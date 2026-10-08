import SwiftUI

/// Tokens and controls shared by the four onboarding screens.
///
/// Split out for the same reason `Metrics` is in MenuComponents: the screens
/// repeat the same card, dot, and button shapes, and they have to stay in step
/// as the copy on any one of them moves around.
enum OnboardingMetrics {
    static let windowWidth: CGFloat = 480

    /// The design's "quaternary fill" — every card background in the flow.
    /// Expressed as an opacity on `.primary` rather than a named system fill so
    /// one value covers both appearances, which is how the popover's own
    /// subtle fills are already written.
    static let cardFill = Color.primary.opacity(0.05)
    /// The design's "control fill" — secondary buttons.
    static let controlFill = Color.primary.opacity(0.10)
    static let inactiveDot = Color.primary.opacity(0.18)
    static let hairline = Color.primary.opacity(0.12)

    static let cardRadius: CGFloat = 9
    static let stepCardRadius: CGFloat = 8
    static let dialogRadius: CGFloat = 10

    /// The design specifies CSS `line-height` — the height of the whole line
    /// box — where SwiftUI's `lineSpacing` is only the gap added *between*
    /// lines. Converting needs the font's own line height, which for the system
    /// font runs about 1.2× its point size.
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
        max(0, size * (lineHeight - 1.2))
    }

    /// The design's `letter-spacing: -0.01em` on the semibold headings, in the
    /// points `.kerning` wants.
    static func headingKerning(_ size: CGFloat) -> CGFloat { size * -0.01 }
}

/// The flow's buttons: a capsule that is either white-on-accent or sits on the
/// control fill. Sizes and padding differ per screen, so both are passed in
/// rather than fixed here.
struct OnboardingButton: View {
    enum Kind { case primary, secondary }

    let title: String
    var kind: Kind = .primary
    var size: CGFloat = 13
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 5
    let action: () -> Void

    init(
        _ title: String,
        kind: Kind = .primary,
        size: CGFloat = 13,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 5,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.size = size
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.action = action
    }

    /// A `.plain` button style opts out of every built-in disabled appearance
    /// along with the rest of the chrome, so the dimming is drawn by hand.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: size, weight: kind == .primary ? .medium : .regular))
                .foregroundStyle(kind == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Color.accentColor)
        case .secondary: AnyShapeStyle(OnboardingMetrics.controlFill)
        }
    }
}

/// Position in the flow, one dot per screen. Shown on the Full Disk Access and
/// folder screens; the welcome and done screens carry their own buttons instead and
/// deliberately have no dots.
struct OnboardingPageDots: View {
    let page: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : OnboardingMetrics.inactiveDot)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// Dots on the left, Back and Continue on the right.
struct OnboardingFooter: View {
    let page: Int
    let pageCount: Int
    var continueTitle = "Continue"
    var continueDisabled = false
    let back: () -> Void
    let advance: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            OnboardingPageDots(page: page, pageCount: pageCount)
            Spacer(minLength: 0)
            OnboardingButton(
                "Back", kind: .secondary, size: 12.5,
                horizontalPadding: 14, action: back)
            OnboardingButton(
                continueTitle, size: 12.5, horizontalPadding: 18, action: advance)
                .disabled(continueDisabled)
        }
    }
}

/// A card with an uppercase header — the "SETUP TAKES TWO STEPS" and
/// "IN SYSTEM SETTINGS" containers.
struct OnboardingCard<Content: View>: View {
    var header: String?
    var spacing: CGFloat = 10
    var radius: CGFloat = OnboardingMetrics.cardRadius
    var padding: EdgeInsets = EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.44)  // the design's +0.04em at 11pt
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnboardingMetrics.cardFill, in: RoundedRectangle(cornerRadius: radius))
    }
}
