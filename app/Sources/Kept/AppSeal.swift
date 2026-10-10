import Foundation
import Security

/// Whether Kept's own files are still the ones it was signed with.
///
/// The bundled Python is hundreds of ordinary files in a bundle the user
/// owns, and Python doesn't check signatures: it runs whatever `.py` it finds.
/// Anything running as the user could edit one, and the next backup would run
/// that edit with Kept's Full Disk Access. Making the files read-only wouldn't
/// help, since their owner can make them writable again. The signature
/// covers every file in the bundle, though, so the engine checks it before
/// every backup (about 0.7 seconds) and refuses to run on a changed copy.
enum AppSeal {
    /// nil outside an app bundle (`swift run`, tests), where there's no
    /// signature to check.
    static func isIntact(_ bundle: URL = Bundle.main.bundleURL) -> Bool? {
        guard bundle.pathExtension == "app" else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
            let code
        else { return false }
        // What `codesign --verify --deep --strict` checks: every nested
        // binary, every sealed resource, nothing added.
        let flags = SecCSFlags(
            rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess
    }
}
