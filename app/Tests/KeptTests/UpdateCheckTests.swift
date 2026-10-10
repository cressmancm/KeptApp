import XCTest

@testable import Kept

final class UpdateCheckTests: XCTestCase {
    func testVersionsCompareByPart() {
        XCTAssertTrue(UpdateCheck.isNewer("1.2", than: "1.1"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UpdateCheck.isNewer("2", than: "1.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.1.1", than: "1.1"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1", than: "1.1"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1.0", than: "1.1"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.1"))
    }

    /// Outside an app bundle the version is "—", which nothing is newer than.
    func testAnUnreadableVersionIsNeverOutOfDate() {
        XCTAssertFalse(UpdateCheck.isNewer("9.9", than: "—"))
        XCTAssertFalse(UpdateCheck.isNewer("v9", than: "1.1"))
    }

    /// The tag becomes part of the URL the Download button opens, so only a
    /// plain version gets through.
    func testOnlyPlainVersionTagsAreRead() {
        XCTAssertEqual(UpdateCheck.version(fromTag: "v1.2"), "1.2")
        XCTAssertEqual(UpdateCheck.version(fromTag: "1.2.3"), "1.2.3")
        for tag in ["v1.2-beta", "1.2.3.4", "v", "", "v1..2", "../evil", "v1.2/../x", "+1", "١.٢"] {
            XCTAssertNil(UpdateCheck.version(fromTag: tag), tag)
        }
    }

    func testTheReleaseIsReadFromGitHubsAnswer() throws {
        let json = Data(#"{"tag_name": "v1.2", "html_url": "https://example.com/elsewhere"}"#.utf8)
        let release = try XCTUnwrap(UpdateCheck.release(fromJSON: json))
        XCTAssertEqual(release.version, "1.2")
        // Built from the version, never taken from the response.
        XCTAssertEqual(
            release.pageURL.absoluteString,
            "https://github.com/cressmancm/KeptApp/releases/tag/v1.2")
        XCTAssertNil(UpdateCheck.release(fromJSON: Data(#"{"message": "Not Found"}"#.utf8)))
        XCTAssertNil(UpdateCheck.release(fromJSON: Data("not json".utf8)))
    }

    func testChecksAreADayApart() {
        let now = Date.now
        XCTAssertTrue(UpdateCheck.isDue(checkedAt: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(checkedAt: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(checkedAt: now.addingTimeInterval(-86_400), now: now))
        // What a failed check records: due again an hour later.
        let failed = now.addingTimeInterval(UpdateCheck.retryAfterFailure - UpdateCheck.interval)
        XCTAssertFalse(UpdateCheck.isDue(checkedAt: failed, now: now.addingTimeInterval(3_500)))
        XCTAssertTrue(UpdateCheck.isDue(checkedAt: failed, now: now.addingTimeInterval(3_600)))
    }
}
