import XCTest

@testable import Kept

/// Production review S6: a backup must never be set aside because osxphotos
/// read a different, or empty, Photos library than the one it came from.
final class PhotosLibraryTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "KeptPhotosLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Which library

    private func writePlist(_ relative: String, _ contents: [String: Any]) throws {
        let url = scratch.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
            .write(to: url)
    }

    private let groupPlist =
        "Library/Group Containers/group.com.apple.photolibraryd.private/Library/Preferences/"
        + "group.com.apple.photolibraryd.private.plist"
    private let containerPlist =
        "Library/Containers/com.apple.photolibraryd/Data/Library/Preferences/"
        + "com.apple.photolibraryd.plist"

    /// macOS 27 keeps it in the group container, and leaves the old plist
    /// behind without the key.
    func testTheGroupContainerComesFirst() throws {
        try writePlist(groupPlist, ["SystemLibraryPath": "/Volumes/Photos/Family.photoslibrary"])
        try writePlist(containerPlist, ["Other": 1])
        XCTAssertEqual(
            PhotosLibrary.systemLibraryPath(home: scratch), "/Volumes/Photos/Family.photoslibrary")
    }

    /// macOS 26 and earlier.
    func testTheAppContainerIsTheFallback() throws {
        try writePlist(groupPlist, ["Other": 1])
        try writePlist(containerPlist, ["SystemLibraryPath": "/Users/me/Pictures/A.photoslibrary"])
        XCTAssertEqual(
            PhotosLibrary.systemLibraryPath(home: scratch), "/Users/me/Pictures/A.photoslibrary")
    }

    func testNoRecordMeansNoLibrary() {
        XCTAssertNil(PhotosLibrary.systemLibraryPath(home: scratch))
    }

    func testTheNameIsWhatTheFinderShows() {
        XCTAssertEqual(
            PhotosLibrary.displayName("/Users/me/Pictures/Photos Library.photoslibrary"),
            "Photos Library")
    }

    // MARK: - Comparing it with the backup

    func testDifferentOrEmptyLibrariesAreCaught() {
        typealias O = PhotosLibrary.Overlap
        XCTAssertTrue(O(inLibrary: 0, backedUp: 48_991, shared: 0).isDifferentLibrary)
        XCTAssertTrue(O(inLibrary: 3_000, backedUp: 48_991, shared: 12).isDifferentLibrary)
        XCTAssertTrue(O(inLibrary: 500, backedUp: 100, shared: 9).isDifferentLibrary)
        XCTAssertFalse(O(inLibrary: 500, backedUp: 100, shared: 10).isDifferentLibrary)
        // The maintainer's library on 2026-10-13.
        XCTAssertFalse(O(inLibrary: 49_499, backedUp: 48_991, shared: 48_458).isDifferentLibrary)
        // A first backup has nothing to protect.
        XCTAssertFalse(O(inLibrary: 0, backedUp: 0, shared: 0).isDifferentLibrary)
    }

    func testOnlySqlitesCountLineIsRead() {
        XCTAssertEqual(
            PhotosLibrary.parseOverlap("49499|48991|48458\n"),
            PhotosLibrary.Overlap(inLibrary: 49_499, backedUp: 48_991, shared: 48_458))
        XCTAssertNil(PhotosLibrary.parseOverlap(""))
        XCTAssertNil(PhotosLibrary.parseOverlap("Error: no such table: ZASSET"))
        XCTAssertNil(PhotosLibrary.parseOverlap("1|2"))
    }

    /// The real query, against stand-ins for Photos.sqlite and the backup
    /// index, with a quote in the index's path.
    func testTheOverlapIsCountedFromBothDatabases() async throws {
        let library = scratch.appending(path: "Photos.sqlite").path
        let index = scratch.appending(path: "Chip's Kept/export.db")
        try FileManager.default.createDirectory(
            at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = await ShellCommand.run(
            "/usr/bin/sqlite3",
            [library, "CREATE TABLE ZASSET (ZUUID TEXT); "
                + "INSERT INTO ZASSET VALUES ('a'), ('b'), ('c'), ('d');"],
            timeout: 30)
        XCTAssertEqual(made.status, 0, made.stderr)
        let indexed = await ShellCommand.run(
            "/usr/bin/sqlite3",
            [index.path, "CREATE TABLE export_data (uuid TEXT); "
                + "INSERT INTO export_data VALUES ('a'), ('a'), ('b'), ('x');"],
            timeout: 30)
        XCTAssertEqual(indexed.status, 0, indexed.stderr)

        let result = await ShellCommand.run(
            "/usr/bin/sqlite3",
            PhotosLibrary.overlapArguments(libraryDatabase: library, exportDatabase: index.path),
            timeout: 30)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            PhotosLibrary.parseOverlap(result.stdout),
            PhotosLibrary.Overlap(inLibrary: 4, backedUp: 3, shared: 2))
    }

    // MARK: - The engine

    private func libraryOnDisk(_ name: String = "Family") throws -> String {
        let library = scratch.appending(path: "\(name).photoslibrary")
        try FileManager.default.createDirectory(
            at: library.appending(path: "database"), withIntermediateDirectories: true)
        try Data().write(to: library.appending(path: "database/Photos.sqlite"))
        return library.path
    }

    private func engine(library: String?, sqlite: CommandResult) -> (BackupEngine, FakeCommands) {
        let commands = FakeCommands { call, _ in
            call.executable == "/usr/bin/sqlite3" ? sqlite : .ok()
        }
        let engine = BackupEngine(
            systemLibrary: { library },
            exportDatabase: scratch.appending(path: "export.db").path,
            command: commands.runner)
        return (engine, commands)
    }

    private let folder = Destination(path: "/Volumes/Photos/Backup", isNetwork: false)

    private func runLog() throws -> RunLog { try RunLog(in: scratch.appending(path: "logs")) }

    func testTheSystemLibraryIsNamedWhenItMatchesTheBackup() async throws {
        let library = try libraryOnDisk()
        let (engine, _) = engine(library: library, sqlite: .ok("49499|48991|48458\n"))
        nonisolated(unsafe) let log = try runLog()
        let source = try await engine.checkPhotosLibrary(folder, log)
        XCTAssertEqual(source, BackupEngine.ExportSource(library: library, cleanup: true))
    }

    func testAnEmptyLibraryLeavesTheBackupAlone() async throws {
        let (engine, _) = engine(library: try libraryOnDisk(), sqlite: .ok("0|48991|0\n"))
        nonisolated(unsafe) let log = try runLog()
        do {
            _ = try await engine.checkPhotosLibrary(folder, log)
            XCTFail("An empty library was accepted")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
            XCTAssertTrue(error.message.contains("has no photos"), error.message)
            XCTAssertTrue(error.message.contains("choose your backup folder again"), error.message)
        }
    }

    func testADifferentLibraryLeavesTheBackupAlone() async throws {
        let (engine, _) = engine(library: try libraryOnDisk("Work"), sqlite: .ok("3000|48991|12\n"))
        nonisolated(unsafe) let log = try runLog()
        do {
            _ = try await engine.checkPhotosLibrary(folder, log)
            XCTFail("A different library was accepted")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
            XCTAssertTrue(error.message.contains("Only 12 of the 48,991 photos"), error.message)
            XCTAssertTrue(error.message.contains("“Work”"), error.message)
        }
    }

    /// Choosing the folder again is the deliberate "yes, this library":
    /// the next backup takes it without the comparison.
    func testChoosingTheFolderAgainConfirmsTheLibrary() async throws {
        let library = try libraryOnDisk("Work")
        let (engine, commands) = engine(library: library, sqlite: .ok("3000|48991|12\n"))
        var confirmed = folder
        confirmed.libraryConfirmed = true
        nonisolated(unsafe) let log = try runLog()
        let source = try await engine.checkPhotosLibrary(confirmed, log)
        XCTAssertEqual(source, BackupEngine.ExportSource(library: library, cleanup: true))
        XCTAssertFalse(commands.executables.contains("/usr/bin/sqlite3"))
    }

    /// When the comparison can't run, new photos are still copied but
    /// nothing is set aside on a guess.
    func testAFailedComparisonBacksUpWithoutCleanup() async throws {
        let library = try libraryOnDisk()
        let (engine, _) = engine(library: library, sqlite: .failed("Error: database is locked"))
        nonisolated(unsafe) let log = try runLog()
        let source = try await engine.checkPhotosLibrary(folder, log)
        XCTAssertEqual(source, BackupEngine.ExportSource(library: library, cleanup: false))
    }

    func testAMissingLibraryIsSaidPlainly() async throws {
        let gone = scratch.appending(path: "Unplugged.photoslibrary").path
        let (engine, commands) = engine(library: gone, sqlite: .ok("1|1|1\n"))
        nonisolated(unsafe) let log = try runLog()
        do {
            _ = try await engine.checkPhotosLibrary(folder, log)
            XCTFail("A missing library was accepted")
        } catch let error as BackupError {
            XCTAssertTrue(error.message.contains("can't find your Photos library “Unplugged”"))
        }
        XCTAssertFalse(commands.executables.contains("/usr/bin/sqlite3"))
    }

    // MARK: - What osxphotos is told

    func testTheLibraryIsPassedAndCleanupCanBeLeftOut() {
        let named = BackupEngine.exportArguments(
            destinationPath: "/backup",
            source: BackupEngine.ExportSource(library: "/L.photoslibrary", cleanup: true))
        let at = try? XCTUnwrap(named.firstIndex(of: "--library"))
        XCTAssertEqual(at.map { named[$0 + 1] }, "/L.photoslibrary")
        XCTAssertTrue(named.contains("--cleanup-command"))

        let cautious = BackupEngine.exportArguments(
            destinationPath: "/backup",
            source: BackupEngine.ExportSource(library: "/L.photoslibrary", cleanup: false))
        XCTAssertFalse(cautious.contains("--cleanup-command"))
        XCTAssertFalse(cautious.contains("--cleanup"))
    }
}
