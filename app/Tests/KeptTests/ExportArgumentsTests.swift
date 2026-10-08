import XCTest

@testable import Kept

final class ExportArgumentsTests: XCTestCase {
    /// Kept's arguments, run past the real osxphotos. Its option checks happen
    /// before it opens the library, so this needs no Full Disk Access: on
    /// 2026-10-06 dropping --cleanup made --keep invalid, and every backup
    /// failed on "Incompatible export options" before copying anything.
    ///
    /// Throwaway paths, --dry-run and --limit 1, so it can't touch the real
    /// backup index or report. Skipped where Kept isn't installed.
    func testOsxphotosAcceptsKeptsArguments() async throws {
        let python = "/Applications/Kept.app/Contents/Resources/python/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "Kept isn't installed")

        let temp = FileManager.default.temporaryDirectory
            .appending(path: "KeptExportArgs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let dest = temp.appending(path: "dest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let arguments = BackupEngine.exportArguments(
            destinationPath: dest.path,
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
        let python = "/Applications/Kept.app/Contents/Resources/python/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "Kept isn't installed")

        let dest = FileManager.default.temporaryDirectory
            .appending(path: "KeptKeepFile-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dest) }
        let files = [
            "#recycle/bin.jpg", "2024/@eaDir/thumb.jpg", "@eaDir/top.jpg",
            "Removed from Photos/2026-10-01/older.jpg", "2024/03/01/IMG_1.jpg",
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
        XCTAssertEqual(kept, Set(files.dropLast()), result.stdout + result.stderr)
    }
}
