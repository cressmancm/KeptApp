#if KEPT_REVIEW_TOOLS
import AppKit
import Foundation

// The review tools in Settings → Advanced: forced panel states, the menubar
// glyph, setup screens, sample warnings, alerts and notifications. They're for
// whoever is working on Kept, so they're compiled into debug builds and local
// builds from build.sh, and left out of releases (KEPT_REVIEW_TOOLS).
//
// The stored overrides themselves live in BackupController, which has to hold
// them; everything that only reads or shows them is here.

extension BackupController {
    /// The two orange rows the General tab can grow under the staleness
    /// checkbox. Neither is reachable on demand: one needs `launchctl
    /// bootstrap` to fail, the other needs launchd to accept the job and then
    /// never spawn it — which is exactly the silent failure they exist to
    /// report, and exactly why the copy has to be reviewable.
    enum StalenessWarningPreview: String, CaseIterable, Identifiable, Sendable {
        case registrationFailed, neverRuns

        var id: String { rawValue }

        var label: String {
            switch self {
            case .registrationFailed: "Couldn't schedule"
            case .neverRuns: "Not running"
            }
        }
    }

    /// The alerts `chooseDestination` raises, shown on demand.
    ///
    /// All are refusals or warnings about a folder the user just picked, so
    /// there is no way to see one without pointing Kept at a folder you
    /// would rather it didn't touch.
    enum PreviewDialog: String, CaseIterable, Identifiable, Sendable {
        case unsafeRoot, photosLibrary, cloudFolder, nonEmptyFolder, cantReconnect, cantSave

        var id: String { rawValue }

        var label: String {
            switch self {
            case .unsafeRoot: "Unsafe Folder"
            case .photosLibrary: "Holds a Library"
            case .cloudFolder: "Cloud Folder"
            case .nonEmptyFolder: "Folder Not Empty"
            case .cantReconnect: "Can't Reconnect"
            case .cantSave: "Can't Save Folder"
            }
        }
    }

    func showPreviewDialog(_ dialog: PreviewDialog) {
        // The real destination when there is one, so the alert names something
        // the reviewer recognises.
        let sample = destination ?? StatePreview.sampleDestination
        NSApp.activate(ignoringOtherApps: true)
        switch dialog {
        case .unsafeRoot:
            DestinationPicker.unsafeMirrorRootAlert(for: FileManager.default
                .homeDirectoryForCurrentUser.appending(path: "Pictures").lastPathComponent)
                .runModal()
        case .photosLibrary:
            DestinationPicker.unsafeMirrorRootAlert(
                for: "Photos SSD", refusal: .holdsPhotosLibrary
            ).runModal()
        case .cloudFolder:
            DestinationPicker.unsafeMirrorRootAlert(
                for: "iCloud Drive", refusal: .cloudFolder
            ).runModal()
        case .nonEmptyFolder:
            _ = DestinationPicker.nonEmptyFolderAlert(
                for: sample, retentionDays: removedRetentionDays
            ).runModal()
        case .cantReconnect:
            if DestinationPicker.cantReconnectAlert(for: sample.displayName).runModal()
                == .alertFirstButtonReturn
            {
                DestinationPicker.openAutomationSettings()
            }
        case .cantSave:
            DestinationPicker.cantSaveAlert(for: "Photos Backup 2", previous: sample).runModal()
        }
    }

    /// The four notifications, posted for real so they can be checked in
    /// Notification Centre — including whether the "Launch Kept" button on the
    /// staleness one still works.
    ///
    /// Deliberately not gated on the notify preferences the engine honours: the
    /// point of the button is to see the notification, and a button that
    /// silently does nothing because a checkbox is off is worse than no button.
    enum PreviewNotification: String, CaseIterable, Identifiable, Sendable {
        case complete, incomplete, failed, stale

        var id: String { rawValue }

        var label: String {
            switch self {
            case .complete: "Backup Complete"
            case .incomplete: "Backup Incomplete"
            case .failed: "Backup Failed"
            case .stale: "Backups Stopped"
            }
        }
    }

    func postPreviewNotification(_ kind: PreviewNotification) {
        let payload: KeptNotification.Kind = switch kind {
        case .complete: .backupComplete(body: "31 new · 6 removed")
        case .incomplete: .backupIncomplete(message: RunFormatting.errorsSentence(12))
        // Both built by the code the real notifications use, so a preview
        // can't drift from what actually arrives.
        case .failed:
            .backupFailed(
                message: FailureCopy.message(
                    kind: .volumeUnreachable, rawMessage: nil,
                    destination: destination ?? StatePreview.sampleDestination,
                    failedAt: .now
                ).plainText)
        case .stale:
            .stale(
                message: StalenessCheck.staleMessage(
                    history: [Self.sampleSuccess(daysAgo: 4)], thresholdDays: 1) ?? "")
        }
        Task { await KeptNotification.post(payload) }
    }

    /// A good run some days back — just enough history for the staleness
    /// check to produce its real sentence for a preview.
    private static func sampleSuccess(daysAgo: Int) -> RunRecord {
        var record = RunRecord(
            trigger: .scheduled, start: .now.addingTimeInterval(-Double(daysAgo) * 86_400))
        record.outcome = .success
        return record
    }

    /// Opens the flow at one screen, for reviewing that screen.
    ///
    /// Unlike `resetOnboarding` this leaves `hasCompletedOnboarding` alone: a
    /// look at screen 3 should not arm the first-run flow for the next launch.
    func showOnboarding(startingAt page: Int) {
        OnboardingWindowController.show(controller: self, startingAt: page)
    }
}
#endif
