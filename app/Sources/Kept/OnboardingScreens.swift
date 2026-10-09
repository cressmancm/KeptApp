import SwiftUI
import UserNotifications

// The onboarding screens. The flow around them — paging, the width, which
// screen gets a dot footer — is in OnboardingView; the shapes they are built
// from are in OnboardingComponents.

// MARK: - 1 · Welcome

struct WelcomeScreen: View {
    let advance: () -> Void

    /// The setup steps, in the order the flow takes them.
    private static let steps = [
        "Turn on Full Disk Access",
        "Choose a backup folder",
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)

            Text("A second copy of every photo")
                .font(.system(size: 19, weight: .semibold))
                .kerning(OnboardingMetrics.headingKerning(19))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                """
                Every night, Kept copies your whole Photos library, edits and \
                videos included, into a folder you can open in the Finder.
                """
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineSpacing(OnboardingMetrics.lineSpacing(size: 13, lineHeight: 1.55))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 330)

            OnboardingCard(
                header: "SETUP TAKES TWO STEPS", spacing: 8,
                radius: OnboardingMetrics.stepCardRadius
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        NumberedStepRow(number: index + 1, text: step)
                    }
                }
            }

            OnboardingButton(
                "Get Started", horizontalPadding: 22, verticalPadding: 6, action: advance)

            Text("Nothing leaves your Mac and your network.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 14)
        .padding(.horizontal, 44)
        .padding(.bottom, 26)
    }
}

/// A numbered circle and its line of text. Centred rather than
/// baseline-aligned: the numeral is 9pt inside a 16pt disc, so matching
/// baselines with the 12pt label would sit the disc visibly low.
private struct NumberedStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 2 · Full Disk Access

struct FullDiskAccessScreen: View {
    let controller: BackupController
    let footer: OnboardingFooter

    /// What the live check last found. `unknown` is a library kept somewhere
    /// other than ~/Pictures, where there is no file to test — the screen says
    /// nothing then rather than guess.
    private enum Access { case checking, granted, missing, unknown }
    @State private var access = Access.checking

    var body: some View {
        // Nothing is requested here, because nothing can be: macOS never
        // prompts for Full Disk Access. The screen's job is to get the user to
        // the switch, and then to show them it worked.
        PermissionScreen(
            symbol: "photo.on.rectangle.angled",
            title: "Turn on Full Disk Access",
            message: """
                macOS won't ask for this one. Turn it on yourself so Kept can read \
                your library. Kept never changes or uploads your photos.
                """,
            cardHeader: "IN SYSTEM SETTINGS",
            footer: footer
        ) {
            SettingsPaneIllustration()
        } annotation: {
            AnnotationLine(Text("\(AnnotationLine.arrow) Switch on **Kept**."))
            AnnotationLine(Text("Not listed? Click **+** and add Kept from Applications."))
            AnnotationLine(Text("If asked to quit Kept, choose **Later**."))
        } accessory: {
            HStack(spacing: 10) {
                AccessStatusLine(
                    granted: access == .granted ? true : access == .missing ? false : nil)
                Spacer(minLength: 8)
                OnboardingButton(
                    "Open Full Disk Access…", kind: .secondary, size: 12,
                    horizontalPadding: 12, verticalPadding: 4
                ) {
                    controller.openFullDiskAccessSettings()
                }
            }
        }
        // Re-checked while the screen is up, so flipping the switch in System
        // Settings shows up here without the user doing anything else. The
        // check is a child process, which is also why "Later" is safe: a fresh
        // process sees the new grant without Kept being relaunched. Cancelled
        // with the screen.
        .task {
            while !Task.isCancelled {
                switch await controller.canReadLibrary() {
                case true?: access = .granted
                case false?: access = .missing
                case nil: access = .unknown
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// "Access is on" / "Waiting for access…", or nothing when there is no verdict.
private struct AccessStatusLine: View {
    let granted: Bool?

    var body: some View {
        if let granted {
            HStack(spacing: 6) {
                Circle().fill(granted ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(granted ? "Access is on" : "Waiting for access…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Shared permission-screen skeleton

/// Screen 2: a header, a labelled card holding an illustration with a
/// note beside it, an optional row of controls under the card, and the footer.
private struct PermissionScreen<Illustration: View, Annotation: View, Accessory: View>: View {
    let symbol: String
    let title: String
    let message: String
    let cardHeader: String
    let footer: OnboardingFooter
    @ViewBuilder var illustration: Illustration
    @ViewBuilder var annotation: Annotation
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .kerning(OnboardingMetrics.headingKerning(17))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(OnboardingMetrics.lineSpacing(size: 12, lineHeight: 1.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            OnboardingCard(
                header: cardHeader,
                padding: EdgeInsets(top: 13, leading: 13, bottom: 13, trailing: 13)
            ) {
                HStack(alignment: .top, spacing: 14) {
                    illustration
                    VStack(alignment: .leading, spacing: 5) { annotation }
                }
            }

            accessory
            footer
        }
        .padding(.top, 4)
        .padding(.horizontal, 30)
        .padding(.bottom, 22)
    }
}

/// One line of the note beside the illustration.
private struct AnnotationLine: View {
    /// The accent arrow that points the first note back at the illustration beside
    /// it. Interpolated into the line rather than concatenated, because
    /// `Text + Text` is deprecated as of macOS 26.
    static let arrow = Text("←").foregroundStyle(Color.accentColor)

    let text: Text

    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineSpacing(OnboardingMetrics.lineSpacing(size: 11.5, lineHeight: 1.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A picture of the Full Disk Access list in System Settings with Kept switched
/// on — never a working copy of it.
///
/// Everything here is drawn. The switch
/// is two shapes rather than a `Toggle` and the + and − are text, so nothing in
/// it invites a click that does nothing. The real list is one button away.
private struct SettingsPaneIllustration: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Disk Access")
                .font(.system(size: 11.5, weight: .semibold))
            HStack(spacing: 8) {
                // The app's real icon, so the row matches what the user is
                // about to look for in the actual list.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text("Kept")
                    .font(.system(size: 11.5))
                Spacer(minLength: 8)
                drawnSwitch
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(OnboardingMetrics.cardFill, in: RoundedRectangle(cornerRadius: 6))
            Text("+    −")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 5)
        }
        .illustrationSurface(
            padding: EdgeInsets(top: 13, leading: 14, bottom: 11, trailing: 14),
            alignment: .leading)
    }

    /// On, in the accent colour, the way System Settings draws it.
    private var drawnSwitch: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 26, height: 15)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .padding(1)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
    }
}

private extension View {
    /// The raised, bordered sheet the illustration sits on: 238pt wide, so
    /// the note beside it gets the rest of the card.
    func illustrationSurface(padding: EdgeInsets, alignment: Alignment) -> some View {
        self
            .padding(padding)
            .frame(width: 238, alignment: alignment)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: OnboardingMetrics.dialogRadius))
            .overlay(
                RoundedRectangle(cornerRadius: OnboardingMetrics.dialogRadius)
                    .stroke(OnboardingMetrics.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 9, y: 6)
    }
}

// MARK: - 3 · Choose the folder

struct ChooseFolderScreen: View {
    let controller: BackupController
    let footer: OnboardingFooter

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a backup folder")
                    .font(.system(size: 17, weight: .semibold))
                    .kerning(OnboardingMetrics.headingKerning(17))
                    .fixedSize(horizontal: false, vertical: true)
                Text("""
                    Your photos are saved as ordinary files you can open anytime. \
                    Photos you delete from your library are removed here too, \
                    after \(controller.removedRetentionDays) days.
                    """)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(OnboardingMetrics.lineSpacing(size: 12, lineHeight: 1.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            destinationRow
            statusCard
            footer
        }
        .padding(.top, 4)
        .padding(.horizontal, 30)
        .padding(.bottom, 22)
        .onAppear { controller.refreshDestinationStats() }
    }

    /// The same folder picker Settings uses, warnings and all — a destination
    /// chosen here has to clear exactly the same guardrails.
    private var destinationRow: some View {
        HStack(spacing: 9) {
            Image(systemName: controller.destination?.symbolName ?? "questionmark.folder")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.destination?.displayName ?? "No folder chosen yet")
                    .font(.system(size: 12.5, weight: .medium))
                if let subtitle = destinationSubtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 9)
            Button {
                controller.chooseDestination()
            } label: {
                // "Choose…" until there is something to change: on a real first
                // run this row is empty, which is the whole reason the screen
                // exists.
                Text(controller.destination == nil ? "Choose…" : "Change…")
                    .font(.system(size: 12))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(
                        OnboardingMetrics.controlFill,
                        in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: OnboardingMetrics.stepCardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingMetrics.stepCardRadius)
                .stroke(OnboardingMetrics.hairline, lineWidth: 1))
    }

    /// The share URL identifies a network folder; a local disk has only a path.
    private var destinationSubtitle: String? {
        guard let destination = controller.destination else { return nil }
        return destination.smbURL ?? destination.path
    }

    /// Hidden until there is a folder to describe — with nothing chosen there
    /// is no volume to call mounted, and Continue is disabled anyway.
    @ViewBuilder
    private var statusCard: some View {
        if controller.destination != nil {
            OnboardingCard {
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(controller.destinationIsMounted ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                        // Nudged onto the first line's optical centre; a 6pt dot
                        // top-aligned against 11.5pt text reads as floating.
                        .padding(.top, 4)
                    Text(RunFormatting.firstCopyPlan(
                        mounted: controller.destinationIsMounted,
                        freeBytes: controller.destinationFreeBytes,
                        itemCount: controller.mirroredItemCount))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(OnboardingMetrics.lineSpacing(size: 11.5, lineHeight: 1.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 4 · Done

struct DoneScreen: View {
    let controller: BackupController
    let backUpNow: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.green)

            Text("You're all set")
                .font(.system(size: 19, weight: .semibold))
                .kerning(OnboardingMetrics.headingKerning(19))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(bodyText)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(OnboardingMetrics.lineSpacing(size: 12.5, lineHeight: 1.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            HStack(spacing: 9) {
                OnboardingButton("Back Up Now", kind: .secondary, action: backUpNow)
                OnboardingButton("Done", action: done)
            }
        }
        .padding(.top, 10)
        .padding(.horizontal, 44)
        .padding(.bottom, 26)
    }

    /// The scheduled time is read live rather than hardcoded to the design's
    /// 2:00 AM — and the phrase degrades to a whole sentence when the cadence
    /// is Manually and there is no time to name.
    private var bodyText: String {
        let phrase = RunFormatting.firstBackupPhrase(controller.nextRun, cadence: controller.cadence)
        // Done is what raises the notification prompt, so this says what it's
        // for first. Left out when the choice is already made (a reinstall).
        let notifications = controller.notificationAuthorization == .notDetermined
            ? " Allow notifications when macOS asks, so Kept can warn you if backups stop."
            : ""
        // Under Manually the phrase already ends by pointing at the menubar,
        // and there's no scheduled backup to "check on".
        guard controller.cadence != .manual else { return phrase + notifications }
        return phrase + " Check on it anytime from the menubar." + notifications
    }
}
