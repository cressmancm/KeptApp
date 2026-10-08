import Foundation

/// Presentation helpers shared by the popover and the Settings window. Pure
/// functions with injectable `now`/`calendar` so they can be tested without
/// waiting for a particular time of day.
enum RunFormatting {
    /// "Today, 11:04 AM" / "Yesterday, 4:52 PM" / "Jul 23, 2:00 AM".
    /// Friendlier than an absolute date for the recent nights that matter,
    /// and unambiguous past that.
    static func friendlyDate(
        _ date: Date, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        let time = date.formatted(style(calendar).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let day = date.formatted(style(calendar).month(.abbreviated).day())
        return "\(day), \(time)"
    }

    /// Day arithmetic and text must agree on a time zone, or a date built in
    /// one zone gets described in another. Everything here formats through the
    /// same calendar it counts with.
    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    }

    /// "33m", "1h 12m", "45s".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        // Spelled out: "4m" reads as months as easily as minutes.
        if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
        if minutes >= 1 { return "\(minutes) min" }
        return "\(Int(interval)) sec"
    }

    /// Trailing detail on a Recent runs row: "2 new · 33m", "failed", "skipped".
    /// The design renames "exported" to "new" — the user's word for what
    /// changed, not osxphotos'.
    static func rowDetail(_ record: RunRecord) -> String {
        switch record.outcome {
        case .success:
            var parts: [String] = []
            if let exported = record.exported { parts.append("\(exported) new") }
            if let elapsed = record.duration { parts.append(duration(elapsed)) }
            return parts.isEmpty ? "Done" : parts.joined(separator: " · ")
        case .failed: return "Failed"
        // "Stopped", not "Cancelled": the button that ends a run says Stop.
        case .cancelled: return "Stopped"
        case .skipped: return "Skipped"
        case .interrupted: return "Interrupted"
        // A run still in flight: recorded at start, outcome not yet known.
        case nil: return "Running…"
        }
    }

    /// "as of 6 hours ago" under the healthy status title.
    ///
    /// Measured from the run's **start**, not its end, and phrased "as of" to
    /// say so. osxphotos copies Photos.sqlite aside as its first act and works
    /// from that snapshot for the whole run, so the mirror holds the library as
    /// it was when the run began. A photo taken an hour into a six-hour run is
    /// not in that backup. Reporting the finish time would answer "when did the
    /// copying stop" while the user is asking "how much would I lose right now"
    /// — and would understate the answer by the length of the run, which is the
    /// dangerous direction for a backup tool to round.
    ///
    /// The bare "6 hours ago" this replaced read as "the backup happened then",
    /// which invited exactly that misreading. The finish time is still visible
    /// in Recent runs, which shows the start plus the duration.
    ///
    /// Deliberately carries no item count. It used to append "· 46,920 photos
    /// mirrored", but that is osxphotos' view of the library — it includes
    /// hidden photos, iCloud Shared Albums, "Shared with You" items and
    /// unselected burst frames, so it sat ~13,000 above the total the Photos
    /// app displays and read as a bug.
    ///
    /// Uses RelativeDateTimeFormatter rather than `.formatted(.relative(...))`
    /// because only the former takes an explicit reference date. The format
    /// style always measures against the real clock, which makes the phrase
    /// both untestable and — since the panel does not re-render on its own —
    /// liable to freeze at whatever it said when the view was first built.
    static func healthySubtitle(_ record: RunRecord, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return "Last backup \(formatter.localizedString(for: record.start, relativeTo: now))"
    }

    /// "Next backup tonight at 2:00 AM", or "Next backup Sunday, Aug 2 at
    /// 2:00 AM · weekly".
    ///
    /// The line has to answer two questions, not one: when is the next run, and
    /// how often do runs happen. It previously answered only the first, and
    /// named a bare weekday for anything 2–6 days out — so a weekly schedule
    /// six days from firing read "Next backup Sunday at 2:00 AM" and was
    /// indistinguishable at a glance from a nightly one. A weekly cadence now
    /// says so outright, and anything past tomorrow gets a real date.
    static func nextRunPhrase(
        _ date: Date?, cadence: BackupCadence, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        if cadence == .manual { return "Backups are manual" }
        guard let date else { return "No backup scheduled" }

        let (when, time) = whenAndTime(date, now: now, calendar: calendar)
        guard cadence == .weekly else { return "Next backup \(when) at \(time)" }
        // "tonight" and "tomorrow" already say when; a date gets its weekday,
        // so "Sunday, Aug 2" reads as the weekly slot it is.
        let day = ["tonight", "today", "tomorrow"].contains(when)
            ? when
            : "\(date.formatted(style(calendar).weekday(.wide))), \(when)"
        return "Next backup \(day) at \(time) · weekly"
    }

    /// "The first backup starts tonight at 2:00 AM." — the onboarding's closing
    /// promise, which is about the *first* run rather than the next one, and so
    /// is a whole sentence rather than a label.
    static func firstBackupPhrase(
        _ date: Date?, cadence: BackupCadence, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        if cadence == .manual { return "Backups are manual. Start one anytime from the menubar." }
        guard let date else { return "The first backup starts at the next scheduled time." }
        let (when, time) = whenAndTime(date, now: now, calendar: calendar)
        return "The first backup starts \(when) at \(time)."
    }

    /// Onboarding's destination card: what the drive looks like right now, and
    /// what the first copy is going to cost.
    ///
    /// Any clause that depends on a probe is dropped when the probe has nothing
    /// to say yet, rather than held open behind a spinner — the screen has to
    /// read cleanly the instant it appears. The item count is the last good
    /// run's, so on a genuine first run it is simply absent.
    static func firstCopyPlan(mounted: Bool, freeBytes: Int64?, itemCount: Int?) -> String {
        var sentences: [String] = []
        if mounted {
            var mount = "Connected"
            if let freeBytes { mount += " · \(bytes(freeBytes)) free" }
            sentences.append(mount + ".")
        } else {
            sentences.append("Not connected.")
        }
        let size = itemCount.map { "about \($0.formatted()) items" } ?? "your whole library"
        sentences.append(
            "The first backup copies \(size) and can take hours, so keep your Mac plugged in.")
        sentences.append("After that, only changes are copied.")
        return sentences.joined(separator: " ")
    }

    /// "Next: tonight, 2:00 AM" — the compact form beside the Settings time
    /// picker, where the cadence control is already on screen.
    static func nextRunShort(
        _ date: Date?, cadence: BackupCadence, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        if cadence == .manual { return "Only when you start one" }
        guard let date else { return "" }
        let (when, time) = whenAndTime(date, now: now, calendar: calendar)
        return "Next: \(when), \(time)"
    }

    /// A 2 AM run scheduled for tomorrow is "tonight" to anyone still awake to
    /// read the panel, which is the whole audience for this line. Past tomorrow
    /// the answer is a date: a weekday name alone reads as imminent whether it
    /// is two days out or six.
    private static func whenAndTime(
        _ date: Date, now: Date, calendar: Calendar
    ) -> (when: String, time: String) {
        let time = date.formatted(style(calendar).hour().minute())
        let hour = calendar.component(.hour, from: date)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)).day ?? 0

        switch days {
        case ..<1: return (hour >= 18 ? "tonight" : "today", time)
        case 1: return (hour < 6 ? "tonight" : "tomorrow", time)
        default: return (date.formatted(style(calendar).month(.abbreviated).day()), time)
        }
    }

    /// "3.4 TB", "812 GB". Decimal units, the way the Finder reports volumes.
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// "about 12 min left", or nil while the estimate is still meaningless.
    static func timeRemaining(_ interval: TimeInterval?) -> String? {
        guard let interval, interval > 30 else { return nil }
        return "about \(duration(interval)) left"
    }

    /// "Today", "Yesterday", "Sun, Oct 4": the headings Recent backups groups
    /// its runs under.
    static func dayHeading(
        _ date: Date, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(style(calendar).weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "2:04 AM", for a row that already sits under its day.
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(style(calendar).hour().minute())
    }

    /// One day's runs in Recent backups, newest first.
    struct RunGroup: Identifiable, Equatable {
        let heading: String
        let runs: [RunRecord]
        var id: String { heading }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.heading == rhs.heading && lhs.runs.map(\.id) == rhs.runs.map(\.id)
        }
    }

    /// The last `limit` runs, newest first, under day headings.
    ///
    /// Runs, not days, on purpose. The section used to pair a seven-night
    /// strip of dots, each the best outcome of its day, with a list of the
    /// last six runs, and people couldn't match one to the other: a night with
    /// two failed retries and a catch-up was one green dot over three rows,
    /// two of them red. Now every row is one attempt and the headings give the
    /// day. Nights with no attempt at all have no row; the status line ("Last
    /// backup 3 days ago") and the "Backups have stopped" notification are
    /// what catch those.
    static func recentRunGroups(
        _ history: [RunRecord], limit: Int = Config.recentRunsShown,
        now: Date = .now, calendar: Calendar = .current
    ) -> [RunGroup] {
        var groups: [RunGroup] = []
        for record in history.suffix(limit).reversed() {
            let heading = dayHeading(record.start, now: now, calendar: calendar)
            if let last = groups.last, last.heading == heading {
                groups[groups.count - 1] = RunGroup(heading: heading, runs: last.runs + [record])
            } else {
                groups.append(RunGroup(heading: heading, runs: [record]))
            }
        }
        return groups
    }

    /// The collapsed section's one line: "Today, 2:04 AM · 31 new". Shorter
    /// than a row, with no duration, because it shares the line with the
    /// section's name.
    static func lastRunSummary(_ record: RunRecord, now: Date = .now, calendar: Calendar = .current) -> String {
        let detail: String = switch record.outcome {
        case .success: record.exported.map { "\($0) new" } ?? "Done"
        default: rowDetail(record)
        }
        return "\(friendlyDate(record.start, now: now, calendar: calendar)) · \(detail)"
    }
}
