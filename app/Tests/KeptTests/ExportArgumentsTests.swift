import XCTest

@testable import Kept

final class ExportArgumentsTests: XCTestCase {
    /// Kept's arguments, run past the real osxphotos. Its option checks happen
    /// before it opens the library, so this needs no Full Disk Access: on
    /// 2026-10-06 dropping --cleanup made --keep invalid, and every backup
    /// failed on "Incompatible export options" before copying anything.
    ///
    /// Throwaway paths, --dry-run and --limit 1, so it can't touch the real
    /// backup index or report. Skipped where there's no bundled Python.
    func testOsxphotosAcceptsKeptsArguments() async throws {
        let python = try Self.bundledPython()

        let temp = FileManager.default.temporaryDirectory
            .appending(path: "KeptExportArgs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let dest = temp.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let arguments = BackupEngine.exportArguments(
            destinationPath: dest.path,
            exportGuard: ExportGuardTests.source.path,
            exportDB: temp.appending(path: "export.db").path,
            report: temp.appending(path: "report.csv").path)
            + ["--dry-run", "--limit", "1"]
        func run(_ arguments: [String]) async -> String {
            // From the temp folder, so a crash log lands there, not in the repo.
            let result = await ShellCommand.run(
                "/bin/sh",
                ["-c", "cd \"$1\" && shift && exec \"$@\"", "sh", temp.path, python] + arguments,
                timeout: 120)
            return result.stdout + result.stderr
        }

        let output = await run(arguments)
        XCTAssertFalse(output.contains("Incompatible export options"), output)
        XCTAssertFalse(output.contains("No such option"), output)
        XCTAssertFalse(output.contains("Usage:"), output)

        // The control: the flag that broke backups is caught by this same run,
        // so a pass above means the check was reached, not skipped.
        let broken = await run(arguments + ["--keep", "#recycle"])
        XCTAssertTrue(broken.contains("Incompatible export options"), broken)
    }

    /// The keep file Kept writes, read by osxphotos' own code: everything in
    /// Synology's folders and the holding folder is protected, and an
    /// ordinary photo isn't. The first version wrote "#recycle" unescaped,
    /// which the file format reads as a comment.
    func testOsxphotosKeepsWhatTheKeepFileNames() async throws {
        let python = try Self.bundledPython()

        let dest = FileManager.default.temporaryDirectory
            .appending(path: "KeptKeepFile-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dest) }
        let files = [
            "#recycle/bin.jpg", "2024/@eaDir/thumb.jpg", "@eaDir/top.jpg",
            "Removed from Photos/2026-10-01/older.jpg",
            // A disk's own folders, when the backup folder is its root.
            ".Trashes/501/document.pdf", ".Spotlight-V100/Store-V2/index",
            "System Volume Information/IndexerVolumeGuid",
            // A Photos library anywhere inside, at any depth.
            "Old/Photos Library.photoslibrary/originals/A/IMG_9.heic",
            "2024/03/01/IMG_1.jpg",
        ]
        for file in files {
            let url = dest.appending(path: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try RemovedPhotos.writeKeepRules(backupRoot: dest)

        let script = """
            import sys
            from osxphotos.cli.export import collect_files_to_keep
            files, _ = collect_files_to_keep((), sys.argv[1])
            for f in sorted(files): print(f[len(sys.argv[1]) + 1:])
            """
        let result = await ShellCommand.run(python, ["-I", "-B", "-c", script, dest.path], timeout: 60)
        let kept = Set(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
        // The keep file itself too: osxphotos never touches it anyway, and the
        // hidden-files rule names it.
        XCTAssertEqual(
            kept, Set(files.dropLast() + [".osxphotos_keep"]), result.stdout + result.stderr)
    }

    /// The Python `bundle-python.sh` built next to this package, so the tests
    /// check the osxphotos this checkout will ship. Falls back to an
    /// installed Kept, and skips when there is neither.
    ///
    /// `KEPT_TEST_PYTHON` names the interpreter outright: CI points it at the
    /// app it just built. Named and missing is a failure, not a skip, so a
    /// broken bundle can't pass by being skipped.
    static func bundledPython() throws -> String {
        if let named = ProcessInfo.processInfo.environment["KEPT_TEST_PYTHON"], !named.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: named) else {
                throw NamedPythonMissing(path: named)
            }
            return named
        }
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            package.appending(path: ".build/python-env/bin/python3").path,
            "/Applications/Kept.app/Contents/Resources/python/bin/python3",
        ]
        guard let python = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
        else { throw XCTSkip("No bundled Python: run bundle-python.sh, or install Kept") }
        return python
    }
}

private struct NamedPythonMissing: Error, CustomStringConvertible {
    let path: String
    var description: String { "KEPT_TEST_PYTHON names \(path), which isn't an executable" }
}
