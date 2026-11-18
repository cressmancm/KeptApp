import Foundation
import Photos

enum LibraryAccess {
    /// Where Kept's access to the library stands, from the Photos permission.
    enum Permission: Equatable, Sendable {
        /// Full Access.
        case granted
        /// Kept hasn't asked yet.
        case notAsked
        /// Limited Access: only the photos someone picked, which isn't the
        /// library. osxphotos reads the library's files, and Limited doesn't
        /// let it.
        case limited
        /// None, or not allowed on this Mac.
        case denied
    }

    /// Never prompts.
    static func permission() -> Permission {
        Self.permission(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func permission(from status: PHAuthorizationStatus) -> Permission {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notAsked
        case .limited: .limited
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Shows macOS's Photos prompt if Kept hasn't asked before, and returns
    /// the answer. After that, macOS answers without asking, and the
    /// permission can only be changed in System Settings.
    static func request() async -> Permission {
        permission(from: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    /// Whether Kept can read the Photos library right now, or nil when there
    /// is nothing at the default location to test against.
    ///
    /// osxphotos reads the library as ordinary files, and the Photos
    /// permission allows that when it's Full Access. Kept's signature has to
    /// carry the entitlement that lets macOS ask (app-entitlements.plist).
    /// Without it, as before 2026-11-18, macOS refused without asking and
    /// Kept needed Full Disk Access.
    ///
    /// Without the permission, nothing reads the library: a read raises the
    /// Photos prompt and waits for an answer, and at 2 AM nobody gives one.
    /// It waited out a 2-minute timeout in the 2026-11-18 test. So the check
    /// reads only when the permission says yes. Full Disk Access would read
    /// it too, but Kept doesn't look for it: the only file that tells is in
    /// the Photos app's data, and each refused read posts "Data Access
    /// Blocked". A Mac set up with an earlier Kept is asked for Photos once.
    ///
    /// The read is a real 1-byte read in a child process. A `stat` would not
    /// do: without access the file is still visible and only the read is
    /// refused. A child is also judged the way osxphotos will be, with this
    /// app as the responsible process.
    ///
    /// Shared by the controller (setup, the paused panel) and the engine, which
    /// runs it before every backup: without it, a backup without access
    /// failed inside osxphotos and was reported as "stopped partway".
    /// `stop` ends the probe early when the backup it's part of is stopped.
    static func canRead(stop: StopSignal? = nil) async -> Bool? {
        guard permission() == .granted else { return false }
        // Libraries can live outside ~/Pictures; no probe target means no
        // verdict. A real run will surface any permission problem loudly.
        guard FileManager.default.fileExists(atPath: Config.photosLibraryProbePath) else {
            return nil
        }
        let probe = await ShellCommand.run(
            "/usr/bin/head", ["-c", "1", Config.photosLibraryProbePath], timeout: 60,
            stop: stop)
        return probe.status == 0
    }
}
