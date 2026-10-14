import XCTest

@testable import Kept

/// Production review S3, 2026-10-13: osxphotos makes the date folders and
/// copies each photo by path, so a link planted in the backup folder, a
/// "2026" that's really a folder on this Mac, had photos put there, and with
/// --update overwrote what was there. Kept now runs osxphotos through its own
/// launcher, Python/kept_export.py, which refuses a link at any level of every
/// write. These run osxphotos' own file code under it, with the bundled
/// Python; skipped without one.
final class ExportGuardTests: XCTestCase {
    /// The launcher in this checkout.
    static let source = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Python/kept_export.py")

    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let made = fm.temporaryDirectory.appending(path: "KeptExportGuard-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        scratch = URL(filePath: String(cString: try XCTUnwrap(realpath(made.path, &buffer))))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: scratch)
    }

    /// Runs `body` in the bundled Python with the launcher installed for
    /// `<scratch>/Mirror`, next to `<scratch>/Documents`, the folder an
    /// attacker would rather the photos went to. Its stdout, with stderr.
    private func python(_ body: String) async throws -> String {
        let python = try ExportArgumentsTests.bundledPython()
        let script = """
            import importlib.util, os, sys, threading
            spec = importlib.util.spec_from_file_location("kept_export", sys.argv[1])
            guard = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(guard)
            scratch = sys.argv[2]
            root = os.path.join(scratch, "Mirror")
            outside = os.path.join(scratch, "Documents")
            src = os.path.join(scratch, "photo.jpg")
            guard.install(root)
            from osxphotos.fileutil import FileUtil
            import osxphotos.sidecars as sidecars
            def attempt(label, act):
                try:
                    act()
                    print("allowed", label)
                except OSError as error:
                    print("refused", label)

            """ + body
        let result = await ShellCommand.run(
            python, ["-I", "-B", "-c", script, Self.source.path, scratch.path], timeout: 120)
        return result.stdout + result.stderr
    }

    private func plant() throws {
        let root = scratch.appending(path: "Mirror")
        let outside = scratch.appending(path: "Documents")
        try fm.createDirectory(at: root.appending(path: "2025/01"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "taxes.pdf"))
        try Data("JPEG".utf8).write(to: scratch.appending(path: "photo.jpg"))
        // A linked year folder, and a linked photo where --update would
        // overwrite one.
        try fm.createSymbolicLink(at: root.appending(path: "2026"), withDestinationURL: outside)
        try fm.createSymbolicLink(
            at: root.appending(path: "2025/01/IMG_1.jpg"),
            withDestinationURL: outside.appending(path: "taxes.pdf"))
    }

    private func outsideIsUntouched(file: StaticString = #filePath, line: UInt = #line) throws {
        let outside = scratch.appending(path: "Documents")
        XCTAssertEqual(
            try fm.contentsOfDirectory(atPath: outside.path), ["taxes.pdf"], file: file, line: line)
        XCTAssertEqual(
            try String(contentsOf: outside.appending(path: "taxes.pdf"), encoding: .utf8), "secret",
            file: file, line: line)
    }

    func testEveryWriteThroughAPlantedLinkIsRefused() async throws {
        try plant()
        let output = try await python("""
            attempt("copy", lambda: FileUtil.copy(src, os.path.join(root, "2026/10/IMG.jpg")))
            attempt("makedirs", lambda: FileUtil.makedirs(os.path.join(root, "2026/10/14"), exist_ok=True))
            attempt("overwrite", lambda: FileUtil.copy(src, os.path.join(root, "2025/01/IMG_1.jpg")))
            attempt("utime", lambda: FileUtil.utime(os.path.join(root, "2025/01/IMG_1.jpg"), (0, 0)))
            attempt("rename", lambda: FileUtil.rename(src, os.path.join(root, "2026/IMG.jpg")))
            attempt("sidecar", lambda: sidecars.open(os.path.join(root, "2026/IMG.jpg.xmp"), "w"))
            attempt("open", lambda: open(os.path.join(root, "2026/IMG.jpg"), "w"))
            attempt("climb", lambda: FileUtil.copy(src, os.path.join(root, "2025/../2026/IMG.jpg")))
            """)
        for label in ["copy", "makedirs", "overwrite", "utime", "rename", "sidecar", "open", "climb"] {
            XCTAssertTrue(output.contains("refused \(label)\n"), "\(label): \(output)")
        }
        XCTAssertTrue(output.contains("Kept: 2026 in the backup folder is a link"), output)
        try outsideIsUntouched()
        XCTAssertTrue(fm.fileExists(atPath: scratch.appending(path: "photo.jpg").path))
    }

    /// What a backup does, still done: folders, copies, times, renames,
    /// sidecars and removals.
    func testAnOrdinaryExportStillWorks() async throws {
        try plant()
        let output = try await python("""
            day = os.path.join(root, "2024/05/06")
            attempt("makedirs", lambda: FileUtil.makedirs(day, exist_ok=True))
            attempt("copy", lambda: FileUtil.copy(src, os.path.join(day, "IMG_2.jpg")))
            attempt("copy into folder", lambda: FileUtil.copy(src, day))
            attempt("utime", lambda: FileUtil.utime(os.path.join(day, "IMG_2.jpg"), (1e9, 1e9)))
            attempt("rename", lambda: FileUtil.rename(os.path.join(day, "IMG_2.jpg"), os.path.join(day, "IMG_3.jpg")))
            attempt("sidecar", lambda: sidecars.open(os.path.join(day, "IMG_3.jpg.xmp"), "w").write("<x/>"))
            attempt("unlink", lambda: FileUtil.unlink(os.path.join(day, "photo.jpg")))
            attempt("elsewhere", lambda: FileUtil.copy(src, os.path.join(scratch, "copy.jpg")))
            print("mtime", int(os.stat(os.path.join(day, "IMG_3.jpg")).st_mtime))
            """)
        for label in [
            "makedirs", "copy", "copy into folder", "utime", "rename", "sidecar", "unlink", "elsewhere",
        ] {
            XCTAssertTrue(output.contains("allowed \(label)\n"), "\(label): \(output)")
        }
        XCTAssertTrue(output.contains("mtime 1000000000"), output)
        let day = scratch.appending(path: "Mirror/2024/05/06")
        XCTAssertEqual(
            Set(try fm.contentsOfDirectory(atPath: day.path)), ["IMG_3.jpg", "IMG_3.jpg.xmp"])
        XCTAssertEqual(try String(contentsOf: day.appending(path: "IMG_3.jpg"), encoding: .utf8), "JPEG")
        try outsideIsUntouched()
    }

    /// The race a check before the export couldn't close: the year folder
    /// swapped for a link and back, over and over, while photos are copied
    /// into it. Not one lands outside.
    func testASwapDuringTheExportSendsNothingOutside() async throws {
        try plant()
        try fm.removeItem(at: scratch.appending(path: "Mirror/2026"))
        let output = try await python("""
            year = os.path.join(root, "2026")
            real = os.path.join(scratch, "real-2026")
            os.makedirs(os.path.join(real, "10"))
            # So a copy that went through the link would land.
            os.makedirs(os.path.join(outside, "10"))
            done = threading.Event()
            def swap():
                # The attacker, so not held to the guard's rules.
                with guard._Ours():
                    while not done.is_set():
                        os.symlink(outside, year)
                        os.unlink(year)
                        os.rename(real, year)
                        os.rename(year, real)
            swapper = threading.Thread(target=swap)
            swapper.start()
            copied = refused = 0
            for n in range(400):
                try:
                    FileUtil.copy(src, os.path.join(year, "10", f"IMG_{n}.jpg"))
                    copied += 1
                except OSError:
                    refused += 1
            done.set()
            swapper.join()
            print("copied", copied, "refused", refused)
            """)
        XCTAssertTrue(output.contains("copied"), output)
        let landed = try fm.contentsOfDirectory(atPath: scratch.appending(path: "Documents/10").path)
        XCTAssertEqual(landed, [], output)
        let kept = try fm.contentsOfDirectory(atPath: scratch.appending(path: "real-2026/10").path)
        XCTAssertFalse(kept.isEmpty, output)
    }

    /// The launcher runs osxphotos itself, as `-m osxphotos` did.
    func testOsxphotosRunsThroughTheLauncher() async throws {
        let python = try ExportArgumentsTests.bundledPython()
        let root = scratch.appending(path: "Mirror")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await ShellCommand.run(
            python, ["-I", "-B", Self.source.path, root.path, "--version"], timeout: 120)
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("osxphotos"), result.stdout)
    }

    // MARK: - What Kept makes of it

    /// A refused link fails the backup with its own message, and isn't tried
    /// again: the link would still be there.
    func testARefusedLinkFailsTheBackupWithoutARetry() async throws {
        let count = scratch.appending(path: "count")
        let python = scratch.appending(path: "python")
        try """
            #!/bin/sh
            echo x >> "\(count.path)"
            echo "Kept: 2026 in the backup folder is a link. Not following it." >&2
            exit \(BackupEngine.linkRefusedStatus)
            """.write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let folder = scratch.appending(path: "Backup")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = BackupEngine(
            python: python, exportGuard: Self.source, workingDirectory: scratch)
        nonisolated(unsafe) let log = try RunLog(in: scratch.appending(path: "logs"))
        do {
            _ = try await engine.runExport(
                Destination.from(folder: folder), log, onProgress: { _ in }, onLogTail: { _ in })
            XCTFail("A refused link was a success")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
            XCTAssertEqual(error.message, BackupEngine.linkRefusedMessage)
        }
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "x\n")
    }

    func testNoLauncherMeansNoExport() async throws {
        let marker = scratch.appending(path: "python-ran")
        let python = scratch.appending(path: "python")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let folder = scratch.appending(path: "Backup")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Not in an app bundle, so Config has no launcher to fall back to.
        let engine = BackupEngine(python: python, workingDirectory: scratch)
        nonisolated(unsafe) let log = try RunLog(in: scratch.appending(path: "logs"))
        do {
            _ = try await engine.runExport(
                Destination.from(folder: folder), log, onProgress: { _ in }, onLogTail: { _ in })
            XCTFail("Exported without the launcher")
        } catch let error as BackupError {
            XCTAssertEqual(error.message, "Part of Kept is missing. Reinstall it.")
        }
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
        let tested = await engine.accessTest()
        XCTAssertEqual(tested, "Part of Kept is missing. Reinstall it.")
    }
}
