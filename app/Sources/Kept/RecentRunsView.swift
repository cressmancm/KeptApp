import SwiftUI

/// "Recent backups" — the last eight runs under day headings. Collapsed, the
/// header carries the latest run ("Today, 2:04 AM · 31 new") so the closed
/// section still answers "did last night work?". Clicking a run opens its log.
///
/// There used to be a seven-night strip of dots here as well. It counted days
/// while the list counted runs, and the two couldn't be matched; see
/// `RunFormatting.recentRunGroups`.
struct RecentRunsView: View {
    let controller: BackupController
    @Binding var isExpanded: Bool
    /// Passed in rather than read from the clock so the Today/Yesterday
    /// headings re-evaluate when the panel ticks.
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            DisclosureHeader(label: "Recent backups", isExpanded: $isExpanded) {
                // Only while collapsed: open, the first row says the same.
                if !isExpanded, let last = controller.displayHistory.last {
                    Text(RunFormatting.lastRunSummary(last, now: now))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    let groups = RunFormatting.recentRunGroups(controller.displayHistory, now: now)
                    if groups.isEmpty {
                        Text("No backups yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                            .padding(.horizontal, Metrics.sectionPaddingH)
                    }
                    ForEach(groups) { group in
                        Text(group.heading)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .padding(.bottom, 1)
                            .padding(.horizontal, Metrics.sectionPaddingH)
                        ForEach(group.runs) { record in
                            RunRow(record: record, action: { controller.openLog(record) })
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            }
        }
    }
}

/// The dot each run row starts with.
enum RunOutcomeStyle {
    static func color(for record: RunRecord) -> Color {
        // Orange, like the panel: it ran, but didn't copy everything.
        record.isPartial ? .orange : color(for: record.outcome)
    }

    static func color(for outcome: RunOutcome?) -> Color {
        switch outcome {
        case .success: .green
        case .failed: .red
        // Grey, like stopped: the run was cut short, not broken.
        case .interrupted, .cancelled, .skipped, nil: Color.primary.opacity(0.18)
        }
    }
}

private struct RunRow: View {
    let record: RunRecord
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(RunOutcomeStyle.color(for: record))
                    .frame(width: 6, height: 6)
                Text(RunFormatting.time(record.start))
                Spacer(minLength: 6)
                Text(RunFormatting.rowDetail(record))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .padding(.horizontal, Metrics.sectionPaddingH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovering ? Metrics.hoverFill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
