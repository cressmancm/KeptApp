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
}
