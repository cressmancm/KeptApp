import SwiftUI

/// Spacing and sizing from the redesign. Named rather than inlined so the
/// rhythm stays consistent as sections move around.
enum Metrics {
    static let panelWidth: CGFloat = 320
    static let sectionPaddingH: CGFloat = 14
    static let sectionPaddingTop: CGFloat = 14
    static let sectionPaddingBottom: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    static let statusGlyph: CGFloat = 26
    static let cardRadius: CGFloat = 8
    static let hoverRadius: CGFloat = 5

    static let subtleFill = Color.primary.opacity(0.035)
    static let hoverFill = Color.primary.opacity(0.06)
}

/// A panel section: content inset, dividers left to run the full width.
struct PanelSection<Content: View>: View {
    var spacing: CGFloat = Metrics.sectionSpacing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.horizontal, Metrics.sectionPaddingH)
        .padding(.top, Metrics.sectionPaddingTop)
        .padding(.bottom, Metrics.sectionPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one answer at the top of the panel: a state glyph, a title that says
/// whether the library is safe, and a subtitle that quantifies it.
struct StatusRow<Glyph: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var glyph: Glyph

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            glyph
                .frame(width: Metrics.statusGlyph, height: Metrics.statusGlyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension StatusRow where Glyph == AnyView {
    /// The common case: an SF Symbol in a state colour.
    init(symbol: String, tint: Color, title: String, subtitle: String?) {
        self.init(title: title, subtitle: subtitle) {
            AnyView(
                Image(systemName: symbol)
                    .font(.system(size: Metrics.statusGlyph))
                    .foregroundStyle(tint)
            )
        }
    }
}

/// Rounded fill holding the at-a-glance facts under the status row.
struct InfoCard<Content: View>: View {
    var fill: Color = Metrics.subtleFill
    var spacing: CGFloat = 5
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
    }
}

/// `symbol + label ......... value` — one line of the facts card.
struct FactRow: View {
    let symbol: String
    let label: String
    var value: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 13)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let value {
                Text(value).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Determinate 6pt bar. Hand-drawn rather than a styled `ProgressView` because
/// the design pins the height and corner radius.
struct ThinProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Backup progress")
        .accessibilityValue("\(Int((max(0, min(1, fraction)) * 100).rounded())) percent")
    }
}

/// Full-width disclosure header: rotating chevron, label, optional trailing
/// accessory, and a hover highlight across the whole row.
struct DisclosureHeader<Accessory: View>: View {
    let label: String
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: Accessory

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(label)
                Spacer(minLength: 6)
                accessory
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, Metrics.sectionPaddingH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.04) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Borderless footer action: no border, hover fill only.
struct FooterButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FooterLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
    }
}

/// The label half of a footer button, shared with `SettingsLink`, which
/// supplies its own button behaviour.
struct FooterLabel: View {
    let title: String
    var symbol: String?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10))
            }
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .background(
            isHovering ? Metrics.hoverFill : .clear,
            in: RoundedRectangle(cornerRadius: Metrics.hoverRadius))
        .onHover { isHovering = $0 }
    }
}

/// Footer strip. "Settings…" is always present; the rest varies by state.
struct FooterBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            SettingsLink {
                FooterLabel(title: "Settings…", symbol: "gearshape")
            }
            .buttonStyle(.plain)
            // An LSUIElement app has no menu bar of its own to bring forward,
            // so the Settings window would open behind whatever is frontmost.
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
                // And the panel gets out of its way. While its own button is
                // being clicked the panel is the key window, and it's a panel,
                // which the Settings window isn't. Closed on the next turn of
                // the run loop, so the link has opened Settings first, and with
                // close() rather than orderOut so the menubar icon knows the
                // panel is gone and opens it again on the next click.
                guard let panel = NSApp.keyWindow as? NSPanel else { return }
                DispatchQueue.main.async { panel.close() }
            })

            content

            Spacer(minLength: 0)
            FooterButton(title: "Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }
}
