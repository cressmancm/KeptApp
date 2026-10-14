import Foundation
import Security

/// Whether Kept's own files are still the ones it was signed with, by the
/// one who signed the Kept that's running.
///
/// The bundled Python is hundreds of ordinary files in a bundle the user
/// owns, and Python doesn't check signatures: it runs whatever `.py` it finds.
/// Anything running as the user could edit one, and the next Python Kept
/// started would run that edit with Kept's Full Disk Access. Making the files
/// read-only wouldn't help, since their owner can make them writable again.
/// The signature covers every file in the bundle, though, so the engine
/// checks it before every launch of Python (about 0.7 seconds) and refuses to
/// run on a changed copy.
///
/// A valid signature isn't enough: anyone can sign a changed bundle again,
/// ad hoc or with a certificate of their own, and that passed (production
/// review S4, 2026-10-13). So the bundle must also satisfy the running
/// Kept's designated requirement: for a release, Kept's identifier and
/// Developer ID team. An update signed the same way passes; a copy signed by
/// anyone else doesn't.
enum AppSeal {
    /// The running Kept's designated requirement. Read once, at launch
    /// (main.swift), and only while the app on disk is still the one that
    /// was launched: Security reads the requirement from the disk, so read
    /// later, after the bundle was signed again, it was the new signer's
    /// (checked 2026-10-13 with a binary re-signed while it ran). nil when
    /// the disk no longer matches, or there's no signature: every check then
    /// fails.
    nonisolated(unsafe) static let runningRequirement: SecRequirement? = requirementOfRunningCode()

    /// What `runningRequirement` holds, read now.
    ///
    /// No flags on the validity check. `kSecCSDoNotValidateResources` is a
    /// static-code flag: running code refuses it with errSecCSInvalidFlags,
    /// so this always came back nil, and every backup in a signed Kept
    /// failed with "Part of Kept has been changed" (2026-10-14, the first
    /// nightly on the S4 fix). Running code isn't checked against its
    /// resources anyway; isIntact does that. This takes milliseconds.
    static func requirementOfRunningCode() -> SecRequirement? {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCheckValidity(code, [], nil) == errSecSuccess,
            // A SecCode is a SecStaticCode to Security, which Swift's types
            // don't say.
            SecCodeCopyDesignatedRequirement(
                unsafeBitCast(code, to: SecStaticCode.self), [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    /// A bundle's designated requirement, as its signature on disk states it.
    static func designatedRequirement(of bundle: URL) -> SecRequirement? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    /// nil outside an app bundle (`swift run`, tests), where there's no
    /// signature to check. False when there's no requirement to hold it to.
    static func isIntact(_ bundle: URL, signedLike requirement: SecRequirement?) -> Bool? {
        guard bundle.pathExtension == "app" else { return nil }
        guard let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
            let code
        else { return false }
        // What `codesign --verify --deep --strict` checks: every nested
        // binary, every sealed resource, nothing added; and then whose it is.
        let flags = SecCSFlags(
            rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    /// The check the engine makes: this bundle, held to the running Kept.
    static func isIntact(_ bundle: URL = Bundle.main.bundleURL) -> Bool? {
        isIntact(bundle, signedLike: runningRequirement)
    }
}
