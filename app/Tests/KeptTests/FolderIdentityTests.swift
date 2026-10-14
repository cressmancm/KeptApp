import XCTest

@testable import Kept

/// Production review S2 (Astra A4, Fable F2), 2026-10-13: the backup happens
/// in the folder that was chosen, not wherever its path leads now. Swapping
/// the chosen folder for a link to another folder on the same disk passed
/// every check, and the export, moves and deletions then worked in the link's
/// target.
final class FolderIdentityTests: XCTestCase {
    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // Its real path, so the folders below are chosen as the picker would.
        let made = fm.temporaryDirectory.appending(path: "KeptFolderIdentity-\(UUID().uuidString)")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        scratch = URL(filePath: try XCTUnwrap(Self.realPath(made.path)))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: scratch)
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : nil
    }

    /// The chosen folder, and a folder elsewhere the attacker would rather
    /// it were: here, one holding a file that isn't a photo.
    private func folders() throws -> (chosen: URL, elsewhere: URL) {
        let chosen = scratch.appending(path: "Mirror")
        let elsewhere = scratch.appending(path: "Documents")
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: elsewhere.appending(path: "taxes.pdf"))
        return (chosen, elsewhere)
    }

    /// The swap: the chosen folder moved aside, a link to elsewhere in its
    /// place.
    private func swapForLink(_ chosen: URL, to elsewhere: URL) throws {
        try fm.moveItem(at: chosen, to: scratch.appending(path: "Mirror-moved"))
        try fm.createSymbolicLink(at: chosen, withDestinationURL: elsewhere)
    }

    // MARK: - Paths

    func testOnlyTheSystemsOwnLinksAreTheSamePath() {
        XCTAssertTrue(NoFollow.isSamePath("/private/var/folders/x", "/var/folders/x"))
        XCTAssertTrue(NoFollow.isSamePath("/private/tmp", "/tmp"))
        XCTAssertTrue(NoFollow.isSamePath("/Volumes/PhotoBackup", "/Volumes/PhotoBackup/"))
        XCTAssertTrue(NoFollow.isSamePath("/Users/me/Mirror", "/users/ME/mirror"))
        XCTAssertFalse(NoFollow.isSamePath("/Users/me", "/Users/me/Mirror"))
        XCTAssertFalse(NoFollow.isSamePath("/Users/me/Documents", "/Users/me/Mirror"))
        XCTAssertFalse(NoFollow.isSamePath("/private/varx", "/varx"))
    }

    func testARootThroughALinkIsRefused() throws {
        let (chosen, elsewhere) = try folders()
        XCTAssertNoThrow(close(try NoFollow.openRoot(chosen.path)))
        try swapForLink(chosen, to: elsewhere)
        XCTAssertThrowsError(try NoFollow.openRoot(chosen.path))
        // A link higher up the path counts too.
        let linkedParent = scratch.appending(path: "Parent")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: scratch)
        XCTAssertThrowsError(
            try NoFollow.openRoot(linkedParent.appending(path: "Documents").path))
    }

    // MARK: - Choosing

    func testAFolderIsChosenByItsRealPathAndIdentity() throws {
        let (chosen, _) = try folders()
        let viaLink = scratch.appending(path: "Shortcut")
        try fm.createSymbolicLink(at: viaLink, withDestinationURL: chosen)

        let picked = Destination.from(folder: viaLink)
        XCTAssertEqual(picked.path, chosen.path)
        XCTAssertFalse(picked.isNetwork)
        var info = stat()
        XCTAssertEqual(stat(chosen.path, &info), 0)
        XCTAssertEqual(picked.folderID, UInt64(info.st_ino))
        XCTAssertNil(picked.folderMismatch())
    }

    // MARK: - Every backup

    func testAFolderSwappedForALinkIsCaught() throws {
        let (chosen, elsewhere) = try folders()
        let picked = Destination.from(folder: chosen)
        try swapForLink(chosen, to: elsewhere)
        let mismatch = try XCTUnwrap(picked.folderMismatch())
        XCTAssertTrue(mismatch.contains("leads to a different folder"), mismatch)
    }

    func testAnotherFolderMovedIntoItsPlaceIsCaught() throws {
        let (chosen, elsewhere) = try folders()
        let picked = Destination.from(folder: chosen)
        try fm.moveItem(at: chosen, to: scratch.appending(path: "Mirror-moved"))
        try fm.moveItem(at: elsewhere, to: chosen)
        let mismatch = try XCTUnwrap(picked.folderMismatch())
        XCTAssertTrue(mismatch.contains("another folder has taken its place"), mismatch)
    }

    /// A folder chosen before Kept recorded identities is still checked for
    /// links.
    func testAFolderWithoutAnIdentityIsStillCheckedForLinks() throws {
        let (chosen, elsewhere) = try folders()
        var picked = Destination.from(folder: chosen)
        picked.folderID = nil
        XCTAssertNil(picked.folderMismatch())
        try swapForLink(chosen, to: elsewhere)
        XCTAssertNotNil(picked.folderMismatch())
    }

    func testTheEngineRefusesASwappedFolderBeforeTheBackup() async throws {
        let (chosen, elsewhere) = try folders()
        let picked = Destination.from(folder: chosen)
        try swapForLink(chosen, to: elsewhere)
        let engine = BackupEngine(command: FakeCommands { _, _ in .ok() }.runner)
        nonisolated(unsafe) let log = try RunLog(in: scratch.appending(path: "logs"))
        do {
            try await engine.ensureDestinationReady(picked, log)
            XCTFail("A swapped folder was accepted")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
        }
    }

    /// Swapped after the checks at the start of the backup: refused again
    /// just before osxphotos would be given the path.
    func testASwapBeforeTheExportIsCaughtBeforeOsxphotosStarts() async throws {
        let (chosen, elsewhere) = try folders()
        let picked = Destination.from(folder: chosen)
        try swapForLink(chosen, to: elsewhere)
        let ran = scratch.appending(path: "osxphotos-ran")
        let python = scratch.appending(path: "python")
        try "#!/bin/sh\ntouch \"\(ran.path)\"\n".write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let engine = BackupEngine(
            python: python, exportGuard: ExportGuardTests.source, workingDirectory: scratch)
        nonisolated(unsafe) let log = try RunLog(in: scratch.appending(path: "logs"))
        do {
            _ = try await engine.runExport(picked, log, onProgress: { _ in }, onLogTail: { _ in })
            XCTFail("A swapped folder was exported to")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
        }
        XCTAssertFalse(fm.fileExists(atPath: ran.path))
        XCTAssertFalse(fm.fileExists(atPath: elsewhere.appending(path: ".osxphotos_keep").path))
    }

    // MARK: - The helpers

    /// `--hold-removed` is given the folder's path by the backup. Through a
    /// link, it moves nothing.
    func testHoldMovesNothingThroughALinkedFolder() throws {
        let (chosen, elsewhere) = try folders()
        try swapForLink(chosen, to: elsewhere)
        XCTAssertThrowsError(
            try RemovedPhotos.hold(chosen.appending(path: "taxes.pdf"), backupRoot: chosen))
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.appending(path: "taxes.pdf").path))
        XCTAssertFalse(fm.fileExists(
            atPath: elsewhere.appending(path: RemovedPhotos.folderName).path))
    }

    func testExpiryDeletesNothingThroughALinkedFolder() throws {
        let (chosen, elsewhere) = try folders()
        let old = elsewhere.appending(path: "\(RemovedPhotos.folderName)/2020-01-01")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try swapForLink(chosen, to: elsewhere)
        _ = RemovedPhotos.expire(backupRoot: chosen, retentionDays: 30)
        XCTAssertTrue(fm.fileExists(atPath: old.path))
    }
}
