import AppKit
import SwiftUI

/// Hosts the first-run flow in a window of its own.
///
/// Not `NSApp.runModal`, despite the design calling the window modal. A modal
/// run loop would block the main-actor work the flow is built on — the live
/// access check on screen 2, the destination probe on screen 4 —
/// and Kept is `LSUIElement`, so there is no app menu for modality to disable
/// in the first place. "Modal" here means what the design means by it: one
/// window, dealt with once, before anything else happens.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// The live flow, held for as long as its window is on screen. Without a
    /// reference at this level the controller deallocates the moment
    /// `showIfNeeded` returns and takes the window down with it.
    private static var current: OnboardingWindowController?

    private var window: NSWindow?
    /// Held so the close handler can tell the controller the flow was
    /// abandoned. Safe to keep strongly: the controller outlives this window.
    private var controller: BackupController?

    static func showIfNeeded(controller: BackupController) {
        guard !controller.hasCompletedOnboarding else { return }
        // A second call while the flow is already up should raise that window,
        // not open a rival copy of it.
        if let current {
            NSApp.activate(ignoringOtherApps: true)
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        show(controller: controller, startingAt: 1)
    }

    /// Opens the flow at a chosen screen, whether or not it has been completed.
    /// Settings → Advanced uses this to review a single screen.
    ///
    /// A flow already on screen is closed and replaced rather than raised: the
    /// caller asked for a particular page, and raising a window sitting on a
    /// different one would silently ignore that.
    static func show(controller: BackupController, startingAt page: Int) {
        current?.window?.close()
        let flow = OnboardingWindowController()
        current = flow
        flow.present(controller: controller, startingAt: page)
    }

    private func present(controller: BackupController, startingAt page: Int) {
        self.controller = controller
        let hosting = NSHostingController(
            rootView: OnboardingView(
                controller: controller,
                dismiss: { [weak self] in self?.window?.close() },
                startPage: page))
        // Deliberately NOT `sizingOptions = [.preferredContentSize]`. That asks
        // the hosting controller to push a new preferred size up to the window
        // as the SwiftUI content resolves, and text-driven content resolves
        // during AppKit's own constraint pass — which re-enters it and throws
        // from -[NSWindow _postWindowNeedsUpdateConstraints]. The window sizes
        // from the hosting view's intrinsic content size instead.

        let window = NSWindow(contentViewController: hosting)
        // Neither .resizable nor .miniaturizable: close is the only control.
        window.styleMask = [.titled, .closable]
        window.title = "Welcome to Kept"
        // The controller owns the window's lifetime, so AppKit must not also
        // release it out from under us when it closes.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // Ordering a window front does not bring an accessory app forward, and
        // a first-run window that opens behind the user's browser is a first
        // run that never happens.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Finishing the flow closes the window too, but sets the flag first —
        // so this only reports a genuinely abandoned setup.
        if let controller, !controller.hasCompletedOnboarding {
            Task { await controller.onboardingDismissedEarly() }
        }
        window = nil
        controller = nil
        Self.current = nil
    }
}
