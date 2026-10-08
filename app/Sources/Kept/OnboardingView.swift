import SwiftUI

/// The first-run flow, in one window, shown before Kept asks the system for
/// anything.
///
/// This file owns the frame around the screens — paging, the width the design
/// pins at 480, and which screen gets the dot footer. The screens themselves
/// live in OnboardingScreens.swift.
struct OnboardingView: View {
    let controller: BackupController
    /// Closes the hosting window. Owned by OnboardingWindowController, because
    /// a SwiftUI view inside an AppKit-hosted window has no dismiss action of
    /// its own to reach for.
    let dismiss: () -> Void

    /// The screens, numbered as Settings → Advanced lists them.
    enum Step: Int, CaseIterable {
        case welcome = 1, fullDiskAccess, folder, done
    }

    @State private var step: Step

    /// `startPage` is a Step number: 1 for a genuine first run; Settings →
    /// Advanced passes the others to review one screen at a time.
    init(controller: BackupController, dismiss: @escaping () -> Void, startPage: Int = 1) {
        self.controller = controller
        self.dismiss = dismiss
        _step = State(initialValue: Step(rawValue: startPage) ?? .welcome)
    }

    /// No network drive screen: Full Disk Access covers network drives, so
    /// with it on macOS never asks about them. (There was one, explaining a
    /// prompt that, since Kept moved to Full Disk Access, never came.)
    private var steps: [Step] { Step.allCases }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .welcome:
                WelcomeScreen(advance: advance)
            case .fullDiskAccess:
                FullDiskAccessScreen(controller: controller, footer: footer())
            case .folder:
                ChooseFolderScreen(
                    controller: controller,
                    footer: footer(continueDisabled: controller.destination == nil))
            case .done:
                DoneScreen(
                    controller: controller,
                    backUpNow: { controller.startBackup(.manual); finish() },
                    done: finish)
            }
        }
        .frame(width: OnboardingMetrics.windowWidth)
        // The window is sized from this view's ideal height, which is what lets
        // each screen be as tall as its own content needs.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(continueDisabled: Bool = false) -> OnboardingFooter {
        OnboardingFooter(
            page: (steps.firstIndex(of: step) ?? 0) + 1,
            pageCount: steps.count,
            continueDisabled: continueDisabled,
            back: goBack,
            advance: advance)
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    private func goBack() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    /// Both exits from the last screen agree on one thing: the flow is done and
    /// must not reappear.
    private func finish() {
        controller.completeOnboarding()
        dismiss()
    }
}
