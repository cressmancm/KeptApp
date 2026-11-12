import Foundation
import NetFS
import Synchronization

/// Connects to the backup folder's share, the way Finder would, but never
/// shows anything.
///
/// Kept used `osascript -e 'mount volume …'`, and away from home that put
/// macOS's "There was a problem connecting to the server" alert on screen
/// with every try: three a night, every night of a trip (2026-11-12). NetFS
/// with its UI turned off returns an error instead. It still signs in with
/// the password saved in the Keychain when the share was first opened in
/// Finder (verified 2026-11-12: mounted in 3s, no prompt).
///
/// The connection is made by macOS's own SMB client, not by Kept, so it's
/// no more a Local Network request than the old mount was. A connection of
/// Kept's own to the NAS would have needed one, asked at 2 AM, and a "Don't
/// Allow" would have made every night at home look like being away.
enum ShareMount {
    /// Mounts `smbURL` where macOS mounts it by default, /Volumes/<share>.
    /// Returns 0, or the error: an errno, or a NetFS code. Stop cancels it.
    typealias Mounter = @Sendable (String, StopSignal) async -> Int32

    static let live: Mounter = { smbURL, stop in
        guard let url = URL(string: smbURL) else { return EINVAL }
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionNoUI
        let mount = NSMutableDictionary()
        // Soft: a share that goes away mid-backup fails the call that was
        // waiting on it, rather than leave it waiting for good.
        mount[kNetFSSoftMountKey] = true

        let queue = DispatchQueue(label: "Kept.ShareMount")
        let request = Request()
        let token = Mutex<Int?>(nil)
        let status = await withCheckedContinuation {
            (continuation: CheckedContinuation<Int32, Never>) in
            let once = Once(continuation)
            var id: AsyncRequestID?
            let started = NetFSMountURLAsync(
                url as CFURL, nil, nil, nil, open, mount, &id, queue
            ) { status, _, _ in
                once.resume(status)
            }
            guard started == 0 else {
                once.resume(started)
                return
            }
            request.id = id
            token.withLock {
                $0 = stop.onStop {
                    request.cancel()
                    once.resume(ECANCELED)
                }
            }
        }
        stop.remove(token.withLock { $0 })
        return status
    }

    /// The request in flight, for Stop to cancel.
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var _id: AsyncRequestID?
        var id: AsyncRequestID? {
            get { lock.withLock { _id } }
            set { lock.withLock { _id = newValue } }
        }
        func cancel() {
            if let id { NetFSMountURLCancel(id) }
        }
    }

    /// The errors that mean nothing answered at that address: the NAS isn't
    /// on this network, or isn't on. Away from home a Bonjour name fails with
    /// EHOSTUNREACH in about 30s and an IP address with ETIMEDOUT in about
    /// 60s (both seen 2026-11-12). Anything else means something answered and
    /// refused, a missing share (ENOENT) or a password it didn't take, and
    /// that is a real failure.
    static func isOutOfReach(_ status: Int32) -> Bool {
        [EHOSTUNREACH, ETIMEDOUT, ENETUNREACH, EHOSTDOWN, ENETDOWN].contains(status)
    }

    /// For the log.
    static func describe(_ status: Int32) -> String {
        status > 0 ? "\(String(cString: strerror(status))) (\(status))" : "error \(status)"
    }
}
