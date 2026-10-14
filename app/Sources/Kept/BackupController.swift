import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// Main-actor glue between the engine, the scheduler, and the menu UI.
///
/// What it owns is the state the panel and Settings show and the decisions
/// about when a backup runs. Choosing a folder is in DestinationPicker, the
/// daily check's LaunchAgent in StalenessAgent, removing Kept in
/// UninstallFlow, and the review tools in ReviewTools.
@MainActor
@Observable
final class BackupController {
    enum Status: Equatable {
        case needsDestination
        case needsPhotosAccess
        case idle
        case running(ExportProgress)
        case failed(FailureKind, String)
        /// A scheduled run was deferred because the Mac is on battery. Not a
        /// failure — nothing was attempted, and it starts itself on plug-in.
        case waitingForPower

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }
    }

    var status: Status = .idle
    var history: [RunRecord] = []
    var isRunning = false
    private(set) var launchAtLogin = false
    var accessTestResult: String?
    var destination: Destination?

    /// Tail of the running export's output, for the Live log disclosure.
    var logTail: [String] = []
    /// Capacity of the destination volume, refreshed when the panel opens.
    var destinationFreeBytes: Int64?
    var destinationIsMounted = false

    /// Preferences, as stored properties so SwiftUI observes them and Settings
    /// binds to them directly. Each writes itself through to UserDefaults.
    ///
    /// `@Observable` keeps property observers, but runs them for the
    /// assignments in `init` too, so each one waits for `preferencesLoaded`:
    /// otherwise loading a preference would write it straight back, and the
    /// ones with side effects would rearm the timer or reinstall the daily
    /// check before anything was set up.
    var cadence: BackupCadence = .nightly {
        didSet {
            persist(cadence.rawValue, Preferences.cadence, rearm: true)
            if preferencesLoaded, cadence == .manual { dropAutomaticWork() }
        }
    }
    var weeklyWeekday = 1 {
        didSet { persist(weeklyWeekday, Preferences.weeklyWeekday, rearm: true) }
    }
    var catchUpEnabled = true {
        didSet { persist(catchUpEnabled, Preferences.catchUpEnabled) }
    }
    var notifyOnFailure = true {
        didSet { persist(notifyOnFailure, Preferences.notifyOnFailure) }
    }
    var notifyAlways = false {
        didSet { persist(notifyAlways, Preferences.notifyAlways) }
    }
    var stalenessWarningEnabled = true {
        didSet {
            persist(stalenessWarningEnabled, Preferences.stalenessWarningEnabled)
            if preferencesLoaded { syncStalenessAgent() }
        }
    }
    var stalenessDays = 3 {
        didSet {
            // Reassigning re-runs this observer, once, with the valid value.
            guard stalenessDays >= 1 else { stalenessDays = 1; return }
            persist(stalenessDays, Preferences.stalenessDays)
        }
    }
    /// Takes effect at the next backup, which deletes anything now past it.
    var removedRetentionDays = RemovedPhotos.defaultRetentionDays {
        didSet {
            guard RemovedPhotos.retentionChoices.contains(removedRetentionDays) else {
                removedRetentionDays = oldValue
                return
            }
            persist(removedRetentionDays, Preferences.removedRetentionDays)
        }
    }
    var checkForUpdates = true {
        didSet {
            persist(checkForUpdates, Preferences.checkForUpdates)
            if preferencesLoaded, checkForUpdates { checkForUpdatesIfDue() }
        }
    }
    private(set) var hasCompletedOnboarding = false

    @ObservationIgnored private var preferencesLoaded = false

    private func persist(_ value: Any, _ key: String, rearm: Bool = false) {
        guard preferencesLoaded else { return }
        UserDefaults.standard.set(value, forKey: key)
        if rearm { scheduler.rearm() }
    }

    /// Mirrors `scheduler.nextFire`. Stored rather than computed so an open
    /// Settings window updates the moment the schedule changes.
    var nextRun: Date?
    var lastSuccess: RunRecord? { displayHistory.last(where: { $0.outcome == .success }) }
    /// The runs for the current backup folder. Everything that says how
    /// protected the library is reads these, so a newly chosen folder shows
    /// as never backed up until a backup there finishes.
    var folderHistory: [RunRecord] { history.runs(for: destination) }
    /// The last write to the history failed, so the daily check and catch-up
    /// are reading an old one. Cleared by the next write that lands.
    private(set) var historyIsNotSaving = false
    /// Items osxphotos counted at the last good run. Used only to size up the
    /// first-copy warning ("about 46,920 items"); it is NOT the number the
    /// Photos app shows, so it is never presented as a library total.
    var mirroredItemCount: Int? { lastSuccess?.mirroredCount }
    /// Filename currently being exported, when a run is in flight.
    var currentItemName: String? {
        guard case .running(let progress) = displayStatus else { return nil }
        return progress.currentItemName
    }

    /// Linear extrapolation from elapsed time over the fraction done. nil until
    /// osxphotos has announced a total, which is also when the design says to
    /// drop the "· about Xm left" clause.
    var estimatedTimeRemaining: TimeInterval? {
        #if KEPT_REVIEW_TOOLS
        if let preview { return preview.estimatedTimeRemaining }
        #endif
        guard case .running(let progress) = status,
            let fraction = progress.fractionComplete, fraction > 0.01,
            let started = runStartedAt
        else { return nil }
        let elapsed = Date.now.timeIntervalSince(started)
        return elapsed / fraction - elapsed
    }

    private let engine = BackupEngine()
    private let scheduler = Scheduler()
    private var runTask: Task<Void, Never>?
    private var runStartedAt: Date?
    private var accessProbeTask: Task<Void, Never>?
    private var powerObserver: (source: CFRunLoopSource, box: AnyObject)?
    private var retryTask: Task<Void, Never>?
    /// The power source at the last change, so only a move onto mains power
    /// counts as one. macOS reports every change in charge level too.
    private var wasOnAC = PowerSource.isOnAC
    /// The panel's mount and free-space reads. See refreshDestinationStats.
    private let statsLane = BlockingLane()

    /// What macOS allows for Kept's notifications. nil until read, and always
    /// outside an app bundle.
    var notificationAuthorization: UNAuthorizationStatus?

    /// True when a warning Kept is set to send can't arrive: the user denied
    /// the prompt, or turned Kept off in System Settings since. The Settings
    /// checkboxes would otherwise go on promising warnings that never come.
    var notificationsAreOff: Bool {
        notificationAuthorization == .denied
            && (notifyOnFailure || notifyAlways || stalenessWarningEnabled)
    }

    init() {
        Scheduler.registerDefaults()
        Preferences.registerDefaults()
        Config.ensureDirectories()
        // Close out any run whose process died before it could write an
        // outcome. Skipped when a live process still holds the backup lock, so
        // a second instance starting mid-export cannot mislabel a healthy run.
        history = BackupEngine.livePidHoldingLock() == nil
            ? RunHistory.reconcileInterrupted()
            : RunHistory.load()
        destination = DestinationStore.load()

        let defaults = UserDefaults.standard
        cadence = Preferences.currentCadence
        weeklyWeekday = Scheduler.clamped(defaults.integer(forKey: Preferences.weeklyWeekday), 1...7)
        catchUpEnabled = defaults.bool(forKey: Preferences.catchUpEnabled)
        notifyOnFailure = defaults.bool(forKey: Preferences.notifyOnFailure)
        notifyAlways = defaults.bool(forKey: Preferences.notifyAlways)
        stalenessWarningEnabled = defaults.bool(forKey: Preferences.stalenessWarningEnabled)
        stalenessDays = max(1, defaults.integer(forKey: Preferences.stalenessDays))
        removedRetentionDays = RemovedPhotos.retentionDays(defaults)
        checkForUpdates = defaults.bool(forKey: Preferences.checkForUpdates)
        hasCompletedOnboarding = defaults.bool(forKey: Preferences.hasCompletedOnboarding)
        preferencesLoaded = true
        availableUpdate = Self.storedUpdate(defaults)

        if destination == nil {
            status = .needsDestination
        } else if let last = folderHistory.last, last.outcome == .failed {
            // A failure that happened before the last quit is still the truth
            // about the library, so the panel opens on it rather than implying
            // all is well. A missing-access failure opens on the paused panel;
            // the access check at launch clears it if access is back.
            status = last.failureKind == .libraryAccess
                ? .needsPhotosAccess
                : .failed(last.failureKind ?? .setupFailed, last.message ?? "Backup failed")
        }
        scheduler.onFire = { [weak self] trigger in self?.startBackup(trigger) }
        scheduler.loadHistory = { [weak self] in
            RunHistory.load().runs(for: self?.destination)
        }
        scheduler.onRearm = { [weak self] fire in self?.nextRun = fire }
        // Event-driven, not polled: plugging in is the signal that a deferred
        // or failed night can finally be made good.
        powerObserver = PowerSource.observe { [weak self] in
            Task { @MainActor in self?.powerSourceChanged() }
        }
        Task { await start() }
    }

    private func start() async {
        if Bundle.main.bundleURL.pathExtension == "app" {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if hasCompletedOnboarding { registerBackgroundItems() }
        }
        // Deliberately outside the bundle check, so the flow can be exercised
        // under `swift run` without signing and installing a bundle first.
        OnboardingWindowController.showIfNeeded(controller: self)
        scheduler.start()
        refreshNotificationAuthorization()
        await requestExplainedPermissions()
        refreshDestinationStats()
        checkForUpdatesIfDue()
        // A scheduled time may have passed while the app wasn't running.
        scheduler.fireCatchUpIfMissed()
    }

    /// Launch-time work held back until onboarding has had its say: the
    /// notification request, which raises a system dialog, and the library
    /// probe, which would otherwise put the paused panel up before the flow has
    /// explained Full Disk Access.
    ///
    /// Both used to run unconditionally here, which on a genuine first launch
    /// put a dialog on screen before the user had been told what Kept is. That
    /// is the exact thing the first-run flow exists to prevent, and it cannot
    /// prevent it from a window that opens underneath the prompt. Every later
    /// launch runs this exactly as before: the flag is already true by then.
    private func requestExplainedPermissions() async {
        guard hasCompletedOnboarding else { return }
        if Bundle.main.bundleURL.pathExtension == "app" {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            refreshNotificationAuthorization()
        }
        await refreshPhotosAccess()
    }

    /// Reads the notification setting, which never prompts. Called at launch,
    /// after the request, and whenever the panel or Settings opens, since the
    /// user can change it in System Settings at any time.
    func refreshNotificationAuthorization() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.notificationAuthorization = status }
        }
    }

    func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.chipcressman.Kept"
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Re-probes every 5s so granting access flips the panel without the user
    /// coming back to it.
    ///
    /// Runs only while access is actually missing. This used to be an
    /// unconditional `while true` loop in start(), which woke the process every
    /// 5 seconds for the life of the app — roughly 17,000 times a day, almost
    /// always to discover that nothing had changed. On a laptop that keeps a
    /// 24/7 background app from ever settling.
    private func startAccessProbe() {
        guard accessProbeTask == nil else { return }
        accessProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.status == .needsPhotosAccess else { return }
                await self.refreshPhotosAccess()
            }
        }
    }

    private func stopAccessProbe() {
        accessProbeTask?.cancel()
        accessProbeTask = nil
    }

    /// See `LibraryAccess.canRead()`.
    func canReadLibrary() async -> Bool? { await LibraryAccess.canRead() }

    private func refreshPhotosAccess() async {
        guard let hasAccess = await canReadLibrary() else { return }
        if !hasAccess, status == .idle || status.isFailed || status == .needsPhotosAccess {
            status = .needsPhotosAccess
            startAccessProbe()
        } else if hasAccess, status == .needsPhotosAccess {
            stopAccessProbe()
            status = .idle
            // A backup missed while access was off runs now, rather than
            // waiting for the next wake, launch or plug-in to notice.
            scheduler.fireCatchUpIfMissed()
        }
    }

    // MARK: - Destination

    /// The folder picker, with its refusals and the non-empty-folder warning
    /// (DestinationPicker).
    ///
    /// Not while a backup is running: that backup carries on to the folder it
    /// started with, and the panel would say it was going somewhere else.
    ///
    /// The folder only changes once it's saved, sealed and reads back. If the
    /// keychain won't seal it, the folder Kept had stays, and is sealed again
    /// in case the attempt cost it its key.
    func chooseDestination() {
        guard !isRunning, !isUninstalling,
            let chosen = DestinationPicker.choose(
                current: destination, retentionDays: removedRetentionDays)
        else { return }
        // A backup that started while the open panel was up.
        guard !isRunning else { return }
        var picked = Destination.adopting(chosen, replacing: destination)
        picked.libraryConfirmed = true

        clearPreview()
        guard DestinationStore.save(picked), DestinationStore.load() == picked else {
            if let destination { DestinationStore.save(destination, sealingKey: SettingsSeal.key()) }
            DestinationPicker.cantSaveAlert(for: picked.displayName, previous: destination)
                .runModal()
            return
        }
        let isNewFolder = picked.id != destination?.id
        destination = picked
        if isNewFolder {
            // The last folder's failure isn't this one's.
            retryTask?.cancel()
            retryTask = nil
            if status.isFailed { status = .idle }
        }
        if status == .needsDestination { status = .idle }
        scheduler.rearm()
        refreshDestinationStats()
        Task { await refreshPhotosAccess() }
    }

    /// A finished backup has used the confirmation that choosing the folder
    /// gave (Destination.libraryConfirmed). Saved like any change to the
    /// folder; if the keychain won't seal it, it stays set, and the next
    /// backup again takes the library unchecked, as the one before did.
    private func clearLibraryConfirmation() {
        guard var updated = destination else { return }
        updated.libraryConfirmed = nil
        guard DestinationStore.save(updated), DestinationStore.load() == updated else {
            if let destination { DestinationStore.save(destination, sealingKey: SettingsSeal.key()) }
            return
        }
        destination = updated
    }

    // MARK: - Runs

    func startBackup(_ trigger: BackupTrigger) {
        // A real run outranks any forced state. Leaving a preview up while the
        // engine works would hide a live backup behind a fabricated panel —
        // and would let "Back Up Now", pressed from a previewed screen, start
        // an invisible one.
        clearPreview()
        guard !isUninstalling, !isRunning, let destination,
            Self.mayStart(trigger, cadence: cadence)
        else { return }

        // Never start an unattended run on battery. It cannot succeed: the
        // PreventSystemSleep assertion is honoured on AC only, so macOS sleeps
        // mid-export and the share drops. On 2026-08-05 that cost two hours of
        // retries and a night's battery to back up nothing. The deferral is
        // recorded and shown — a silent skip would be exactly the failure mode
        // this app exists to prevent. A manual Back Up Now is attended and
        // explicit, so it still runs.
        if trigger != .manual, !PowerSource.isOnAC {
            deferForPower(trigger)
            return
        }

        isRunning = true
        runStartedAt = .now
        logTail = []
        status = .running(ExportProgress())
        // The callbacks hold the controller strongly, on purpose. This Task
        // already holds it for the whole run, so a weak capture inside it
        // protected nothing — and the callbacks don't outlive the run.
        runTask = Task {
            let record = await engine.run(
                trigger: trigger,
                destination: destination,
                onProgress: { progress in
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.status = .running(progress)
                    }
                },
                onLogTail: { lines in
                    Task { @MainActor in
                        guard self.isRunning else { return }
                        self.logTail = lines
                    }
                })
            self.finish(record)
        }
    }

    /// Whether a backup may start. Backed up Manually means only when asked:
    /// a retry, a catch-up or a deferred night still pending from before the
    /// switch is dropped here, whatever armed it (production review W6,
    /// 2026-10-13).
    nonisolated static func mayStart(_ trigger: BackupTrigger, cadence: BackupCadence) -> Bool {
        trigger == .manual || cadence != .manual
    }

    /// Switching to Manually cancels what was waiting to start on its own:
    /// the retry after a failure, and a night held back for power. Plugging
    /// in afterwards used to start the deferred backup anyway.
    private func dropAutomaticWork() {
        retryTask?.cancel()
        retryTask = nil
        status = Self.statusDroppingAutomaticWork(status)
    }

    nonisolated static func statusDroppingAutomaticWork(_ status: Status) -> Status {
        status == .waitingForPower ? .idle : status
    }

    /// Re-attempts a failed run after the cooldown, at most
    /// `Config.maxFailureRetries` times per scheduled slot.
    ///
    /// Counted from the history, the same way catch-up counts, so the two
    /// share one cap. An in-memory count only knew about the retries it had
    /// scheduled itself: every wake and plug-in could start another attempt
    /// on top, and a Mac on mains power away from its NAS failed about hourly
    /// for as long as the share was gone.
    ///
    /// A failed night used to sit untouched until something external happened —
    /// a wake, a launch, or a transition onto mains power. On 2026-08-07 the
    /// Mac was already plugged in and stayed awake, so none of those occurred
    /// and the 02:00 failure went unretried for fifteen hours. Catch-up watches
    /// for *changes*; this covers the case where nothing changes.
    ///
    /// The cap is the point: two tries cover a share that was briefly away, and
    /// anything more persistent is left in the failed state where the user will
    /// see it.
    private func scheduleFailureRetry() {
        retryTask?.cancel()
        let history = RunHistory.load().runs(for: destination)
        guard let window = scheduler.attemptWindowStart(history),
            Scheduler.failedAttempts(history, since: window) < Config.maxAttemptsPerSlot
        else {
            retryTask = nil
            return
        }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Config.catchUpCooldownSecs))
            guard let self, !Task.isCancelled else { return }
            // Anything that resolved the failure in the meantime wins.
            guard case .failed = self.status else { return }
            self.startBackup(.retry)
        }
    }

    /// Records the deferral and shows it, so a week on battery reads as a week
    /// of grey "nothing happened" dots rather than a silent gap.
    ///
    /// Once per wait, not once per wake: every lid-open on battery used to
    /// add another record, and history keeps 50, so a week or so away from
    /// power pushed the last good backup out of it. The panel, the failed
    /// panel and the daily check then all said no backup had ever finished.
    private func deferForPower(_ trigger: BackupTrigger) {
        guard status != .waitingForPower else { return }
        // The real trigger, not a hardcoded .scheduled: a deferral at 17:25 that
        // claims to be the 2 AM job makes the history lie about what happened.
        var record = RunRecord(trigger: trigger, start: .now)
        record.destinationID = destination?.id
        record.end = .now
        record.outcome = .skipped
        record.message = "Skipped — on battery power"
        do {
            try RunHistory.upsert(record)
            historyIsNotSaving = false
        } catch {
            historyIsNotSaving = true
        }
        history = RunHistory.load()
        status = .waitingForPower
    }

    /// Power arrived. Start whatever the battery rule held back.
    private func powerSourceChanged() {
        let onAC = PowerSource.isOnAC
        defer { wasOnAC = onAC }
        guard onAC, !wasOnAC else { return }
        if status == .waitingForPower {
            startBackup(.catchUp)
        } else {
            // Covers the other reason a slot can go unserviced — last night's
            // run failed — now that the machine can actually finish one.
            scheduler.fireCatchUpIfMissed()
        }
    }

    func cancelBackup() {
        Task { await engine.cancel() }
    }

    func runAccessTest() {
        guard !isRunning, accessTestResult != "Testing…" else { return }
        accessTestResult = "Testing…"
        Task {
            let result = await engine.accessTest()
            // A failed read is almost always Full Disk Access, which is the
            // one thing the user can fix from here, so the failure says so.
            // The raw tool output stays in access-test.log. Timeouts and a
            // broken install already come back as sentences.
            self.accessTestResult = result.hasPrefix("FAILED")
                ? "Kept can't read your library. Check that Full Disk Access is on."
                : result
            // A read can still raise a consent dialog, and answering it hands
            // focus to the system and leaves this app behind it — an agent app
            // has no Dock icon to click its way back with. Come forward so the
            // result is visible where the user was already looking.
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func finish(_ record: RunRecord) {
        clearPreview()
        isRunning = false
        runStartedAt = nil
        if record.outcome == .success, destination?.libraryConfirmed == true {
            clearLibraryConfirmation()
        }
        history = RunHistory.load()
        // Read back rather than trusted: the engine wrote it, and logged it
        // if it couldn't.
        historyIsNotSaving = !history.contains {
            $0.id == record.id && $0.outcome == record.outcome
        }
        switch record.outcome {
        case .failed where record.failureKind == .libraryAccess:
            // The paused panel, not the failed one: it names the fix and clears
            // itself when access returns. No retry either — it would fail the
            // same way until the switch is on, and turning it on starts the
            // missed backup (refreshPhotosAccess).
            retryTask?.cancel()
            retryTask = nil
            status = .needsPhotosAccess
            startAccessProbe()
        case .failed:
            status = .failed(
                record.failureKind ?? .setupFailed, record.message ?? "Backup failed")
            scheduleFailureRetry()
        case .success:
            retryTask?.cancel()
            retryTask = nil
            status = destination == nil ? .needsDestination : .idle
        default:
            // Cancelled or skipped: the user's choice or a deferral, neither of
            // which should provoke an automatic retry.
            retryTask?.cancel()
            retryTask = nil
            status = destination == nil ? .needsDestination : .idle
        }
        scheduler.rearm()
        refreshDestinationStats()
        Task { await refreshPhotosAccess() }
    }

    // MARK: - Destination stats

    /// Reads the volume's mount state and free space on a thread of its own.
    ///
    /// `statfs` costs ~0.01ms on a healthy volume, but the destination is
    /// usually an SMB share, and on a stale mount these calls block —
    /// indefinitely. Inline on the main actor, one dead mount froze the
    /// panel. Then they ran on the cooperative pool, where each panel open
    /// left another thread blocked for good until the pool ran dry and the
    /// backup in progress stalled with it (see BlockingLane). One read at a
    /// time now, and a read that doesn't answer in time leaves the share
    /// showing as not connected, which by then it effectively isn't.
    func refreshDestinationStats() {
        guard let destination else {
            destinationIsMounted = false
            destinationFreeBytes = nil
            return
        }
        Task { [weak self, statsLane] in
            let outcome = await statsLane.run(timeout: Config.volumeCallTimeoutSecs) {
                (mounted: destination.isMounted, free: destination.volumeStats()?.freeBytes)
            }
            guard let self, self.destination == destination else { return }
            switch outcome {
            case .finished(let stats):
                self.destinationIsMounted = stats.mounted
                self.destinationFreeBytes = stats.free
            case .timedOut:
                self.destinationIsMounted = false
                self.destinationFreeBytes = nil
            case .busy:
                // An earlier read is still out, and either it lands or it has
                // already timed out and said so.
                break
            }
        }
    }

    // MARK: - Updates

    /// A newer release than this copy, when the last check found one.
    private(set) var availableUpdate: UpdateCheck.Release?
    @ObservationIgnored private var updateCheckInFlight = false

    /// Asks GitHub for the latest release if the last check was a day ago or
    /// more. Called at launch and whenever the panel or Settings opens, which
    /// are the only places the answer shows, so no timer runs for it.
    ///
    /// Not before setup is done: the welcome screen is where Kept says it
    /// checks. Not outside an app bundle either, which has no version to
    /// compare.
    func checkForUpdatesIfDue(now: Date = .now) {
        let defaults = UserDefaults.standard
        guard checkForUpdates, hasCompletedOnboarding, !updateCheckInFlight,
            Bundle.main.bundleURL.pathExtension == "app",
            UpdateCheck.isDue(
                checkedAt: defaults.object(forKey: Preferences.updateCheckedAt) as? Date, now: now)
        else { return }
        updateCheckInFlight = true
        Task {
            let latest = await UpdateCheck.fetchLatest()
            updateCheckInFlight = false
            guard let latest else {
                // Offline, or GitHub didn't answer: try again in an hour, not
                // at every panel open.
                defaults.set(
                    now.addingTimeInterval(UpdateCheck.retryAfterFailure - UpdateCheck.interval),
                    forKey: Preferences.updateCheckedAt)
                return
            }
            defaults.set(Date.now, forKey: Preferences.updateCheckedAt)
            let newer = UpdateCheck.isNewer(latest.version, than: Config.appVersion)
            defaults.set(newer ? latest.version : nil, forKey: Preferences.availableUpdateVersion)
            availableUpdate = newer ? latest : nil
        }
    }

    /// The release found last time, if it's still newer than this copy. After
    /// an update it no longer is, and it's forgotten.
    private static func storedUpdate(_ defaults: UserDefaults) -> UpdateCheck.Release? {
        guard let stored = defaults.string(forKey: Preferences.availableUpdateVersion),
            let version = UpdateCheck.version(fromTag: stored),
            UpdateCheck.isNewer(version, than: Config.appVersion)
        else {
            defaults.removeObject(forKey: Preferences.availableUpdateVersion)
            return nil
        }
        return UpdateCheck.Release(version: version)
    }

    func openUpdatePage() {
        guard let release = displayAvailableUpdate else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    // MARK: - Schedule

    var scheduledHour: Int { scheduler.scheduledHour }
    var scheduledMinute: Int { scheduler.scheduledMinute }

    func setSchedule(hour: Int, minute: Int) {
        UserDefaults.standard.set(hour, forKey: Scheduler.hourKey)
        UserDefaults.standard.set(minute, forKey: Scheduler.minuteKey)
        scheduler.rearm()
    }

    /// Time of day, as a Date, for the Settings picker. Writing it reschedules.
    var scheduleTime: Date {
        get {
            Calendar.current.date(
                bySettingHour: scheduledHour, minute: scheduledMinute, second: 0, of: .now)
                ?? .now
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            setSchedule(hour: parts.hour ?? 2, minute: parts.minute ?? 0)
        }
    }

    // MARK: - Staleness watchdog

    var stalenessAgentError: String?

    /// Brings the daily check's LaunchAgent in line with the preference.
    func syncStalenessAgent() {
        Task { stalenessAgentError = await StalenessAgent.apply(enabled: stalenessWarningEnabled) }
    }

    /// See StalenessAgent.staleWarning.
    func stalenessAgentStaleWarning(now: Date = .now) -> String? {
        StalenessAgent.staleWarning(enabled: stalenessWarningEnabled, now: now)
    }

    // MARK: - Login item

    /// The login item and the daily check. Registering each makes macOS post a
    /// notification ("Login Item Added", "App Background Activity"), so on a
    /// first run they wait for setup to finish — posted the moment Kept opened,
    /// they landed on top of the welcome screen, announcing background work for
    /// an app that hadn't been set up. Found in testing on 2026-10-05.
    private func registerBackgroundItems() {
        registerLoginItemOnce()
        syncStalenessAgent()
    }

    private func registerLoginItemOnce() {
        let key = "didRegisterLoginItem"
        // Marked done only once macOS has it. A registration that failed used
        // to be marked done anyway, so it was never tried again.
        if !UserDefaults.standard.bool(forKey: key) {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: key)
                loginItemError = nil
            } catch {
                loginItemError = Self.loginItemErrorText
            }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The Open at Login checkbox. Computed rather than observed: the value
    /// shown is what macOS reports afterwards, which isn't always what was
    /// asked for, and a `didSet` that corrects itself would run forever.
    var openAtLogin: Bool {
        get { launchAtLogin }
        set { setLaunchAtLogin(newValue) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = Self.loginItemErrorText
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Said under the checkbox when macOS refused the change, which otherwise
    /// only shows as a checkbox that didn't stay the way it was set.
    private(set) var loginItemError: String?
    static let loginItemErrorText =
        "macOS didn't allow this. Check Login Items in System Settings."


    // MARK: - Onboarding

    /// Called from the flow's last screen, and only from there. Closing the
    /// window early leaves the flag alone on purpose, so an abandoned setup
    /// gets another chance at the next launch rather than stranding the user
    /// with permissions that were never asked for.
    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Preferences.hasCompletedOnboarding)
        // The last screen just named when the first backup starts. A time
        // that passed before now isn't one it promised (fireCatchUpIfMissed).
        UserDefaults.standard.set(Date.now, forKey: Preferences.setupCompletedAt)
        // Everything start() held back: the login item, the daily check, and
        // the access check, so a blocked library surfaces in the panel now
        // rather than after a relaunch.
        if Bundle.main.bundleURL.pathExtension == "app" { registerBackgroundItems() }
        Task { await requestExplainedPermissions() }
        checkForUpdatesIfDue()
    }

    /// The window was closed before the last screen.
    ///
    /// The flag stays false, so the flow returns next launch — but the access
    /// probe has to run now regardless. Without it, `start()` skipped the probe
    /// and nothing else would set `.needsPhotosAccess`, leaving the panel
    /// claiming all is well for the rest of the session while the library was
    /// unreadable.
    func onboardingDismissedEarly() async {
        guard !hasCompletedOnboarding else { return }
        await refreshPhotosAccess()
    }

    // MARK: - Menu actions

    /// The five looks the menubar icon has. Split out from `Status` so the
    /// glyph can be previewed from Settings without faking a backup state.
    enum GlyphState: String, CaseIterable, Identifiable, Sendable {
        case idle, running, needsSetup, accessBlocked, failed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .idle: "Idle"
            case .running: "Running"
            case .failed: "Failed"
            case .needsSetup: "Needs setup"
            case .accessBlocked: "Access blocked"
            }
        }

        /// The menubar symbol for this state.
        ///
        /// State is carried by the symbol itself rather than by a badge drawn
        /// over it: a template image has no colour to distinguish "needs you"
        /// from "failed", so it has to be said in shape. The two "needs you"
        /// states share a glyph because they ask the same thing of the user —
        /// go and do something before tonight.
        ///
        /// The design asked for `photo.badge.questionmark` on the "needs you"
        /// states. It didn't exist when this was built (macOS 26), and by the
        /// time macOS 27 added it the shared glyph had become the intent.
        ///
        /// So every state that wants attention — nothing set up, access
        /// blocked, last run failed — shares the one badged glyph. The menubar
        /// says only "this needs looking at"; the panel behind it is what says
        /// which of the three it is, in a sentence, which is a better place to
        /// draw a distinction than a 30pt silhouette.
        var symbol: String {
            switch self {
            case .idle: "photo.on.rectangle.angled"
            case .running: "photo.on.rectangle.angled.fill"
            case .needsSetup, .accessBlocked, .failed: "photo.badge.exclamationmark"
            }
        }
    }

    var glyphState: GlyphState {
        #if KEPT_REVIEW_TOOLS
        if let glyphPreview { return glyphPreview }
        #endif
        // displayStatus, not status: previewing a panel state should carry the
        // menubar icon with it, or the two halves of the same screenshot
        // disagree.
        switch displayStatus {
        case .running: return .running
        case .failed: return .failed
        case .needsPhotosAccess: return .accessBlocked
        case .needsDestination: return .needsSetup
        // Amber, like the other "needs something from you" states: plugging in
        // is the action, and an idle glyph would imply all is well.
        case .waitingForPower: return .needsSetup
        case .idle: return .idle
        }
    }

    var menuBarSymbol: String { glyphState.symbol }

    /// `logPath` comes back from runs.json, which anything running as this user
    /// can rewrite. `NSWorkspace.open` on an arbitrary path launches whatever
    /// is there — an app bundle, a document with its own handler — so the path
    /// is confined to the log directory before it is handed over.
    func openLog(_ record: RunRecord) {
        guard let path = record.logPath, let url = Self.logURL(forStoredPath: path) else { return }
        NSWorkspace.shared.open(url)
    }

    nonisolated static func logURL(forStoredPath path: String) -> URL? {
        let url = URL(filePath: path).standardizedFileURL
        guard url.pathExtension == "log" else { return nil }
        let root = Config.logDir.standardizedFileURL.path
        // Compare against "<root>/" so a sibling directory whose name merely
        // starts with the same characters can't pass.
        guard url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return url
    }

    func openLastLog() {
        if let record = history.last(where: { $0.logPath != nil }) {
            openLog(record)
        }
    }

    func openReport() {
        NSWorkspace.shared.open(Config.reportURL)
    }

    func openLogsFolder() {
        NSWorkspace.shared.open(Config.logDir)
    }

    /// Straight to the Full Disk Access list, which is where Kept's access to
    /// the library is actually granted.
    func openFullDiskAccessSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - What the panel shows

    /// What the panel renders. Everything the UI reads goes through the
    /// `display…` accessors, so a review build's forced state sits on top of
    /// the real one and the real one comes straight back when it's cleared.
    var displayStatus: Status {
        #if KEPT_REVIEW_TOOLS
        if let preview { return preview.status }
        #endif
        return status
    }

    var displayHistory: [RunRecord] {
        #if KEPT_REVIEW_TOOLS
        if let preview { return preview.history }
        #endif
        return folderHistory
    }

    var displayLogTail: [String] {
        #if KEPT_REVIEW_TOOLS
        if let preview { return preview.logTail }
        #endif
        return logTail
    }

    /// The real destination wins whenever there is one — a preview should never
    /// claim photos are going somewhere they aren't. The sample only fills in on
    /// a machine that has not been set up, where the alternative is a blank row.
    var displayDestination: Destination? {
        #if KEPT_REVIEW_TOOLS
        return destination ?? preview?.destination
        #else
        return destination
        #endif
    }

    /// General tab reads these two rather than the underlying values, so the
    /// preview is a display concern and never touches what the watchdog
    /// actually reported.
    var displayStalenessAgentError: String? {
        #if KEPT_REVIEW_TOOLS
        switch stalenessWarningPreview {
        case .registrationFailed: return "launchctl bootstrap failed (5) Input/output error"
        case .neverRuns: return nil
        case nil: break
        }
        #endif
        return stalenessAgentError
    }

    /// The update the panel and Settings offer. Nothing while checking is off.
    var displayAvailableUpdate: UpdateCheck.Release? {
        #if KEPT_REVIEW_TOOLS
        if updatePreview { return UpdateCheck.Release(version: "9.9") }
        #endif
        return checkForUpdates ? availableUpdate : nil
    }

    func displayStalenessAgentStaleWarning(now: Date = .now) -> String? {
        #if KEPT_REVIEW_TOOLS
        switch stalenessWarningPreview {
        case .registrationFailed: return nil
        case .neverRuns: return "This check last ran 6 days ago — it should run daily."
        case nil: break
        }
        #endif
        return stalenessAgentStaleWarning(now: now)
    }

    /// Drops every forced state. Called by anything that starts or finishes a
    /// real run, which outranks them; nothing to drop in a release build.
    func clearPreview() {
        #if KEPT_REVIEW_TOOLS
        preview = nil
        glyphPreview = nil
        stalenessWarningPreview = nil
        updatePreview = false
        #endif
    }

    // MARK: - Review tools' overrides

    #if KEPT_REVIEW_TOOLS
    /// The forced panel state, when Settings → Advanced is driving one.
    ///
    /// In-memory only, like `glyphPreview` and for the same reason: a panel
    /// showing a fabricated "backed up an hour ago" is the exact lie this app
    /// exists to prevent, so it must not survive a quit. Nothing here is
    /// written to runs.json or to any preference.
    private(set) var preview: StatePreview.Snapshot?

    /// The scenario picker's selection.
    var previewScenario: PreviewScenario? {
        get { preview?.scenario }
        set { preview = newValue.map { StatePreview.snapshot(for: $0) } }
    }

    var isPreviewing: Bool { preview != nil }

    /// Any override at all is up, including the Settings-only ones.
    var hasAnyPreview: Bool {
        preview != nil || glyphPreview != nil || stalenessWarningPreview != nil || updatePreview
    }

    /// Shows "Kept 9.9 is available" in the panel and Settings, so that row
    /// can be reviewed without waiting for a release.
    var updatePreview = false

    /// Forced menubar glyph. In-memory only: a forced badge must never outlive
    /// the app that set it.
    var glyphPreview: GlyphState?

    var stalenessWarningPreview: StalenessWarningPreview?

    /// Reopens the flow from Settings → Advanced, for checking the setup
    /// screens without having to clear the preference by hand.
    ///
    /// Nothing already granted is asked for a second time: macOS will not
    /// re-prompt for a decision the user has made.
    func resetOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: Preferences.hasCompletedOnboarding)
        OnboardingWindowController.showIfNeeded(controller: self)
    }
    #endif

    // MARK: - Uninstall

    /// True once removal has started, for the rest of the process's life, so
    /// the button can't be pressed twice and no backup starts into the state
    /// folder being deleted.
    private(set) var isUninstalling = false

    /// Settings → Advanced → Remove Kept. See UninstallFlow.
    func beginUninstall() {
        guard !isUninstalling else { return }
        // From the first dialog on, nothing starts. AppKit's modal loop
        // services timers, so a scheduled, retry or plug-in start used to be
        // able to begin while the confirmation was open, and the removal then
        // deleted its state mid-export (production review S8, 2026-10-13).
        isUninstalling = true
        Task {
            await UninstallFlow.run(destination: destination, backupIsRunning: isRunning)
            // Still here: cancelled or refused. A slot that came round while
            // the dialog was open is made up now, by catch-up's usual rules.
            isUninstalling = false
            scheduler.fireCatchUpIfMissed()
        }
    }
}
