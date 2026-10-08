import AppKit
import SwiftUI

/// The menubar icon, authored in SwiftUI and rasterized before it is handed to
/// `MenuBarExtra`.
///
/// The rasterizing is not decoration: MenuBarExtra renders only `Image` and
/// `Text` in its label, and anything layered on with `.overlay` is silently
/// dropped. Drawing the view through `ImageRenderer` and passing the result as
/// a single `Image` sidesteps that, and keeps the glyph expressed in SwiftUI
/// rather than in AppKit drawing code.
struct MenuBarGlyphContent: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: MenuBarGlyph.pointSize))
            .foregroundStyle(.black)
            // Every state renders into the same box, centred, so the bar never
            // reflows on a state change.
            .frame(width: MenuBarGlyph.glyphSize.width, height: MenuBarGlyph.glyphSize.height)
    }
}

enum MenuBarGlyph {
    /// 14pt, not the design's 19. The menu bar is 22pt tall, and at 19pt the
    /// glyph's box is 25pt — taller than the bar — so it read as visibly
    /// oversized next to the system's own items. At 14 the box is 18pt.
    static let pointSize: CGFloat = 14

    /// The box every state is drawn into: the widest and tallest of the three
    /// symbols at `pointSize`.
    ///
    /// Measured rather than guessed. `photo.badge.exclamationmark` is wider
    /// than the `.angled` pair, and a glyph whose width changes shifts every menu bar item to its
    /// left each time a backup starts or fails. Measuring also means the box
    /// stays correct if a symbol is swapped for another.
    @MainActor
    static let glyphSize: CGSize = {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let sizes = BackupController.GlyphState.allCases.compactMap { state in
            NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)?.size
        }
        guard !sizes.isEmpty else { return CGSize(width: pointSize * 1.5, height: pointSize) }
        return CGSize(
            width: sizes.map(\.width).max() ?? pointSize,
            height: sizes.map(\.height).max() ?? pointSize)
    }()

    /// Renders the glyph for a symbol, **always as a template image**.
    ///
    /// Template means AppKit picks the colour, which is the only way to be
    /// correct: it tints for light and dark menu bars, for the darkening macOS
    /// applies over a dark wallpaper while the system is still in Light mode,
    /// for reduce-transparency, and it inverts while the panel is open.
    ///
    /// An earlier version rendered the badged states non-template so a drawn
    /// badge could be amber or red, and chose the glyph colour from
    /// `NSApplication.effectiveAppearance`. That reports the *system*
    /// appearance, not the menu bar's — so on a dark wallpaper under Light mode
    /// it drew a black glyph on a black bar and the icon vanished, leaving only
    /// a floating red dot. There is no API to read a MenuBarExtra's own
    /// appearance, so the colour had to go, and the state moved into the symbol.
    @MainActor
    static func image(symbol: String) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarGlyphContent(symbol: symbol))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
