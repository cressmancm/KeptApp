import XCTest

@testable import Kept

final class AppLocationTests: XCTestCase {
    func testTranslocatedPathsAreRecognised() {
        XCTAssertTrue(AppLocation.isTranslocated(
            path: "/private/var/folders/x1/abc/T/AppTranslocation/0F3A-11B2/d/Kept.app"))
        XCTAssertFalse(AppLocation.isTranslocated(path: "/Applications/Kept.app"))
        XCTAssertFalse(AppLocation.isTranslocated(path: "/Users/me/Downloads/Kept.app"))
    }

    /// The test runner isn't translocated, so there's no download to find.
    func testNoOriginalOutsideTranslocation() {
        XCTAssertFalse(AppLocation.isTranslocated)
        XCTAssertNil(AppLocation.originalURL())
    }

    /// The lookup isn't in the public headers, so a macOS that drops it
    /// should fail here rather than leave every download asking to be moved
    /// by hand.
    func testTheOriginalPathLookupExists() {
        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        XCTAssertNotNil(handle)
        XCTAssertNotNil(dlsym(handle, "SecTranslocateCreateOriginalPathForURL"))
    }
}
