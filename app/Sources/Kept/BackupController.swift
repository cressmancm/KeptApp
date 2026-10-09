import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// Main-actor glue between the engine, the scheduler, and the menu UI.
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
    var launchAtLogin = false
    var accessTestResult: String?
    var destination: Destination?

    /// Tail of the running export's output, for the Live log disclosure.
    var logTail: [String] = []
    /// Capacity of the destination volume, refreshed when the panel opens.
    var destinationFreeBytes: Int64?
    var destinationIsMounted = false

    /// Preferences, mirrored into stored properties so SwiftUI observes them.
    /// Written through to UserDefaults by the `set…` methods below rather than
    /// by property observers, which `@Observable` does not carry over.
    private(set) var cadence: BackupCadence = .nightly
    private(set) var weeklyWeekday = 1
    private(set) var catchUpEnabled = true
    private(set) var notifyOnFailure = true
    private(set) var notifyAlways = false
    private(set) var stalenessWarningEnabled = true
    private(set) var stalenessDays = 3
    private(set) var removedRetentionDays = RemovedPhotos.defaultRetentionDays
    private(set) var hasCompletedOnboarding = false

    /// Mirrors `scheduler.nextFire`. Stored rather than computed so an open
    /// Settings window updates the moment the schedule changes.
    var nextRun: Date?
    var lastSuccess: RunRecord? { displayHistory.last(where: { $0.outcome == .success }) }
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
        if let preview { return preview.estimatedTimeRemaining }
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
        hasCompletedOnboarding = defaults.bool(forKey: Preferences.hasCompletedOnboarding)

        if destination == nil {
            status = .needsDestination
        } else if let last = history.last, last.outcome == .failed {
            // A failure that happened before the last quit is still the truth
            // about the library, so the panel opens on it rather than implying
            // all is well. A missing-access failure opens on the paused panel;
            // the access check at launch clears it if access is back.
            status = last.failureKind == .libraryAccess
                ? .needsPhotosAccess
                : .failed(last.failureKind ?? .setupFailed, last.message ?? "Backup failed")
        }
        scheduler.onFire = { [weak self] trigger in self?.startBackup(trigger) }
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
        let id = Bundle.main.bundleIdentifier ?? "com.chip.Kept"
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

    /// Folder picker plus the --cleanup guardrail: picking a non-empty folder
    /// gets a blunt warning that foreign contents will be deleted by the
    /// mirror and that a new folder means a full re-export.
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use for Backup"
        panel.message = "Choose a folder for your backup."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let picked = Destination.from(folder: url)

        // The destination is a mirror, not a folder that also holds a backup:
        // anything else in it is moved aside and later deleted. Pointed at a
        // home or system folder, a Photos library or a whole cloud drive, that
        // loses someone's files, so those are refused outright rather than
        // warned about.
        if Destination.isUnsafeMirrorRoot(path: picked.path, resolvingLinks: true) {
            unsafeMirrorRootAlert(for: picked.displayName).runModal()
            return
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if let refusal = Destination.refusal(path: picked.path, entries: entries)
            ?? Destination.refusal(path: url.resolvingSymlinksInPath().path)
        {
            unsafeMirrorRootAlert(for: picked.displayName, refusal: refusal).runModal()
            return
        }

        // By path: choosing the current folder again only refreshes what Kept
        // knows about its disk, and isn't a new folder to warn about.
        if picked.path != destination?.path {
            if !Destination.isEffectivelyEmpty(entries: entries) {
                guard nonEmptyFolderAlert(for: picked).runModal() == .alertSecondButtonReturn
                else { return }
            }
        }

        clearPreview()
        DestinationStore.save(picked)
        destination = picked
        if status == .needsDestination { status = .idle }
        scheduler.rearm()
        refreshDestinationStats()
        Task { await refreshPhotosAccess() }
    }

    /// Refusal for a folder the mirror would empty out. Built here rather
    /// than inline so Settings → Advanced can show it without anyone having
    /// to aim the picker at their home folder to find out what it says.
    private func unsafeMirrorRootAlert(
        for name: String, refusal: Destination.Refusal? = nil
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(name)” can't be the backup folder"
        alert.informativeText = switch refusal {
        case nil:
            "Kept removes anything in the backup folder that isn't from your "
                + "library, so system and home folders aren't safe. Create a new "
                + "folder for it."
        case .insidePhotosLibrary:
            "It's inside a Photos library. Choose a folder outside the library."
        case .holdsPhotosLibrary:
            "It has a Photos library in it, which Kept would move out of the "
                + "folder. Create a new folder for the backup."
        case .cloudFolder:
            "Kept would move the files already in it, and the change would sync "
                + "to your other devices. Create a new folder for the backup."
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// The "this folder is not empty" confirmation. Cancel is added first,
    /// which makes it the default button, so Return never accepts a folder
    /// whose contents Kept will move. "Use This Folder" is the second button;
    /// reordering these means reworking the caller's return-code check.
    private func nonEmptyFolderAlert(for picked: Destination) -> NSAlert {
        let alert = NSAlert()
        alert.messageText =
            "Use “\(picked.displayName)”\(hostClause(picked)) as your backup folder?"
        alert.informativeText = """
            This folder isn't empty. Kept will move anything in it that isn't \
            from your library to “\(RemovedPhotos.folderName)” and delete it after \
            \(removedRetentionDays) days. Continue only if it's an old Kept backup \
            or you don't need what's in it.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use This Folder")
        return alert
    }

    /// " on nas.local" for a network share, empty for a local disk — the design
    /// asks for the host in the alert so two same-named folders can be told apart.
    private func hostClause(_ destination: Destination) -> String {
        guard destination.isNetwork,
            let smbURL = destination.smbURL,
            let host = URL(string: smbURL)?.host()
        else { return "" }
        return " on \(host)"
    }

    // MARK: - Runs

    func startBackup(_ trigger: BackupTrigger) {
        // A real run outranks any forced state. Leaving a preview up while the
        // engine works would hide a live backup behind a fabricated panel —
        // and would let "Back Up Now", pressed from a previewed screen, start
        // an invisible one.
        clearPreview()
        guard !isUninstalling, !isRunning, let destination else { return }

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
        let history = RunHistory.load()
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
        record.end = .now
        record.outcome = .skipped
        record.message = "Skipped — on battery power"
        RunHistory.upsert(record)
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
        history = RunHistory.load()
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

    /// Reads the volume's mount state and free space off the main actor.
    ///
    /// `statfs` costs ~0.01ms on a healthy volume, which is why this used to run
    /// inline on the main actor. But the destination is usually an SMB share,
    /// and on a stale mount these calls block — indefinitely. That is not
    /// hypothetical here: BackupEngine runs its mount probe as a SIGKILL-able
    /// child process for exactly this reason. Inline, one dead mount freezes
    /// the menubar panel; off the actor it just leaves the numbers blank.
    func refreshDestinationStats() {
        guard let destination else {
            destinationIsMounted = false
            destinationFreeBytes = nil
            return
        }
        Task { [weak self] in
            let stats = await Task.detached(priority: .utility) {
                (mounted: destination.isMounted, free: destination.volumeStats()?.freeBytes)
            }.value
            guard let self, self.destination == destination else { return }
            self.destinationIsMounted = stats.mounted
            self.destinationFreeBytes = stats.free
        }
    }

    // MARK: - Schedule

    var scheduledHour: Int { scheduler.scheduledHour }
    var scheduledMinute: Int { scheduler.scheduledMinute }

    func setSchedule(hour: Int, minute: Int) {
        UserDefaults.standard.set(hour, forKey: Scheduler.hourKey)
        UserDefaults.standard.set(minute, forKey: Scheduler.minuteKey)
        scheduler.rearm()
    }

    func setCadence(_ value: BackupCadence) {
        cadence = value
        UserDefaults.standard.set(value.rawValue, forKey: Preferences.cadence)
        scheduler.rearm()
    }

    func setWeeklyWeekday(_ value: Int) {
        weeklyWeekday = value
        UserDefaults.standard.set(value, forKey: Preferences.weeklyWeekday)
        scheduler.rearm()
    }

    func setCatchUpEnabled(_ value: Bool) {
        catchUpEnabled = value
        UserDefaults.standard.set(value, forKey: Preferences.catchUpEnabled)
    }

    func setNotifyOnFailure(_ value: Bool) {
        notifyOnFailure = value
        UserDefaults.standard.set(value, forKey: Preferences.notifyOnFailure)
    }

    func setNotifyAlways(_ value: Bool) {
        notifyAlways = value
        UserDefaults.standard.set(value, forKey: Preferences.notifyAlways)
    }

    // MARK: - Staleness watchdog

    func setStalenessWarningEnabled(_ value: Bool) {
        stalenessWarningEnabled = value
        UserDefaults.standard.set(value, forKey: Preferences.stalenessWarningEnabled)
        syncStalenessAgent()
    }

    /// Takes effect at the next backup, which deletes anything now past it.
    func setRemovedRetentionDays(_ value: Int) {
        guard RemovedPhotos.retentionChoices.contains(value) else { return }
        removedRetentionDays = value
        UserDefaults.standard.set(value, forKey: Preferences.removedRetentionDays)
    }

    func setStalenessDays(_ value: Int) {
        stalenessDays = max(1, value)
        UserDefaults.standard.set(stalenessDays, forKey: Preferences.stalenessDays)
    }

    /// Brings the staleness LaunchAgent in line with the preference.
    ///
    /// Uses a plain user LaunchAgent under ~/Library/LaunchAgents, bootstrapped
    /// with launchctl, rather than the modern `SMAppService.agent`. That is
    /// deliberate and was measured, not assumed: SMAppService validates the
    /// registered program against a Team-ID-based code requirement, and this
    /// app is self-signed with `TeamIdentifier=not set`. launchd accepted the
    /// registration, reported the job `.enabled`, and then refused every spawn
    /// with `last exit reason = OS_REASON_CODESIGNING`. Five silent failures,
    /// and three nights without a backup that nothing reported. A plain agent
    /// carries no such requirement and runs (verified: `last exit code = 0`).
    ///
    /// Worth revisiting if the app ever gets a real Developer ID — that would
    /// also let the hardened runtime drop `disable-library-validation`.
    func syncStalenessAgent() {
        Task { await applyStalenessAgent() }
    }

    private func applyStalenessAgent() async {
        let target = "gui/\(getuid())/\(Self.stalenessLabel)"
        let plistURL = Self.stalenessPlistURL
        // Always bootout first: bootstrap fails outright if the label is
        // already loaded, so this is what makes reinstalls idempotent.
        _ = await ShellCommand.run("/bin/launchctl", ["bootout", target], timeout: 20)

        guard stalenessWarningEnabled else {
            try? FileManager.default.removeItem(at: plistURL)
            stalenessAgentError = nil
            return
        }

        // The program path comes from the running bundle, not a hardcoded
        // /Applications, so a copy running from anywhere schedules itself.
        guard let executable = Bundle.main.executableURL?.path else {
            stalenessAgentError = "Could not locate the Kept executable."
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.stalenessPlist(executable: executable)
                .write(to: plistURL, atomically: true, encoding: .utf8)
            let result = await ShellCommand.run(
                "/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path], timeout: 20)
            stalenessAgentError = result.status == 0
                ? nil
                : "launchctl bootstrap failed (\(result.status)) "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Surfaced in Settings rather than swallowed — a watchdog that
            // silently failed to install is worse than no watchdog, because
            // the checkbox would claim protection that isn't there.
            stalenessAgentError = error.localizedDescription
        }
    }

    static let stalenessLabel = "com.chip.Kept.staleness"

    static var stalenessPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(stalenessLabel).plist")
    }

    /// `AssociatedBundleIdentifiers` ties the job to the app in System Settings
    /// → Login Items & Extensions. Without it, Background App Activity listed
    /// Kept twice: the app, and a second "Kept" with a generic exec icon that
    /// was this job.
    static func stalenessPlist(
        executable: String, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.chip.Kept"
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(stalenessLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(executable))</string>
                <string>--staleness-check</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key><integer>9</integer>
                <key>Minute</key><integer>0</integer>
            </dict>
            <key>RunAtLoad</key>
            <false/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>\(xmlEscaped(bundleIdentifier))</string>
            </array>
        </dict>
        </plist>
        """
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
    var stalenessAgentError: String?

    /// Complaint text when the watchdog is switched on but launchd is not
    /// actually running it, else nil.
    ///
    /// The check runs daily, so a stamp older than three days means it has
    /// missed at least two firings — the failure that let this app go three
    /// nights without a backup and say nothing. Registration status cannot
    /// detect it: launchd reported the job as `.enabled` the whole time it was
    /// failing to spawn.
    func stalenessAgentStaleWarning(now: Date = .now) -> String? {
        guard stalenessWarningEnabled else { return nil }
        let defaults = UserDefaults.standard
        guard let lastRun = defaults.object(forKey: Preferences.stalenessLastRun) as? Date else {
            // Never run. Only a complaint once it has had a chance to.
            let installed = (try? FileManager.default.attributesOfItem(
                atPath: Bundle.main.bundlePath)[.modificationDate]) as? Date
            guard let installed, now.timeIntervalSince(installed) > 2 * 86_400 else { return nil }
            return "The daily check hasn't run yet."
        }
        let days = Int(now.timeIntervalSince(lastRun) / 86_400)
        guard days >= 3 else { return nil }
        return "The daily check hasn't run in \(days) days."
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
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Onboarding

    /// Called from the flow's last screen, and only from there. Closing the
    /// window early leaves the flag alone on purpose, so an abandoned setup
    /// gets another chance at the next launch rather than stranding the user
    /// with permissions that were never asked for.
    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Preferences.hasCompletedOnboarding)
        // Everything start() held back: the login item, the daily check, and
        // the access check, so a blocked library surfaces in the panel now
        // rather than after a relaunch.
        if Bundle.main.bundleURL.pathExtension == "app" { registerBackgroundItems() }
        Task { await requestExplainedPermissions() }
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

    /// Reopens the flow from Settings → Advanced, for checking the setup
    /// screens without having to clear the preference by hand.
    ///
    /// Nothing already granted is asked for a second time: the Photos request
    /// returns early unless the choice is still `.notDetermined`, and macOS
    /// will not re-prompt for a decision the user has made.
    func resetOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: Preferences.hasCompletedOnboarding)
        OnboardingWindowController.showIfNeeded(controller: self)
    }

    /// Opens the flow at one screen, for reviewing that screen.
    ///
    /// Unlike `resetOnboarding` this leaves `hasCompletedOnboarding` alone: a
    /// look at screen 3 should not arm the first-run flow for the next launch.
    func showOnboarding(startingAt page: Int) {
        OnboardingWindowController.show(controller: self, startingAt: page)
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

    /// Diagnostic override for the glyph, set from Settings → Advanced.
    /// In-memory only: a forced badge must never outlive the app that set it.
    var glyphPreview: GlyphState?

    var glyphState: GlyphState {
        if let glyphPreview { return glyphPreview }
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

    // MARK: - State preview

    /// The forced state, when Settings → Advanced is driving one.
    ///
    /// In-memory only, like `glyphPreview` and for the same reason: a panel
    /// showing a fabricated "backed up an hour ago" is the exact lie this app
    /// exists to prevent, so it must not survive a quit. Nothing here is
    /// written to runs.json or to any preference.
    private(set) var preview: StatePreview.Snapshot?

    var isPreviewing: Bool { preview != nil }

    /// Any override at all is up, including the two Settings-only ones.
    var hasAnyPreview: Bool {
        preview != nil || glyphPreview != nil || stalenessWarningPreview != nil
    }

    /// What the panel renders. Everything the UI reads goes through the
    /// `display…` pair so the real state is left intact underneath and comes
    /// straight back when the preview is cleared.
    var displayStatus: Status { preview?.status ?? status }
    var displayHistory: [RunRecord] { preview?.history ?? history }
    var displayLogTail: [String] { preview?.logTail ?? logTail }

    /// The real destination wins whenever there is one — a preview should never
    /// claim photos are going somewhere they aren't. The sample only fills in on
    /// a machine that has not been set up, where the alternative is a blank row.
    var displayDestination: Destination? { destination ?? preview?.destination }

    func setPreview(_ scenario: PreviewScenario?) {
        preview = scenario.map { StatePreview.snapshot(for: $0) }
    }

    /// Drops every override. Called from the panel's preview banner, from
    /// Settings, and by anything that starts or finishes a real run.
    func clearPreview() {
        preview = nil
        glyphPreview = nil
        stalenessWarningPreview = nil
    }

    /// The two orange rows the General tab can grow under the staleness
    /// checkbox. Neither is reachable on demand: one needs `launchctl
    /// bootstrap` to fail, the other needs launchd to accept the job and then
    /// never spawn it — which is exactly the silent failure they exist to
    /// report, and exactly why the copy has to be reviewable.
    enum StalenessWarningPreview: String, CaseIterable, Identifiable, Sendable {
        case registrationFailed, neverRuns

        var id: String { rawValue }

        var label: String {
            switch self {
            case .registrationFailed: "Couldn't schedule"
            case .neverRuns: "Not running"
            }
        }
    }

    var stalenessWarningPreview: StalenessWarningPreview?

    /// General tab reads these two rather than the underlying values, so the
    /// preview is a display concern and never touches what the watchdog
    /// actually reported.
    var displayStalenessAgentError: String? {
        switch stalenessWarningPreview {
        case .registrationFailed:
            "launchctl bootstrap failed (5) Input/output error"
        case .neverRuns: nil
        case nil: stalenessAgentError
        }
    }

    func displayStalenessAgentStaleWarning(now: Date = .now) -> String? {
        switch stalenessWarningPreview {
        case .registrationFailed: nil
        case .neverRuns: "This check last ran 6 days ago — it should run daily."
        case nil: stalenessAgentStaleWarning(now: now)
        }
    }

    /// The alerts `chooseDestination` raises, shown on demand.
    ///
    /// All are refusals or warnings about a folder the user just picked, so
    /// there is no way to see one without pointing Kept at a folder you
    /// would rather it didn't touch.
    enum PreviewDialog: String, CaseIterable, Identifiable, Sendable {
        case unsafeRoot, photosLibrary, cloudFolder, nonEmptyFolder

        var id: String { rawValue }

        var label: String {
            switch self {
            case .unsafeRoot: "Unsafe Folder"
            case .photosLibrary: "Holds a Library"
            case .cloudFolder: "Cloud Folder"
            case .nonEmptyFolder: "Folder Not Empty"
            }
        }
    }

    func showPreviewDialog(_ dialog: PreviewDialog) {
        // The real destination when there is one, so the alert names something
        // the reviewer recognises.
        let sample = destination ?? StatePreview.sampleDestination
        NSApp.activate(ignoringOtherApps: true)
        switch dialog {
        case .unsafeRoot:
            unsafeMirrorRootAlert(for: FileManager.default
                .homeDirectoryForCurrentUser.appending(path: "Pictures").lastPathComponent)
                .runModal()
        case .photosLibrary:
            unsafeMirrorRootAlert(for: "Photos SSD", refusal: .holdsPhotosLibrary).runModal()
        case .cloudFolder:
            unsafeMirrorRootAlert(for: "iCloud Drive", refusal: .cloudFolder).runModal()
        case .nonEmptyFolder:
            _ = nonEmptyFolderAlert(for: sample).runModal()
        }
    }

    /// The three notifications, posted for real so they can be checked in
    /// Notification Centre — including whether the "Launch Kept" button on the
    /// staleness one still works.
    ///
    /// Deliberately not gated on the notify preferences the engine honours: the
    /// point of the button is to see the notification, and a button that
    /// silently does nothing because a checkbox is off is worse than no button.
    enum PreviewNotification: String, CaseIterable, Identifiable, Sendable {
        case complete, failed, stale

        var id: String { rawValue }

        var label: String {
            switch self {
            case .complete: "Backup Complete"
            case .failed: "Backup Failed"
            case .stale: "Backups Stopped"
            }
        }
    }

    // MARK: - Uninstall

    /// True while the removal is working, so the button cannot be pressed twice.
    private(set) var isUninstalling = false

    /// Settings → Advanced → Remove Kept.
    ///
    /// A self-signed menubar app that registers a login item and a LaunchAgent
    /// has no Installer to undo it, and the obvious move — drag it to the Trash
    /// — is the one that leaves launchd firing daily at a missing binary. So
    /// the app has to know how to remove itself.
    func beginUninstall() {
        Task { await runUninstall() }
    }

    private func runUninstall() async {
        guard !isUninstalling else { return }

        // build.sh refuses for the same reason: taking the app away mid-export
        // kills osxphotos, loses the run, and leaves the mirror half-updated.
        // The lock file is checked as well as `isRunning`, so a run started by
        // another copy of Kept also counts.
        guard !isRunning, BackupEngine.livePidHoldingLock() == nil else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "A backup is running"
            alert.informativeText =
                "Wait for it to finish, or stop it from the menubar, then try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        // Decided once, so the confirmation, the plan and the summary agree.
        let removeApp = Uninstall.canRemoveApp()
        let confirmation = confirmUninstallAlert(removeApp: removeApp)
        guard confirmation.alert.runModal() == .alertSecondButtonReturn else { return }
        let keepExportDatabase = confirmation.keepExportDatabase?.state == .on

        // Stays true for the rest of the process's life. The summary alert
        // below runs a modal loop, which services timers — so without this a
        // scheduled slot landing in those few seconds would start a backup into
        // the state directory that was just deleted.
        isUninstalling = true
        // The Settings window saves its frame into the defaults domain when it
        // closes, and it used to close after the domain was deleted, which
        // brought the domain back with that one key. Closed first now.
        for window in NSApp.windows where window.isVisible { window.close() }
        let outcome = await Uninstall.perform(
            Uninstall.plan(keepExportDatabase: keepExportDatabase, removeApp: removeApp))

        uninstallSummaryAlert(
            outcome, keptExportDatabase: keepExportDatabase, removedApp: removeApp
        ).runModal()
        // Again, flushed to disk: the alert is a window too, and AppKit can
        // write state on the way out.
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            CFPreferencesAppSynchronize(bundleIdentifier as CFString)
        }
        NSApp.terminate(nil)
    }

    /// The confirmation, plus the checkbox that decides the export database's
    /// fate — nil when there is no database to keep.
    ///
    /// Asked rather than decided: deleting it is what "remove Kept" promises
    /// and leaves nothing behind, but it is also about a gigabyte that takes
    /// hours of copying to rebuild, and someone reinstalling to fix a broken
    /// install would want it kept. Off by default, so the button still does
    /// what it says.
    private func confirmUninstallAlert(
        removeApp: Bool
    ) -> (alert: NSAlert, keepExportDatabase: NSButton?) {
        let exportDBSize = (try? Config.exportDBURL.resourceValues(forKeys: [.fileSizeKey]))?
            .fileSize

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Remove Kept from this Mac?"
        var text = removeApp
            ? "Kept moves to the Trash, and its settings, history, logs and permissions are deleted.\n"
            : """
                Kept's settings, history and logs are deleted from this account. \
                Kept.app stays in Applications: removing it needs an administrator.

                """
        text += destination.map { "\nYour backup folder stays as it is:\n\($0.path)" }
            ?? "\nYour backup folder stays as it is."
        var checkbox: NSButton?
        if let exportDBSize {
            text += """


                Planning to reinstall? Keep the backup index, or the next backup \
                starts over from scratch.
                """
            let box = NSButton(
                checkboxWithTitle:
                    "Keep the backup index (\(RunFormatting.bytes(Int64(exportDBSize))))",
                target: nil, action: nil)
            box.state = .off
            box.sizeToFit()
            alert.accessoryView = box
            checkbox = box
        }
        alert.informativeText = text
        // Cancel first, as in the folder-picker warning, and for a stronger
        // reason here: NSAlert makes the first button added both the rightmost
        // one and the Return default. That puts the safe answer under the
        // return key AND under a fast click on the button macOS trains people
        // to aim for. Reordering these means reworking the caller's
        // return-code check.
        alert.addButton(withTitle: "Cancel")
        let remove = alert.addButton(withTitle: "Remove Kept")
        remove.hasDestructiveAction = true
        return (alert, checkbox)
    }

    private func uninstallSummaryAlert(
        _ outcome: Uninstall.Outcome, keptExportDatabase: Bool, removedApp: Bool
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = outcome.isClean ? .informational : .warning
        alert.messageText = switch (outcome.isClean, removedApp) {
        case (true, true): "Kept was removed."
        case (true, false): "Kept was removed from this account."
        case (false, _): "Kept was removed, but some items were left behind."
        }

        // No list of what was removed: on a clean removal it is noise, and the
        // title already says it. Only what's left over, and why, is worth
        // reading. The Quit button says the rest.
        var paragraphs: [String] = []
        if !outcome.failed.isEmpty {
            // Named with their paths: a partial uninstall the user cannot see
            // is worse than one they can finish in the Finder.
            paragraphs.append("Delete these yourself:\n"
                + outcome.failed.map { failure in
                    var line = "• \(failure.label): \(failure.reason)"
                    if let path = failure.path { line += "\n  \(path)" }
                    return line
                }.joined(separator: "\n"))
        }
        var backup = "Your backup in \(backupFolderName) wasn't touched."
        // Checked on disk rather than assumed from the choice: this sentence
        // tells the user where a gigabyte is, so it has to be true.
        if keptExportDatabase,
            FileManager.default.fileExists(atPath: Config.exportDBURL.path) {
            let folder = (Config.appSupportDir.path as NSString).abbreviatingWithTildeInPath
            backup += " The backup index stays in \(folder) for a reinstall."
        }
        paragraphs.append(backup)
        // With Kept.app gone its permissions went too; with it staying, the
        // ones every account shares stay with it (Uninstall.tccResetArguments).
        if !removedApp {
            paragraphs.append(
                "Kept.app and its Privacy & Security settings are shared by every "
                    + "account, so they stay. An administrator can remove them.")
        }
        let text = paragraphs.joined(separator: "\n\n")
        alert.informativeText = text
        alert.addButton(withTitle: "Quit")
        return alert
    }

    /// "“Kept”" — the name the summary promises survived. The confirmation
    /// gives the full path instead, on a line of its own: wrapped inside a
    /// sentence, a long path left its closing parenthesis alone on a line.
    private var backupFolderName: String {
        guard let destination else { return "your backup folder" }
        return "“\(destination.displayName)”"
    }

    /// A good run some days back — just enough history for the staleness
    /// check to produce its real sentence for a preview.
    private static func sampleSuccess(daysAgo: Int) -> RunRecord {
        var record = RunRecord(
            trigger: .scheduled, start: .now.addingTimeInterval(-Double(daysAgo) * 86_400))
        record.outcome = .success
        return record
    }

    func postPreviewNotification(_ kind: PreviewNotification) {
        let payload: KeptNotification.Kind = switch kind {
        case .complete: .backupComplete(body: "31 new · 6 removed")
        // Both built by the code the real notifications use, so a preview
        // can't drift from what actually arrives.
        case .failed:
            .backupFailed(
                message: FailureCopy.message(
                    kind: .volumeUnreachable, rawMessage: nil,
                    destination: destination ?? StatePreview.sampleDestination,
                    failedAt: .now
                ).plainText)
        case .stale:
            .stale(
                message: StalenessCheck.staleMessage(
                    history: [Self.sampleSuccess(daysAgo: 4)], thresholdDays: 1) ?? "")
        }
        Task { await KeptNotification.post(payload) }
    }
}
