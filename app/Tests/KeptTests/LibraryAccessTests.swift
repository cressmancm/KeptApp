import Photos
import XCTest

@testable import Kept

final class LibraryAccessTests: XCTestCase {
    /// Only Full Access reads the library. Limited is a picked set of photos,
    /// not the library, and osxphotos can't read its files with it.
    func testOnlyFullAccessIsGranted() {
        XCTAssertEqual(LibraryAccess.permission(from: .authorized), .granted)
        XCTAssertEqual(LibraryAccess.permission(from: .limited), .limited)
        XCTAssertEqual(LibraryAccess.permission(from: .notDetermined), .notAsked)
        XCTAssertEqual(LibraryAccess.permission(from: .denied), .denied)
        XCTAssertEqual(LibraryAccess.permission(from: .restricted), .denied)
    }

    func testTheRecordFilesAreInTheHomeFolder() {
        let home = URL(filePath: "/Users/me")
        let files = PhotosLibrary.recordFiles(home: home)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].hasPrefix("/Users/me/Library/Group Containers/"), files[0])
        XCTAssertTrue(files[1].hasPrefix("/Users/me/Library/Containers/"), files[1])
    }
}
