import XCTest

@testable import Kept

@MainActor
final class MenuBarGlyphTests: XCTestCase {
    /// Two failures at once, both of which have happened:
    ///
    /// A symbol name that does not exist renders nothing — `photo.badge.
    /// questionmark`, which the design asked for, didn't exist on macOS 26 and
    /// would have rendered a blank menubar. And a glyph whose width changes
    /// with state shifts every menu bar item beside it each time a backup
    /// starts or fails, which is why the symbols are drawn into a measured box.
    func testEveryStateRendersIntoAnIdenticalBox() {
        let states = BackupController.GlyphState.allCases
        let sizes = states.compactMap { MenuBarGlyph.image(symbol: $0.symbol)?.size }

        XCTAssertEqual(
            sizes.count, states.count,
            "a state's symbol does not exist: "
                + states.filter { MenuBarGlyph.image(symbol: $0.symbol) == nil }
                .map(\.symbol).joined(separator: ", "))
        XCTAssertEqual(Set(sizes.map(\.width)).count, 1, "glyph width varies by state: \(sizes)")
        XCTAssertEqual(Set(sizes.map(\.height)).count, 1, "glyph height varies by state: \(sizes)")
    }
}
