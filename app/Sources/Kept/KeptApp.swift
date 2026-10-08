import SwiftUI
import UserNotifications

/// Receives the "Launch Kept" notification action. Tapping it makes macOS
/// launch the bundle to deliver the response here, which *is* the launch the
/// user asked for — so there is nothing to do but accept it and let the app
/// finish starting. Registering the category again matters when the app is
/// already running and posts its own notifications.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([StalenessCheck.category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // The app is running by the time this arrives; that was the point.
        if response.actionIdentifier == StalenessCheck.launchActionIdentifier {
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// Without this, a notification posted while Kept is frontmost is silently
    /// swallowed rather than shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Entry point lives in main.swift, which picks between this and the headless
/// `--staleness-check` mode — hence no @main here.
struct KeptApp: App {
    @State private var controller = BackupController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            // Everything observable is read here, in the Scene body. Reading it
            // inside a nested label view instead leaves the icon stuck on its
            // first render: MenuBarExtra rebuilds its label when the scene
            // invalidates, not when a view inside it observes a change.
            //
            // The glyph is pre-rendered to a single Image because MenuBarExtra
            // renders only Image and Text in its label — see MenuBarGlyph.
            if let image = MenuBarGlyph.image(symbol: controller.menuBarSymbol) {
                Image(nsImage: image)
            } else {
                Image(systemName: controller.menuBarSymbol)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
    }
}
