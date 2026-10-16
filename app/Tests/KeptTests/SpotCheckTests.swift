import XCTest

@testable import Kept

/// Production review C2: a backup proves new files were copied, not that the
/// ones copied before are still intact. After each unattended backup Kept
/// compares a few files already in the backup with their originals, and the
/// next backup copies again any that don't match.
final class SpotCheckTests: XCTestCase {
    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let made = fm.temporaryDirectory.appending(path: "KeptSpotCheck-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        scratch = URL(filePath: String(cString: try XCTUnwrap(realpath(made.path, &buffer))))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: scratch)
    }

    // MARK: - The launcher's spot-check

    /// A backup of five photos and their originals, with a backup index
    /// naming them as osxphotos would. One copy is damaged, one gone (set
    /// aside by the export), one a link to a file elsewhere on the Mac, and
    /// one has an original that's changed since it was copied. The check runs in the bundled Python,
    /// with the library replaced by a lookup of the originals; skipped
    /// without one.
    private func checkBackup(count: Int = 50, seconds: Int = 60) async throws -> String {
        let python = try ExportArgumentsTests.bundledPython()
        let root = scratch.appending(path: "Mirror")
        let originals = scratch.appending(path: "originals")
        let outside = scratch.appending(path: "Documents")
        for folder in [root.appending(path: "2025/01"), originals, outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: outside.appending(path: "taxes.pdf"))
        for name in ["intact", "damaged", "gone", "linked", "edited"] {
            let bytes = Data("photo \(name) ".utf8 + [UInt8](repeating: 7, count: 3_000_000))
            try bytes.write(to: originals.appending(path: "\(name).jpg"))
            if name != "gone", name != "linked" {
                try bytes.write(to: root.appending(path: "2025/01/\(name).jpg"))
            }
        }
        // The same size, one byte different, deep in the file.
        let damaged = root.appending(path: "2025/01/damaged.jpg")
        var bytes = try Data(contentsOf: damaged)
        bytes[2_500_000] ^= 0xFF
        try bytes.write(to: damaged)
        try fm.createSymbolicLink(
            at: root.appending(path: "2025/01/linked.jpg"),
            withDestinationURL: outside.appending(path: "taxes.pdf"))

        let script = """
            import importlib.util, os, sqlite3, sys
            spec = importlib.util.spec_from_file_location("kept_export", sys.argv[1])
            guard = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(guard)
            scratch, count, seconds = sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
            originals = os.path.join(scratch, "originals")
            db_path = os.path.join(scratch, "export.db")
            db = sqlite3.connect(db_path)
            db.execute("CREATE TABLE export_data (id INTEGER PRIMARY KEY, filepath_normalized TEXT, "
                       "filepath TEXT, uuid TEXT, src_mode INTEGER, src_size INTEGER, src_mtime REAL, "
                       "dest_mode INTEGER, dest_size INTEGER, dest_mtime REAL, error JSON)")
            for name in ["intact", "damaged", "gone", "linked", "edited"]:
                info = os.stat(os.path.join(originals, name + ".jpg"))
                db.execute("INSERT INTO export_data (filepath_normalized, filepath, uuid, src_mode, "
                           "src_size, src_mtime, dest_mode, dest_size, dest_mtime) "
                           "VALUES (?, ?, ?, 32768, ?, ?, 32768, ?, ?)",
                           (f"2025/01/{name}.jpg", f"2025/01/{name}.jpg", name, info.st_size,
                            info.st_mtime, info.st_size, info.st_mtime))
            # A sidecar: never compared.
            db.execute("INSERT INTO export_data (filepath_normalized, filepath, uuid, dest_mode, "
                       "dest_size, dest_mtime) VALUES ('2025/01/intact.jpg.xmp', "
                       "'2025/01/intact.jpg.xmp', 'intact', 32768, 10, 0)")
            db.commit()
            db.close()
            # Edited in Photos since: no longer the file that was copied.
            with open(os.path.join(originals, "edited.jpg"), "ab") as edited:
                edited.write(b"more")
            sources = lambda uuid: [os.path.join(originals, uuid + ".jpg")]
            guard.spot_check(os.path.join(scratch, "Mirror"), db_path, "/no/library", count,
                             seconds, sources=sources)
            db = sqlite3.connect(db_path)
            for filepath, mode, size in db.execute(
                    "SELECT filepath, dest_mode, dest_size FROM export_data ORDER BY filepath"):
                print("index", filepath, "cleared" if mode is None and size is None else "kept")
            """
        let result = await ShellCommand.run(
            python,
            ["-I", "-B", "-c", script, ExportGuardTests.source.path, scratch.path, "\(count)",
             "\(seconds)"],
            timeout: 120)
        return result.stdout + result.stderr
    }

    func testADamagedCopyIsCopiedAgain() async throws {
        let output = try await checkBackup()
        XCTAssertTrue(output.contains("Spot-check: different: 2025/01/damaged.jpg"), output)
        // Intact and damaged were compared. Not the gone copy, which
        // --update copies again by itself if it still needs it, the link, or
        // the edited original.
        XCTAssertTrue(output.contains("Spot-check summary: 2 checked, 1 damaged, 3 skipped"), output)
        XCTAssertEqual(BackupEngine.parseSpotCheck(output), .init(checked: 2, damaged: 1))
        // The damaged copy loses its signature, so --update copies it again.
        // Nothing else in the index changes.
        for line in [
            "index 2025/01/damaged.jpg cleared", "index 2025/01/gone.jpg kept",
            "index 2025/01/intact.jpg kept", "index 2025/01/intact.jpg.xmp kept",
            "index 2025/01/linked.jpg kept", "index 2025/01/edited.jpg kept",
        ] {
            XCTAssertTrue(output.contains(line), "\(line)\n\(output)")
        }
    }

    /// The check reads the backup as the export writes it: never through a
    /// link. A planted one isn't read, and isn't called damage.
    func testALinkInTheBackupIsNotFollowed() async throws {
        let output = try await checkBackup()
        XCTAssertFalse(
            output.split(separator: "\n").contains { $0.hasPrefix("Spot-check:") && $0.contains("linked") },
            output)
        XCTAssertTrue(output.contains("Kept: 2025/01/linked.jpg in the backup folder is a link"), output)
        XCTAssertEqual(
            try String(contentsOf: scratch.appending(path: "Documents/taxes.pdf"), encoding: .utf8),
            "secret")
    }

    /// Found on the first check of a real backup, 2026-10-15: a photo in
    /// Recently Deleted is one osxphotos no longer copies, and its copy was
    /// set aside, but the index still names it. That's not a missing copy.
    /// Runs the launcher's own lookup against a stand-in for osxphotos.
    func testAPhotoInRecentlyDeletedIsSkipped() async throws {
        let python = try ExportArgumentsTests.bundledPython()
        let root = scratch.appending(path: "Mirror")
        try fm.createDirectory(at: root.appending(path: "2025"), withIntermediateDirectories: true)
        let original = scratch.appending(path: "deleted.jpg")
        try Data("photo".utf8).write(to: original)
        // Damaged, so that only being in Recently Deleted keeps it unchecked.
        try Data("PHOTO".utf8).write(to: root.appending(path: "2025/deleted.jpg"))
        let script = """
            import importlib.util, os, sqlite3, sys, types
            spec = importlib.util.spec_from_file_location("kept_export", sys.argv[1])
            guard = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(guard)
            scratch = sys.argv[2]
            original = os.path.join(scratch, "deleted.jpg")
            class Photo:
                path, path_edited, path_raw, path_live_photo, path_edited_live_photo = \\
                    original, None, None, None, None
                intrash = sys.argv[3] == "deleted"
            class PhotosDB:
                def __init__(self, dbfile): pass
                def get_photo(self, uuid): return Photo()
            sys.modules["osxphotos"] = types.SimpleNamespace(PhotosDB=PhotosDB)
            db_path = os.path.join(scratch, "export.db")
            db = sqlite3.connect(db_path)
            db.execute("CREATE TABLE IF NOT EXISTS export_data (id INTEGER PRIMARY KEY, "
                       "filepath TEXT, uuid TEXT, src_size INTEGER, src_mtime REAL, "
                       "dest_mode INTEGER, dest_size INTEGER, dest_mtime REAL, error JSON)")
            info = os.stat(original)
            db.execute("DELETE FROM export_data")
            db.execute("INSERT INTO export_data (filepath, uuid, src_size, src_mtime, dest_mode, "
                       "dest_size, dest_mtime) VALUES ('2025/deleted.jpg', 'X', ?, ?, 32768, ?, ?)",
                       (info.st_size, info.st_mtime, info.st_size, info.st_mtime))
            db.commit()
            guard.spot_check(os.path.join(scratch, "Mirror"), db_path, "/library", 20, 60)
            """
        for state in ["deleted", "in the library"] {
            let result = await ShellCommand.run(
                python,
                ["-I", "-B", "-c", script, ExportGuardTests.source.path, scratch.path, state],
                timeout: 60)
            let output = result.stdout + result.stderr
            XCTAssertTrue(
                output.contains(
                    state == "deleted"
                        ? "Spot-check summary: 0 checked, 0 damaged, 1 skipped"
                        : "Spot-check summary: 1 checked, 1 damaged, 0 skipped"),
                "\(state)\n\(output)")
        }
    }

    /// Out of time, the rest go unchecked rather than counted as damage.
    func testTheCheckStopsAtItsTimeLimit() async throws {
        let output = try await checkBackup(seconds: 0)
        XCTAssertTrue(output.contains("Spot-check summary: 0 checked, 0 damaged"), output)
        XCTAssertFalse(output.contains("cleared"), output)
    }

    // MARK: - The engine

    private func fakePython(_ body: String) throws -> URL {
        let url = scratch.appending(path: "python-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func spotCheck(_ body: String) async throws -> BackupEngine.SpotCheck? {
        let folder = scratch.appending(path: "Backup")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = BackupEngine(
            python: try fakePython(body), exportGuard: ExportGuardTests.source,
            workingDirectory: scratch)
        nonisolated(unsafe) let log = try RunLog(in: scratch.appending(path: "logs"))
        defer { log.close() }
        return await engine.spotCheck(
            Destination(path: folder.path, isNetwork: false), log, library: "/no/library")
    }

    func testTheEngineReadsTheSummary() async throws {
        let check = try await spotCheck("""
            echo "Spot-check: different: 2025/01/IMG_1.jpg"
            echo "Spot-check summary: 20 checked, 1 damaged, 3 skipped"
            """)
        XCTAssertEqual(check, .init(checked: 20, damaged: 1))
    }

    /// A check that fails says nothing about the backup, which already ran.
    func testAFailedCheckIsNotRecorded() async throws {
        let failed = try await spotCheck("echo 'Spot-check summary: 20 checked, 0 damaged'; exit 1")
        XCTAssertNil(failed)
        let silent = try await spotCheck("exit 0")
        XCTAssertNil(silent)
    }

    // MARK: - What the panel says

    private func success(errors: Int = 0, damaged: Int? = nil) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: .now)
        record.outcome = .success
        record.exported = 4
        record.errors = errors
        record.damaged = damaged
        return record
    }

    func testDamageMakesABackupIncomplete() {
        let record = success(damaged: 2)
        XCTAssertTrue(record.isPartial)
        XCTAssertEqual(RunFormatting.partialTitle(record), "Some photos aren't backed up")
        XCTAssertEqual(RunFormatting.notCopied(record), "2 damaged")
        XCTAssertEqual(
            RunFormatting.partialDetails(record),
            ["2 items in your backup no longer match your library. The next backup copies them again."])
        XCTAssertEqual(
            RunFormatting.damagedSentence(1),
            "1 item in your backup no longer matches your library. The next backup copies it again.")
        XCTAssertFalse(success().isPartial)
    }

    func testCopyErrorsAndDamageAreBothSaid() {
        let record = success(errors: 3, damaged: 1)
        XCTAssertEqual(RunFormatting.notCopied(record), "3 not copied · 1 damaged")
        XCTAssertEqual(
            RunFormatting.partialDetails(record),
            [RunFormatting.errorsSentence(3), RunFormatting.damagedSentence(1)])
    }

    /// Records from before the spot-check decode with none.
    func testOlderRecordsHaveNoSpotCheck() throws {
        let json = #"[{"id":"7ADF1A30-0EAB-4FBB-8B72-DBABE5BDB9F9","trigger":"scheduled","#
            + #""start":"2026-10-15T09:00:02Z","outcome":"success","errors":0}]"#
        let record = try XCTUnwrap(RunHistory.decode(Data(json.utf8))?.first)
        XCTAssertNil(record.spotChecked)
        XCTAssertNil(record.damaged)
        XCTAssertFalse(record.isPartial)
    }
}
