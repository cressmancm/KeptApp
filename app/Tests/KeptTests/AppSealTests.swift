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
        XCTAssertEqual(AppSeal.isIntact(app, signedLike: AppSeal.designatedRequirement(of: app)), true)
    }

    /// A copy of the built app, on APFS a clone, so it's instant.
    private func copyOfBuiltApp(in scratch: URL) throws -> URL {
        let copy = scratch.appending(path: "Kept.app")
        try FileManager.default.copyItem(at: try builtApp(), to: copy)
        return copy
    }

    private func plantPython(in app: URL) throws {
        let lib = app.appending(path: "Contents/Resources/python/lib")
        let python = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: lib.path)
            .first { $0.hasPrefix("python3") })
        let module = lib.appending(path: "\(python)/site-packages/osxphotos/__init__.py")
        let handle = try FileHandle(forWritingTo: module)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\nprint('planted')\n".utf8))
        try handle.close()
    }

    /// Production review S4: the changed copy signed again, ad hoc, has a
    /// valid signature of its own, which used to be enough. Held to the
    /// original's requirement, it isn't.
    func testAChangedCopySignedAgainIsCaught() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "KeptAppSeal-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let original = try builtApp()
        let requirement = try XCTUnwrap(AppSeal.designatedRequirement(of: original))
        let copy = try copyOfBuiltApp(in: scratch)
        try plantPython(in: copy)
        let signed = Process()
        signed.executableURL = URL(filePath: "/usr/bin/codesign")
        signed.arguments = ["--force", "--deep", "--sign", "-", copy.path]
        signed.standardError = FileHandle.nullDevice
        try signed.run()
        signed.waitUntilExit()
        XCTAssertEqual(signed.terminationStatus, 0)

        // Valid by its own lights: what the old check asked.
        XCTAssertEqual(
            AppSeal.isIntact(copy, signedLike: AppSeal.designatedRequirement(of: copy)), true)
        XCTAssertEqual(AppSeal.isIntact(copy, signedLike: requirement), false)
    }

    func testNoRequirementMeansNotIntact() throws {
        // Outside the assertion, as in testABuiltAppIsIntact: a skip thrown
        // inside one is reported as a failure (CI, 2026-10-14).
        let app = try builtApp()
        XCTAssertEqual(AppSeal.isIntact(app, signedLike: nil), false)
    }

    /// One edited line of bundled Python is enough to refuse the copy.
    func testAnEditedPythonFileIsCaught() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "KeptAppSeal-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let requirement = AppSeal.designatedRequirement(of: try builtApp())
        let copy = try copyOfBuiltApp(in: scratch)
        XCTAssertEqual(AppSeal.isIntact(copy, signedLike: requirement), true)
        try plantPython(in: copy)
        XCTAssertEqual(AppSeal.isIntact(copy, signedLike: requirement), false)
    }

    /// The test runner is signed, as the app is. With a flag running code
    /// refuses, this came back nil in every signed Kept, so every backup
    /// failed the seal check (2026-10-14). No test read it before.
    func testTheRunningCodesRequirementIsRead() {
        XCTAssertNotNil(AppSeal.requirementOfRunningCode())
    }

    func testThereIsNothingToCheckOutsideABundle() {
        XCTAssertNil(AppSeal.isIntact(URL(filePath: "/usr/bin")))
    }
}
