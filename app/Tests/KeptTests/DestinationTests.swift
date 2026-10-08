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
}
