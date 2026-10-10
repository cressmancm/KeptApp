import Foundation

enum LibraryAccess {
    /// Whether Kept can read the Photos library right now, or nil when there is
    /// nothing at the default location to test against.
    ///
    /// Access comes from Full Disk Access. osxphotos reads the library as
    /// ordinary files, and macOS judges an ordinary file read against Full Disk
    /// Access — which it never prompts for; it can only be switched on by hand
    /// in System Settings. Kept used to request PhotoKit authorization as well,
    /// but that prompt never appeared: the app is self-signed with no Team ID,
    /// and since the bundle identifier changed on 2026-08-13 the narrower
    /// Photos grant has been unobtainable. So nothing here asks for anything.
    ///
    /// The probe is a real 1-byte read in a child process. A `stat` would not
    /// do: without access the file is still visible and only the read is
    /// refused. A child also gets a fresh TCC evaluation with this app as the
    /// responsible process — exactly how osxphotos will be judged — which
    /// sidesteps in-process caching of the verdict after access is granted.
    /// The generous timeout is because a read that triggers a consent dialog
    /// waits for the dialog to be answered.
    ///
    /// Shared by the controller (setup, the paused panel) and the engine, which
    /// runs it before every backup: without it, a backup with Full Disk Access
    /// off failed inside osxphotos and was reported as "stopped partway".
    /// `stop` ends the probe early when the backup it's part of is stopped.
    static func canRead(stop: StopSignal? = nil) async -> Bool? {
        // Libraries can live outside ~/Pictures; no probe target means no
        // verdict — a real run will surface any permission problem loudly.
        guard FileManager.default.fileExists(atPath: Config.photosLibraryProbePath) else {
            return nil
        }
        let probe = await ShellCommand.run(
            "/usr/bin/head", ["-c", "1", Config.photosLibraryProbePath], timeout: 300,
            stop: stop)
        return probe.status == 0
    }
}
