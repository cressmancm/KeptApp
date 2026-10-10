import XCTest

@testable import Kept

/// The check before every backup that Kept's files are the ones it was signed
/// with, against a real build: `.build/Kept.app` from build.sh, or the app
/// `KEPT_TEST_APP` names (CI). Skipped when there's no build.
final class AppSealTests: XCTestCase {
    private func builtApp() throws -> URL {
        if let named = ProcessInfo.processInfo.environment["KEPT_TEST_APP"], !named.isEmpty {
            let url = URL(filePath: named)
            guard FileManager.default.fileExists(atPath: url.appending(path: "Contents").path) else {
                XCTFail("KEPT_TEST_APP names \(named), which isn't an app")
                throw XCTSkip()
            }
            return url
        }
        let package = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = package.appending(path: ".build/Kept.app")
        guard FileManager.default.fileExists(atPath: app.appending(path: "Contents").path) else {
            throw XCTSkip("No .build/Kept.app: run build.sh --no-install")
        }
        return app
    }

    func testABuiltAppIsIntact() throws {
        // Outside the assertion: XCTAssertEqual reports an error thrown inside
        // it as a failure, which turned "no build here, skip" into a red CI run.
        let app = try builtApp()
        XCTAssertEqual(AppSeal.isIntact(app), true)
    }

    /// One edited line of bundled Python is enough to refuse the copy.
    func testAnEditedPythonFileIsCaught() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "KeptAppSeal-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        // A clone on APFS, so copying a couple of hundred megabytes is instant.
        let copy = scratch.appending(path: "Kept.app")
        try fm.copyItem(at: try builtApp(), to: copy)
        XCTAssertEqual(AppSeal.isIntact(copy), true)

        let lib = copy.appending(path: "Contents/Resources/python/lib")
        let python = try XCTUnwrap(try fm.contentsOfDirectory(atPath: lib.path)
            .first { $0.hasPrefix("python3") })
        let module = lib.appending(path: "\(python)/site-packages/osxphotos/__init__.py")
        let handle = try FileHandle(forWritingTo: module)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nprint('planted')\n".utf8))
        try handle.close()

        XCTAssertEqual(AppSeal.isIntact(copy), false)
    }

    func testThereIsNothingToCheckOutsideABundle() {
        XCTAssertNil(AppSeal.isIntact(URL(filePath: "/usr/bin")))
    }
}
