import SwiftUI

/// Everything configurable, moved out of the popover. Three tabs, so the
/// panel can stay a status readout and the diagnostics have somewhere to live.
struct SettingsView: View {
    let controller: BackupController

    var body: some View {
        TabView {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            ScheduleSettings(controller: controller)
                .tabItem { Label("Schedule", systemImage: "clock") }
            AdvancedSettings(controller: controller)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        // 560 rather than 520: the 130pt right-aligned label column and its
        // 14pt gutter take that much off every control column, and the General
        // tab's staleness row was the one that ran out of room first.
        .frame(width: 560)
        .background(ClearInitialFocus())
    }
}

/// Opens Settings with nothing focused.
///
/// With Keyboard navigation turned on in System Settings, AppKit hands initial
/// focus to the first toolbar item, the General tab, and macOS draws that focus
/// as a blue glow on its icon whenever the window is active — so it reads as a
/// selection stuck on General, whichever tab is open. Clearing the first
/// responder leaves focus unset until the user presses Tab, which is how most
/// Mac settings windows open.
private struct ClearInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusClearingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class FocusClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Deferred: AppKit picks the initial first responder as the window
            // is ordered front, which happens after this view is installed.
            Task { @MainActor in window.makeFirstResponder(nil) }
        }
    }
}

/// Label column right-aligned at a fixed width, controls flush left after it.
private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .frame(width: 130, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TabBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var controller: BackupController

    var body: some View {
        TabBody {
            SettingsRow(label: "Backup folder:") {
                // The field takes the full column and the button moves down to
                // the status line: sharing the row with "Change…" cost the path
                // ~90pt, which was most of what got truncated away.
                destinationField
                HStack(spacing: 10) {
                    mountStatus
                    Spacer(minLength: 12)
                    // A backup carries on to the folder it started with, so the
                    // folder waits until it's done.
                    Button("Change…") { controller.chooseDestination() }
                        .disabled(controller.isRunning || controller.isUninstalling)
                        .help(controller.isRunning ? "You can change it after this backup." : "")
                }
            }

            SettingsRow(label: "Deleted photos:") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Keep in the backup for")
                        Picker("", selection: $controller.removedRetentionDays) {
                            ForEach(RemovedPhotos.retentionChoices, id: \.self) { days in
                                Text("\(days) days").tag(days)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("They wait in the “Removed from Photos” folder, then are deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 330, alignment: .leading)
                }
            }

            Divider()

            SettingsRow(label: "Options:") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Open at login", isOn: $controller.openAtLogin)
                    if let error = controller.loginItemError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 330, alignment: .leading)
                    }
                    Toggle("Notify me when a backup fails", isOn: $controller.notifyOnFailure)
                    Toggle("Notify me after every backup", isOn: $controller.notifyAlways)

                    VStack(alignment: .leading, spacing: 4) {
                        // The label is a whole sentence on its own; the interval
                        // sits on the line below rather than finishing it.
                        Toggle("Warn me if backups stop", isOn: $controller.stalenessWarningEnabled)
                        // Interval on its own line, indented to align with the
                        // checkbox's text, so it can grow to "14 days" without
                        // pushing anything off the end of the row.
                        HStack(spacing: 6) {
                            Text("After")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $controller.stalenessDays) {
                                ForEach([1, 2, 3, 5, 7, 14], id: \.self) { days in
                                    Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        .padding(.leading, 21)
                        .disabled(!controller.stalenessWarningEnabled)
                        Text("Works even when Kept isn't running.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 330, alignment: .leading)
                        if let error = controller.displayStalenessAgentError {
                            Label("Couldn't turn on this warning: \(error)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let stale = controller.displayStalenessAgentStaleWarning() {
                            // Registration succeeding is not the same as launchd
                            // being able to run it; this reports the difference.
                            Label(stale, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if controller.notificationsAreOff {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "Notifications are off for Kept, so none of these can reach you.",
                                systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 330, alignment: .leading)
                            Button("Turn On…") { controller.openNotificationSettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .onAppear {
            controller.refreshDestinationStats()
            controller.refreshNotificationAuthorization()
        }
    }

    private var destinationField: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: destinationSymbol)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.destination?.displayName ?? "None")
                    .font(.system(size: 12, weight: .medium))
                // The share URL and the mount path get a line each rather than
                // being joined with a separator — together they were long
                // enough that middle-truncation ate the hostname, which is the
                // most identifying part of the whole line.
                ForEach(destinationLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1))
        // Backstop for a path long enough to truncate even on its own line.
        .help(destinationTooltip)
    }

    private var destinationSymbol: String {
        controller.destination?.symbolName ?? "questionmark.folder"
    }

    /// The SMB URL and the mount path — the two things you need to tell one
    /// backup folder from another. A local disk has only the one.
    private var destinationLines: [String] {
        guard let destination = controller.destination else { return [] }
        var lines: [String] = []
        if let address = destination.shareAddress { lines.append(address) }
        lines.append(destination.path)
        return lines
    }

    private var destinationTooltip: String {
        guard !destinationLines.isEmpty else { return "No backup folder chosen yet." }
        return destinationLines.joined(separator: "\n")
    }

    private var mountStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.destinationIsMounted ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(mountStatusText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var mountStatusText: String {
        guard controller.destinationIsMounted else { return "Not connected" }
        var parts = ["Connected"]
        if let free = controller.destinationFreeBytes {
            parts.append("\(RunFormatting.bytes(free)) free")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Schedule

private struct ScheduleSettings: View {
    @Bindable var controller: BackupController

    var body: some View {
        TabBody {
            SettingsRow(label: "Back up:") {
                HStack(spacing: 10) {
                    Picker("", selection: $controller.cadence) {
                        ForEach(BackupCadence.allCases, id: \.self) { cadence in
                            Text(cadence.label).tag(cadence)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()

                    if controller.cadence == .weekly {
                        Picker("", selection: $controller.weeklyWeekday) {
                            ForEach(Array(weekdayNames.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index + 1)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SettingsRow(label: "At:") {
                HStack(spacing: 10) {
                    DatePicker(
                        "", selection: $controller.scheduleTime,
                        displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                    Text(nextRunText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(controller.cadence == .manual)
            }

            SettingsRow(label: "") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Catch up on missed backups", isOn: $controller.catchUpEnabled)
                    Text("If your Mac was asleep, back up when it wakes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Nothing is scheduled under Manually, so there is nothing to
                // miss — the preference is already inert, and this says so.
                .disabled(controller.cadence == .manual)
            }
        }
    }

    /// Calendar's weekday numbering starts at Sunday, and so does this list —
    /// the index+1 tag in the picker depends on that.
    private var weekdayNames: [String] {
        var calendar = Calendar.current
        calendar.locale = .autoupdatingCurrent
        return calendar.standaloneWeekdaySymbols
    }

    private var nextRunText: String {
        RunFormatting.nextRunShort(controller.nextRun, cadence: controller.cadence)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Bindable var controller: BackupController

    /// The review tools (forced panel states, the menubar glyph, onboarding
    /// screens, sample warnings, alerts and notifications) are for whoever is
    /// working on Kept, not for the people using it. Only debug and local
    /// builds have them (ReviewTools.swift). There, they appear when Option is
    /// held as this tab opens, and stay while anything they forced is still
    /// forced — hiding them then would strand a fake state with no way back
    /// to Live.
    @State private var showsReviewTools = false

    var body: some View {
        Group {
            if showsReviewTools {
                // With the review tools showing, this tab carries every preview
                // in the app, and a Settings window taller than the screen is
                // its own kind of broken — so it scrolls, at a fixed height.
                ScrollView { tabContent }
                    .frame(height: 460)
            } else {
                // Without them it is three short rows and sizes to fit, like
                // the other tabs. Never a ScrollView here: one has no height of
                // its own to offer the window, which is what cut off the
                // Uninstall row when the tools were first hidden.
                tabContent
            }
        }
        .onAppear {
            #if KEPT_REVIEW_TOOLS
            showsReviewTools =
                NSEvent.modifierFlags.contains(.option) || controller.hasAnyPreview
            #endif
        }
    }

    private var tabContent: some View {
        TabBody {
            #if KEPT_REVIEW_TOOLS
            // Review tools. See `showsReviewTools`.
            if showsReviewTools {
                ReviewToolsSection(controller: controller)
            }
            #endif

            SettingsRow(label: "Diagnostics:") {
                // Wraps onto a second line rather than clipping if the labels
                // run long under a different locale.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        testButton
                        logsButton
                        reportButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            testButton
                            logsButton
                        }
                        reportButton
                    }
                }
                accessTestResult
            }

            Divider()

            SettingsRow(label: "Version:") {
                Text(versionLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Check for updates", isOn: $controller.checkForUpdates)
                    Text("Once a day, Kept asks GitHub for the latest version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 330, alignment: .leading)
                }
                if let update = controller.displayAvailableUpdate {
                    HStack(spacing: 8) {
                        Text("Kept \(update.version) is available.")
                        Button("Download") { controller.openUpdatePage() }
                            .controlSize(.small)
                    }
                    .font(.caption)
                }
            }
            .onAppear { controller.checkForUpdatesIfDue() }

            Divider()

            SettingsRow(label: "Uninstall:") {
                Button("Remove Kept…", role: .destructive) { controller.beginUninstall() }
                    .disabled(controller.isRunning || controller.isUninstalling)
                Text("Removes Kept and everything it installed. Your backup folder "
                    + "isn't touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }
        }
    }

    private var testButton: some View {
        Button("Test Library Access") { controller.runAccessTest() }
            .disabled(controller.isRunning)
    }

    private var logsButton: some View {
        Button("Reveal Logs…") { controller.openLogsFolder() }
    }

    private var reportButton: some View {
        Button("Open Report") { controller.openReport() }
    }

    @ViewBuilder
    private var accessTestResult: some View {
        if let result = controller.accessTestResult {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if result == "Testing…" {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text("Testing…")
                } else {
                    Image(systemName: result.hasPrefix("OK")
                        ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(result.hasPrefix("OK") ? Color.green : Color.red)
                    Text(friendlyResult(result))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The engine reports "OK — exported 5, missing 0, errors 0"; the row says
    /// only what that means. The counts are in access-test.log.
    private func friendlyResult(_ result: String) -> String {
        guard result.hasPrefix("OK") else { return result }
        return "Kept can read your library"
    }

    private var versionLine: String {
        var text = "Kept \(Config.appVersion)"
        if let osxphotos = Config.osxphotosVersion {
            text += " · osxphotos \(osxphotos)"
        }
        return text
    }
}

#if KEPT_REVIEW_TOOLS
/// The review tools at the top of the Advanced tab. See `showsReviewTools`.
private struct ReviewToolsSection: View {
    @Bindable var controller: BackupController

    /// Which onboarding screen the picker is aimed at. View state, not app
    /// state: it selects what to open, and opening it changes nothing.
    @State private var onboardingPage = 1

    private static let onboardingScreens = [
        "1 · Welcome",
        "2 · Full Disk Access",
        "3 · Choose folder",
        "4 · Done",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsRow(label: "Panel state:") {
                scenarioPicker
                Text(previewNote)
                    .font(.caption)
                    .foregroundStyle(controller.isPreviewing ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Divider()

            SettingsRow(label: "Menubar glyph:") {
                // Forces the icon into each state so it can be checked
                // without unplugging the NAS or waiting for a backup to
                // fail. Separate from the panel picker above, which already
                // carries the icon with it — this one is for the two "needs
                // you" states that deliberately share a glyph.
                Picker("", selection: $controller.glyphPreview) {
                    Text("Live").tag(BackupController.GlyphState?.none)
                    Divider()
                    ForEach(BackupController.GlyphState.allCases) { state in
                        Text(state.label).tag(BackupController.GlyphState?.some(state))
                    }
                }
                .labelsHidden()
                .fixedSize()

                Text(controller.glyphPreview == nil
                    ? "Following the panel: \(controller.glyphState.label.lowercased())."
                    : "Forced. Set back to Live when you're done.")
                    .font(.caption)
                    .foregroundStyle(controller.glyphPreview == nil
                        ? Color.secondary : Color.orange)
            }

            Divider()

            SettingsRow(label: "Onboarding:") {
                HStack(spacing: 8) {
                    Picker("", selection: $onboardingPage) {
                        ForEach(Array(Self.onboardingScreens.enumerated()), id: \.offset) {
                            index, name in
                            Text(name).tag(index + 1)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Open Screen") {
                        controller.showOnboarding(startingAt: onboardingPage)
                    }
                }
                Button("Replay First Run") { controller.resetOnboarding() }
                Text("Open Screen shows one screen. Replay First Run starts setup over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Divider()

            SettingsRow(label: "Warnings:") {
                Picker("", selection: $controller.stalenessWarningPreview) {
                    Text("Live").tag(BackupController.StalenessWarningPreview?.none)
                    Divider()
                    ForEach(BackupController.StalenessWarningPreview.allCases) { warning in
                        Text(warning.label)
                            .tag(BackupController.StalenessWarningPreview?.some(warning))
                    }
                }
                .labelsHidden()
                .fixedSize()

                Text(controller.stalenessWarningPreview == nil
                    ? "Shows the warnings under \"Warn me if backups stop\" on the "
                        + "General tab."
                    : "Forced. The General tab isn't reporting a real problem.")
                    .font(.caption)
                    .foregroundStyle(controller.stalenessWarningPreview == nil
                        ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Divider()

            SettingsRow(label: "Update:") {
                Toggle("Show “update available”", isOn: $controller.updatePreview)
                Text("Shows a sample update in the panel and on this tab. Nothing is checked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Divider()

            SettingsRow(label: "Alerts:") {
                HStack(spacing: 8) {
                    ForEach(BackupController.PreviewDialog.allCases) { dialog in
                        Button(dialog.label) { controller.showPreviewDialog(dialog) }
                    }
                }
                Text("Shows the folder picker's two warnings. Nothing is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Divider()

            SettingsRow(label: "Notifications:") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { notificationButtons }
                    VStack(alignment: .leading, spacing: 8) { notificationButtons }
                }
                Text("Sends a real notification, even if notifications are off on the "
                    + "General tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)
            }

            Divider()
        }
    }

    /// Live plus every scenario, grouped the way `PreviewScenario.Group` orders
    /// them so seventeen entries don't arrive as one undifferentiated list.
    private var scenarioPicker: some View {
        HStack(spacing: 8) {
            Picker("", selection: $controller.previewScenario) {
                Text("Live").tag(PreviewScenario?.none)
                ForEach(PreviewScenario.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(PreviewScenario.allCases.filter { $0.group == group }) { scenario in
                            Text(scenario.label).tag(PreviewScenario?.some(scenario))
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()

            if controller.hasAnyPreview {
                Button("Back to Live") { controller.clearPreview() }
            }
        }
    }

    /// Says what the selected state is for, and — while one is forced — what it
    /// costs. A preview is dropped the moment a real backup starts or ends, and
    /// the panel has to be opened by hand to be seen at all; both are worth
    /// saying here rather than leaving to be discovered.
    private var previewNote: String {
        guard let preview = controller.preview else {
            return "Shows the menubar panel in any state. Uses sample data; your history "
                + "isn't touched."
        }
        return "\(preview.scenario.note) Click the menubar icon to see it. "
            + "Ends when a backup runs or Kept quits."
    }

    @ViewBuilder
    private var notificationButtons: some View {
        ForEach(BackupController.PreviewNotification.allCases) { kind in
            Button(kind.label) { controller.postPreviewNotification(kind) }
        }
    }
}
#endif
