import Foundation
import IOKit.ps

/// Whether the Mac is on mains power, and a way to be told when that changes.
///
/// Kept cares because an unattended backup on battery cannot work and should
/// not be attempted. `PreventSystemSleep` is honoured on AC only, so on battery
/// macOS sleeps mid-export, the SMB session dies, and the run fails after
/// hours of trying — 47 sleep/wake cycles and two failed attempts on
/// 2026-08-05, having burned battery all night to back up nothing.
enum PowerSource {
    static var isOnAC: Bool {
        guard let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue()
        else { return true }  // Unknown: assume mains rather than block backups.
        return (source as String) == kIOPMACPowerKey
    }

    /// Event-driven notification of power source changes — no polling, so an
    /// app that sits idle for days stays idle.
    static func observe(
        _ handler: @escaping @Sendable () -> Void
    ) -> (source: CFRunLoopSource, box: AnyObject)? {
        final class Box {
            let handler: @Sendable () -> Void
            init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        }
        let box = Box(handler)
        let context = Unmanaged.passUnretained(box).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().handler()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue()
        else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        // The box must outlive the source; the caller holds it.
        return (source, box)
    }
}
