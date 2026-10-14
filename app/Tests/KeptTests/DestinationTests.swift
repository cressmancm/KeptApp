import XCTest

@testable import Kept

final class DestinationTests: XCTestCase {
    func testSMBURLDerivedFromMountFrom() {
        XCTAssertEqual(
            Destination.smbURL(fromMountFrom: "//user@nas.local/PhotoBackup"),
            "smb://user@nas.local/PhotoBackup")
        XCTAssertEqual(
            Destination.smbURL(fromMountFrom: "//host/share"),
            "smb://host/share")
        XCTAssertNil(Destination.smbURL(fromMountFrom: "/dev/disk3s1"))
        XCTAssertNil(Destination.smbURL(fromMountFrom: ""))
    }

    func testEffectivelyEmpty() {
        XCTAssertTrue(Destination.isEffectivelyEmpty(entries: []))
        XCTAssertTrue(
            Destination.isEffectivelyEmpty(entries: [".DS_Store", "#recycle", "@eaDir"]))
        XCTAssertFalse(Destination.isEffectivelyEmpty(entries: ["2026"]))
        XCTAssertFalse(Destination.isEffectivelyEmpty(entries: [".DS_Store", "photo.jpg"]))
    }

    func testFromLocalFolderCapturesLocalVolume() {
        let dest = Destination.from(folder: FileManager.default.temporaryDirectory)
        XCTAssertFalse(dest.isNetwork)
        XCTAssertNil(dest.smbURL)
        XCTAssertNil(dest.mountPoint)
    }

    func testCodableRoundTrip() throws {
        let dest = Destination(
            path: "/Volumes/PhotoBackup", isNetwork: true,
            smbURL: "smb://user@nas.local/PhotoBackup",
            mountPoint: "/Volumes/PhotoBackup")
        let decoded = try JSONDecoder().decode(
            Destination.self, from: JSONEncoder().encode(dest))
        XCTAssertEqual(decoded, dest)
    }

    // MARK: - Volume identity

    func testFromLocalFolderRecordsTheVolumeUUID() {
        let dest = Destination.from(folder: FileManager.default.temporaryDirectory)
        XCTAssertNotNil(dest.volumeUUID)
        XCTAssertNil(dest.volumeMismatch())
    }

    /// A disk image or another disk mounted under the same name has a
    /// different UUID, and must not be backed up to.
    func testADifferentDiskUnderTheSamePathIsRefused() {
        var dest = Destination.from(folder: FileManager.default.temporaryDirectory)
        dest.volumeUUID = UUID().uuidString
        XCTAssertNotNil(dest.volumeMismatch())
    }

    /// A share's mount point with a local disk at it now.
    func testALocalDiskWhereAShareWasIsRefused() {
        let dest = Destination(
            path: FileManager.default.temporaryDirectory.path, isNetwork: true,
            smbURL: "smb://nas.local/PhotoBackup", mountPoint: "/Volumes/PhotoBackup")
        XCTAssertNotNil(dest.volumeMismatch())
    }

    /// Chosen before Kept recorded a UUID: nothing to compare, so allowed.
    func testALocalFolderWithoutARecordedUUIDIsAllowed() {
        let dest = Destination(path: FileManager.default.temporaryDirectory.path, isNetwork: false)
        XCTAssertNil(dest.volumeMismatch())
    }

    func testDestinationsSavedWithoutAUUIDStillDecode() throws {
        let old = #"{"path":"/Volumes/Backup","isNetwork":false}"#
        let dest = try JSONDecoder().decode(Destination.self, from: Data(old.utf8))
        XCTAssertNil(dest.volumeUUID)
    }

    func testTheSameShareMatchesHoweverTheHostIsNamed() {
        let saved = "smb://chip@nas.local/PhotoBackup"
        for mounted in [
            "smb://chip@nas.local/PhotoBackup", "smb://nas._smb._tcp.local/PhotoBackup",
            "smb://other@NAS.local:445/photobackup", "smb://nas/PhotoBackup/",
        ] {
            XCTAssertTrue(Destination.isSameShare(saved, mounted), mounted)
        }
        for mounted in [
            "smb://evil.local/PhotoBackup", "smb://nas.local/Other",
            "smb://localhost/PhotoBackup", "not a url",
        ] {
            XCTAssertFalse(Destination.isSameShare(saved, mounted), mounted)
        }
    }

    func testARawSpaceInTheMountSourceIsEncoded() {
        XCTAssertEqual(
            Destination.smbURL(fromMountFrom: "//nas.local/Photo Backup"),
            "smb://nas.local/Photo%20Backup")
    }

    // MARK: - Folders whose contents aren't Kept's

    func testPhotosLibrariesAreRefused() {
        XCTAssertEqual(
            Destination.refusal(path: "/Volumes/SSD/Photos Library.photoslibrary"),
            .insidePhotosLibrary)
        XCTAssertEqual(
            Destination.refusal(path: "/Volumes/SSD/My.PhotosLibrary/originals"),
            .insidePhotosLibrary)
        XCTAssertEqual(
            Destination.refusal(
                path: "/Volumes/SSD", entries: [".Trashes", "Photos Library.photoslibrary"]),
            .holdsPhotosLibrary)
        XCTAssertNil(Destination.refusal(path: "/Volumes/SSD/Backup", entries: ["2024"]))
    }

    func testCloudFolderRootsAreRefused() {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library").path
        for path in [
            "\(library)/Mobile Documents",
            "\(library)/Mobile Documents/com~apple~CloudDocs",
            "\(library)/CloudStorage",
            "\(library)/CloudStorage/Dropbox",
            "\(library)/CloudStorage/GoogleDrive-me@example.com/My Drive",
        ] {
            XCTAssertEqual(Destination.refusal(path: path), .cloudFolder, path)
        }
        for path in [
            "\(library)/Mobile Documents/com~apple~CloudDocs/Photo Backup",
            "\(library)/CloudStorage/Dropbox/Photo Backup",
        ] {
            XCTAssertNil(Destination.refusal(path: path), path)
        }
    }

    // MARK: - Kept's own folders (production review S5)

    /// Removing Kept deletes these, so a backup in one would go with it, and
    /// a backup that held one would move Kept's own files aside.
    func testKeptsOwnFoldersAreRefused() {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library").path
        for path in [
            "\(library)/Application Support/Kept",
            "\(library)/Application Support/Kept/Photo Backup",
            "\(library)/Logs/Kept/Photo Backup",
            "\(library)/logs/KEPT/Photo Backup",
            "\(library)/Application Support",
            "\(library)/Logs",
            "\(library)/Logs/Kept/../Kept/Photo Backup",
        ] {
            XCTAssertEqual(Destination.refusal(path: path), .keptsOwnFolder, path)
        }
        for path in [
            "\(library)/Application Support/Kept Backup",
            "\(library)/Logs/Other",
            "/Volumes/Photos/Backup",
        ] {
            XCTAssertNotEqual(Destination.refusal(path: path), .keptsOwnFolder, path)
        }
    }

    func testTheAppItselfIsRefused() {
        let owned = Destination.keptsOwnFolders(bundle: URL(filePath: "/Applications/Kept.app"))
        XCTAssertEqual(
            Destination.refusal(path: "/Applications/Kept.app/Contents", owned: owned),
            .keptsOwnFolder)
        // A bare binary has no bundle to protect.
        XCTAssertEqual(
            Destination.keptsOwnFolders(bundle: URL(filePath: "/usr/local/bin")).count, 2)
    }

    /// Kept's folder reached through a link: the picker checks the folder with
    /// links resolved, and Kept's own folders are compared resolved too.
    func testALinkToKeptsOwnFolderIsRefused() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "KeptOwned-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        let real = scratch.appending(path: "Real/Kept")
        try fm.createDirectory(at: real.appending(path: "Backup"), withIntermediateDirectories: true)
        let link = scratch.appending(path: "Link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        // Kept's folder is the link; the backup is chosen at the real path.
        XCTAssertEqual(
            Destination.refusal(path: real.appending(path: "Backup").path, owned: [link]),
            .keptsOwnFolder)
        // The backup is chosen through the link, as the picker resolves it.
        let picked = link.appending(path: "Backup")
        XCTAssertEqual(
            Destination.refusal(path: picked.resolvingSymlinksInPath().path, owned: [real]),
            .keptsOwnFolder)
    }

    /// A folder chosen before Kept refused these is refused before every
    /// backup, before anything is moved.
    func testTheEngineRefusesABackupInKeptsOwnFolder() async throws {
        let engine = BackupEngine(command: FakeCommands { _, _ in .ok() }.runner)
        let logs = FileManager.default.temporaryDirectory
            .appending(path: "KeptOwnedEngine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: logs) }
        nonisolated(unsafe) let log = try RunLog(in: logs)
        let inside = Destination(
            path: Config.logDir.appending(path: "Photo Backup").path, isNetwork: false)
        do {
            try await engine.ensureDestinationReady(inside, log)
            XCTFail("A backup inside Kept's logs was accepted")
        } catch let error as BackupError {
            XCTAssertEqual(error.kind, .setupFailed)
        }
    }

    /// What Settings shows: no account name, no Bonjour service name.
    func testAShareIsShownAsAPersonWouldWriteIt() {
        func shown(_ url: String) -> String? {
            Destination(path: "/Volumes/PhotoBackup", isNetwork: true, smbURL: url).shareAddress
        }
        XCTAssertEqual(
            shown("smb://cressman@CressmanNAS._smb._tcp.local/PhotoBackup"),
            "smb://CressmanNAS.local/PhotoBackup")
        XCTAssertEqual(shown("smb://me@nas.local/PhotoBackup"), "smb://nas.local/PhotoBackup")
        XCTAssertEqual(shown("smb://192.168.1.5/Chip%27s%20Photos"), "smb://192.168.1.5/Chip's Photos")
        XCTAssertNil(Destination(path: "/Volumes/Disk", isNetwork: false).shareAddress)
    }
}
