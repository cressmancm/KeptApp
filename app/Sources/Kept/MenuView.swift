import SwiftUI

/// The menubar panel. Every state answers one question at the top — is the
/// library safe, and if not, what do I do about it — and pushes configuration
/// into the Settings window.
struct MenuView: View {
    let controller: BackupController

    var body: some View {
        // Every relative string here — "3 hours ago", "Today, 8:25 AM", the
        // Today/Yesterday headings, "tonight at 2:00 AM" — is derived from the
        // current time, but nothing else in the panel depends on the clock. A
        // MenuBarExtra with .window style builds its content once and then only
        // shows and hides the window, so without this the strings freeze at
        // whatever they were when the view was first built and never update
        // again, however many times the panel is reopened.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 0) {
                if let preview = controller.preview {
                    PreviewBanner(controller: controller, scenario: preview.scenario)
                }
                switch controller.displayStatus {
                case .needsDestination:
                    FirstRunPanel(controller: controller)
                case .needsPhotosAccess:
                    AccessBlockedPanel(controller: controller)
                case .running(let progress):
                    RunningPanel(controller: controller, progress: progress)
                case .failed(let kind, let message):
                    FailedPanel(
                        controller: controller, kind: kind, message: message, now: context.date)
                case .waitingForPower:
                    WaitingForPowerPanel(controller: controller, now: context.date)
                case .idle:
                    HealthyPanel(controller: controller, now: context.date)
                }
            }
        }
        .frame(width: Metrics.panelWidth)
        .onAppear { controller.refreshDestinationStats() }
    }
}

/// Says, on the panel itself, that none of what follows is true.
///
/// The state preview in Settings → Advanced exists so every screen can be
/// reviewed, which means it can put "Your library is Kept up-to-date" in front
/// of someone whose last backup failed. A strip the preview cannot be seen
/// without — and a way out of it that doesn't require finding Settings again —
/// is the price of that.
private struct PreviewBanner: View {
    let controller: BackupController
    let scenario: PreviewScenario

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.fill")
                .font(.system(size: 9))
            Text("Preview · \(scenario.label)")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button("Exit") { controller.clearPreview() }
                .buttonStyle(.plain)
                .underline()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Color.orange)
        .padding(.vertical, 5)
        .padding(.horizontal, Metrics.sectionPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14))
    }
}

// MARK: - Healthy

private struct HealthyPanel: View {
    let controller: BackupController
    let now: Date
    @AppStorage(Preferences.recentRunsExpanded) private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            PanelSection {
                if let last = controller.lastSuccess {
                    StatusRow(
                        symbol: "checkmark.circle.fill", tint: .green,
                        title: "Your photos are backed up",
                        subtitle: RunFormatting.healthySubtitle(last, now: now))
                } else {
                    // Destination chosen but nothing has run yet — true, and
                    // not a problem, so it gets a neutral glyph rather than a
                    // green tick it hasn't earned.
                    StatusRow(
                        symbol: "photo.on.rectangle", tint: .secondary,
                        title: "Ready to back up",
                        subtitle: "No backups yet")
                }

                DestinationFacts(controller: controller, now: now)

                Button("Back Up Now") { controller.startBackup(.manual) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            RecentRunsView(controller: controller, isExpanded: $isExpanded, now: now)
            Divider()
            // Open Report lives in Settings → Advanced; the panel footer stays
            // Settings and Quit in every state.
            FooterBar {}
        }
    }
}

/// The two facts worth showing without asking: where the mirror lives and how
/// much room is left, and when it next runs.
private struct DestinationFacts: View {
    let controller: BackupController
    let now: Date

    var body: some View {
        InfoCard {
            if let destination = controller.displayDestination {
                FactRow(
                    symbol: destination.isNetwork
                        ? "externaldrive.connected.to.line.below" : "externaldrive",
                    label: "Backs up to \(locationName(destination))",
                    value: controller.destinationFreeBytes.map {
                        "\(RunFormatting.bytes($0)) free"
                    })
            }
            FactRow(
                symbol: "clock",
                label: RunFormatting.nextRunPhrase(
                    controller.nextRun, cadence: controller.cadence, now: now))
        }
    }

    private func locationName(_ destination: Destination) -> String {
        if destination.isNetwork, let smb = destination.smbURL,
            let host = URL(string: smb)?.host() {
            return host
        }
        return destination.displayName
    }
}

// MARK: - Running

private struct RunningPanel: View {
    let controller: BackupController
    let progress: ExportProgress
    @AppStorage(Preferences.liveLogExpanded) private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            PanelSection {
                StatusRow(title: "Backing up", subtitle: subtitle) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 22, height: 22)
                }

                // Gated on the phase, not merely on having a fraction. Once the
                // export ends, current and total stay equal — so the fraction
                // is still 1.0 through cleaning and finishing, and this branch
                // would keep showing the last exported filename at 100% while
                // the log says "Cleaning up".
                if progress.phase == .exporting, let fraction = progress.fractionComplete {
                    ThinProgressBar(fraction: fraction)
                    HStack {
                        Text(progress.currentItemName ?? progress.phase.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    // Scanning, cleaning, finishing: nothing meaningful to
                    // count, so the phase name replaces bar, file and percent.
                    ProgressView().progressViewStyle(.linear)
                    Text(progress.phase.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Stop Backup") { controller.cancelBackup() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            LiveLogView(controller: controller, isExpanded: $isExpanded)
            Divider()
            FooterBar {}
        }
    }

    /// nil before osxphotos announces a total: the phase is already showing in
    /// the detail row under the bar, and saying "Starting" twice tells the user
    /// nothing the first one didn't.
    private var subtitle: String? {
        // Same reason as the detail row: "46,937 of 46,937 items" is a
        // leftover once the copying is done and cleanup has started.
        guard progress.phase == .exporting, progress.total > 0 else { return nil }
        var text = "\(progress.current.formatted(.number)) "
            + "of \(progress.total.formatted(.number)) items"
        if let remaining = RunFormatting.timeRemaining(controller.estimatedTimeRemaining) {
            text += " · \(remaining)"
        }
        return text
    }
}

private struct LiveLogView: View {
    let controller: BackupController
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            DisclosureHeader(label: "Log", isExpanded: $isExpanded) { EmptyView() }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.displayLogTail.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.sectionPaddingH)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Failed

private struct FailedPanel: View {
    let controller: BackupController
    let kind: FailureKind
    let message: String
    let now: Date
    /// Local, not persisted: the design opens this state with the runs
    /// expanded, and the view is rebuilt each time the panel opens.
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            PanelSection {
                StatusRow(
                    symbol: "exclamationmark.circle.fill", tint: .red,
                    title: "Last backup failed",
                    subtitle: FailureCopy.lastGoodCopy(controller.lastSuccess, now: now))

                InfoCard(fill: Color.red.opacity(0.08)) {
                    failureText
                        .font(.caption)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Try Again") { controller.startBackup(.manual) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Button("Open Log") { controller.openLastLog() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }

            Divider()
            RecentRunsView(controller: controller, isExpanded: $isExpanded, now: now)
            Divider()
            FooterBar {}
        }
    }

    /// Only copy we wrote is parsed as markdown; the engine's own message is
    /// rendered verbatim. See FailureCopy.Message.
    @ViewBuilder
    private var failureText: some View {
        switch FailureCopy.message(
            kind: kind, rawMessage: message,
            destination: controller.destination,
            failedAt: controller.displayHistory.last?.start) {
        case .authored(let markdown):
            Text(.init(markdown))
        case .verbatim(let raw):
            Text(verbatim: raw)
        }
    }
}

// MARK: - Waiting for power

/// Deliberately not the failed panel: nothing broke, nothing was attempted, and
/// the remedy is a cable rather than a diagnosis. It still offers Back Up Now,
/// because an attended run on battery is the user's call to make.
private struct WaitingForPowerPanel: View {
    let controller: BackupController
    let now: Date
    @AppStorage(Preferences.recentRunsExpanded) private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            PanelSection {
                StatusRow(
                    symbol: "powerplug", tint: .orange,
                    title: "Waiting for power",
                    subtitle: controller.lastSuccess.map {
                        RunFormatting.healthySubtitle($0, now: now)
                    } ?? "No backups yet")

                InfoCard {
                    Text("Plug in and the backup starts on its own. "
                        + "On battery, your Mac can sleep partway through.")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DestinationFacts(controller: controller, now: now)

                Button("Back Up Anyway") { controller.startBackup(.manual) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Divider()
            RecentRunsView(controller: controller, isExpanded: $isExpanded, now: now)
            Divider()
            FooterBar {}
        }
    }
}

// MARK: - Library access blocked

private struct AccessBlockedPanel: View {
    let controller: BackupController

    var body: some View {
        VStack(spacing: 0) {
            PanelSection {
                StatusRow(
                    symbol: "exclamationmark.circle.fill", tint: .orange,
                    title: "Backups are paused",
                    subtitle: "Kept can't read your Photos library")

                // One step. There used to be a second, Network Volumes in Files &
                // Folders, but Full Disk Access covers network drives too: with it
                // on, macOS never asks about them.
                InfoCard(spacing: 8) {
                    Text("Turn on Kept in **Full Disk Access**.")
                        .font(.caption)
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Open Full Disk Access…") { controller.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                // Documents the 5-second re-probe in BackupController.start():
                // granting access flips this panel without the user coming back.
                HStack(spacing: 5) {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                    Text("Updates on its own once access is on")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
            }

            Divider()
            FooterBar {}
        }
    }
}

// MARK: - First run

private struct FirstRunPanel: View {
    let controller: BackupController

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 2)

                Text("Choose a backup folder")
                    .font(.system(size: 14, weight: .semibold))

                // Both sentences wrap rather than truncate: without fixedSize the
                // panel's layout gives each one line, and they ended in "…".
                Text("Kept copies your whole Photos library to one folder, every night.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Choose Backup Folder…") { controller.chooseDestination() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Text("Backups run nightly at \(scheduledTime). You can change this in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
            HStack {
                Spacer()
                FooterButton(title: "Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
        }
    }

    private var scheduledTime: String {
        let components = DateComponents(
            hour: controller.scheduledHour, minute: controller.scheduledMinute)
        guard let date = Calendar.current.date(from: components) else { return "2:00 AM" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
