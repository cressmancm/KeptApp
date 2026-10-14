import Foundation

/// Turns an engine failure into something the user can act on.
///
/// The engine's message is written for the log — it names paths, exit codes,
/// and timeouts. The panel says what broke, in the user's terms, and what
/// happens next. The raw message is never thrown away; it stays one click
/// behind "Open Log", and unmapped failures fall back to it verbatim.
enum FailureCopy {
    /// How the panel is allowed to render a failure line.
    ///
    /// The distinction is a security boundary, not a formatting one. Authored
    /// copy is ours and is parsed as markdown so the destination can be bold
    /// mid-sentence. The engine's own message reaches the panel via runs.json,
    /// which anything running as this user can rewrite — parsing that as
    /// markdown would let a crafted record render a tappable link pointing
    /// anywhere. It is shown verbatim instead.
    enum Message: Equatable {
        case authored(String)
        case verbatim(String)

        /// The underlying text, regardless of how it will be rendered.
        var text: String {
            switch self {
            case .authored(let text), .verbatim(let text): text
            }
        }

        /// For places that show plain text — a notification body. Authored
        /// copy only ever uses `**bold**`, so dropping the markers is enough;
        /// verbatim text was never markdown and passes through untouched.
        var plainText: String {
            switch self {
            case .authored(let text):
                text.replacingOccurrences(of: "**", with: "")
                    .replacing(#/\\(.)/#) { String($0.1) }
            case .verbatim(let text): text
            }
        }
    }

    static func message(
        kind: FailureKind?, rawMessage: String?, destination: Destination?, failedAt: Date?
    ) -> Message {
        // Escaped: the name is the user's folder or host, spliced into
        // markdown, and a folder called "*old*" or "[x](y)" would otherwise
        // render as formatting or a link.
        let name = escapedMarkdown(displayTarget(destination))
        let time = failedAt.map { $0.formatted(date: .omitted, time: .shortened) }

        switch kind {
        case .volumeUnreachable:
            let when = time.map { " at \($0)" } ?? ""
            // No time or trigger promised: a retry comes within the hour, or
            // once three tries are used up, at the next scheduled backup. Kept
            // doesn't watch for the folder coming back, so "when it's back"
            // was wrong.
            return .authored(
                "Couldn't reach **\(name)**\(when). Check that it's on and connected, "
                    + "and Kept will try again.")
        case .diskFull:
            return .authored(
                "**\(name)** has less than \(Config.minFreeGB) GB free. "
                    + "Free up space and Kept will try again.")
        case .exportFailed:
            // No specific time promised: a retry may come within the hour, or
            // not until tonight if the retries for this slot are used up.
            return .authored(
                "The backup to **\(name)** stopped partway. Kept will try again. "
                    + "If it keeps happening, check the log.")
        case .cancelled:
            return .authored("You stopped the last backup.")
        case .libraryAccess:
            return .authored("Kept can't read your Photos library. Turn on Full Disk Access for Kept.")
        case .setupFailed, nil:
            guard let rawMessage else {
                return .authored("The backup didn't finish. Open the log for details.")
            }
            return .verbatim(rawMessage)
        }
    }

    /// Backslash-escapes what markdown gives meaning to mid-sentence:
    /// emphasis, code, links, autolinks and strikethrough. Dots and dashes
    /// only matter at the start of a line, which a name never is here.
    static func escapedMarkdown(_ text: String) -> String {
        let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "~"]
        return String(text.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// The host for a network share, the folder name otherwise — whichever the
    /// user would recognise as "the thing that isn't there".
    private static func displayTarget(_ destination: Destination?) -> String {
        guard let destination else { return "the backup folder" }
        return destination.serverName ?? destination.displayName
    }

    /// "Last good backup: 30 hours ago" — the subtitle states the cost of the
    /// failure rather than repeating that it failed.
    static func lastGoodCopy(_ lastSuccess: RunRecord?, now: Date = .now) -> String {
        guard let lastSuccess else { return "No backup has finished yet" }
        let elapsed = now.timeIntervalSince(lastSuccess.start)
        let hours = Int(elapsed / 3600)
        if hours < 1 { return "Last good backup: less than an hour ago" }
        if hours == 1 { return "Last good backup: 1 hour ago" }
        if hours < 48 { return "Last good backup: \(hours) hours ago" }
        return "Last good backup: \(hours / 24) days ago"
    }
}
