import AppKit
import Foundation

// Under Xcode's tests the app is the test host: XCTest loads the test bundle
// into it once it has finished launching. Nothing of Kept's own may start then.
// Claiming the single instance would quit the Kept you use, and the scheduler
// would run real backups. So the host only runs an empty application.
if Config.isTestHost {
    MainActor.assumeIsolated { NSApplication.shared.run() }
    exit(0)
}

// Kept has three modes, chosen before any UI exists.
//
// `--staleness-check` is the LaunchAgent's headless invocation: it reads the
// run history, may post a notification, and exits — it must never become the
// menubar app, or the watchdog would resurrect an app the user deliberately
// quit. That decision has to happen ahead of SwiftUI, which is why this file
// exists and `KeptApp` no longer carries @main.
if CommandLine.arguments.contains("--staleness-check") {
    StalenessCheck.runAndExit()
}

// `--hold-removed <file>` is osxphotos' cleanup command, run once per file the
// mirror would delete. Same rule: no UI, do the one thing, exit.
if CommandLine.arguments.contains("--hold-removed") {
    RemovedPhotos.runHoldAndExit(arguments: CommandLine.arguments)
}

// Opened straight from a download, macOS runs Kept from a temporary copy whose
// path would go into the login item and the daily check. Move first, before
// this copy claims anything or quits the installed one.
if AppLocation.isTranslocated {
    MainActor.assumeIsolated { AppLocation.offerMoveAndExit() }
}

// Everything past here is the menubar app, and there must only be one.
SingleInstance.claim()

// Kept's first identifier was com.chip.Kept. Carried over once, after any copy
// still running under it has quit and before anything reads a preference.
IdentityMigration.runIfNeeded()

KeptApp.main()
