import XCTest

@testable import Kept

/// Production review W8, 2026-10-13: on a share that can't rename without
/// replacing, Kept checked that the name was free and then renamed, so a
/// file arriving in between was overwritten. The NAS this was written
/// against takes that path for every photo set aside: its rename refuses
/// RENAME_EXCL (ENOTSUP), and it has no hard links. Here the exclusive
/// rename is made to fail the same way.
final class ExclusiveMoveTests: XCTestCase {
    private var scratch: URL!
    private var source: Int32 = -1
    private var target: Int32 = -1
    private let fm = FileManager.default

    override func setUpWithError() throws {
        scratch = fm.temporaryDirectory.appending(path: "KeptExclusiveMove-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch.appending(path: "from"), withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch.appending(path: "to"), withIntermediateDirectories: true)
        source = open(scratch.appending(path: "from").path, O_RDONLY | O_DIRECTORY)
        target = open(scratch.appending(path: "to").path, O_RDONLY | O_DIRECTORY)
    }

    override func tearDownWithError() throws {
        close(source)
        close(target)
        try? fm.removeItem(at: scratch)
    }

    private let noExclusiveRename: (Int32, String, Int32, String) -> Int32 = { _, _, _, _ in ENOTSUP }

    private func write(_ text: String, _ path: String) throws {
        try Data(text.utf8).write(to: scratch.appending(path: path))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: scratch.appending(path: path), encoding: .utf8)
    }

    func testAFreeNameIsMovedTo() throws {
        try write("photo", "from/IMG_1.jpg")
        let status = NoFollow.moveExclusive(
            "IMG_1.jpg", from: source, to: target, as: "IMG_1.jpg", exclusiveRename: noExclusiveRename)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try read("to/IMG_1.jpg"), "photo")
        XCTAssertFalse(fm.fileExists(atPath: scratch.appending(path: "from/IMG_1.jpg").path))
    }

    func testATakenNameIsNeverReplaced() throws {
        try write("photo", "from/IMG_1.jpg")
        try write("already set aside", "to/IMG_1.jpg")
        let status = NoFollow.moveExclusive(
            "IMG_1.jpg", from: source, to: target, as: "IMG_1.jpg", exclusiveRename: noExclusiveRename)
        XCTAssertEqual(status, EEXIST)
        XCTAssertEqual(try read("to/IMG_1.jpg"), "already set aside")
        XCTAssertEqual(try read("from/IMG_1.jpg"), "photo")
    }

    /// A link at the name is something there too, and isn't followed.
    func testALinkAtTheNameIsNeverReplacedOrFollowed() throws {
        try write("photo", "from/IMG_1.jpg")
        try write("elsewhere", "elsewhere.txt")
        try fm.createSymbolicLink(
            at: scratch.appending(path: "to/IMG_1.jpg"),
            withDestinationURL: scratch.appending(path: "elsewhere.txt"))
        let status = NoFollow.moveExclusive(
            "IMG_1.jpg", from: source, to: target, as: "IMG_1.jpg", exclusiveRename: noExclusiveRename)
        XCTAssertEqual(status, EEXIST)
        XCTAssertEqual(try read("elsewhere.txt"), "elsewhere")
    }

    /// The move failing leaves no placeholder behind.
    func testAFailedMoveLeavesNothingBehind() throws {
        let status = NoFollow.moveExclusive(
            "gone.jpg", from: source, to: target, as: "gone.jpg", exclusiveRename: noExclusiveRename)
        XCTAssertEqual(status, ENOENT)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: scratch.appending(path: "to").path), [])
    }

    /// Where exclusive rename works, it's used as before.
    func testExclusiveRenameIsUsedWhereItWorks() throws {
        try write("photo", "from/IMG_1.jpg")
        try write("already set aside", "to/IMG_1.jpg")
        XCTAssertEqual(
            NoFollow.moveExclusive("IMG_1.jpg", from: source, to: target, as: "IMG_1.jpg"), EEXIST)
        XCTAssertEqual(
            NoFollow.moveExclusive("IMG_1.jpg", from: source, to: target, as: "IMG_1 2.jpg"), 0)
        XCTAssertEqual(try read("to/IMG_1 2.jpg"), "photo")
    }
}
