//
//  VizColors.swift
//  Viz
//
//  The Viz theme: the blue accent palette, the corner radii and the Liquid Glass
//  helpers used by every surface.
//
//  The availability branching lives here on purpose. Liquid Glass (`glassEffect`,
//  `.buttonStyle(.glass)` / `.glassProminent`) is macOS 26+, while Viz deploys to
//  macOS 13, so call sites stay free of `#available` checks and simply ask for a glass
//  surface, a material fallback or a pill. Keeping the branch in one place also keeps
//  the two appearances consistent: nothing here paints an opaque background, so the
//  window vibrancy and the system appearance show through.
//

import SwiftUI
import AppKit

enum VizTheme {
    /// Primary accent: a vivid, slightly soft blue (display-P3).
    static let accent = Color(.displayP3, red: 0.20, green: 0.52, blue: 1.00, opacity: 1.0)
    /// Lighter blue used for the title gradient and highlights.
    static let accentBright = Color(.displayP3, red: 0.45, green: 0.75, blue: 1.00, opacity: 1.0)
    /// Soft accent for tints, hover fills and pills.
    static let accentSoft = accent.opacity(0.18)

    /// The original Viz surface colour (display-P3 #313443) from the pre-redesign palette.
    /// It is used only as a translucent glass tint, so the Liquid Glass surfaces keep the
    /// app's classic dark blue-grey identity instead of being painted flat again.
    static let surface = Color(.displayP3, red: 49.0 / 255.0, green: 52.0 / 255.0, blue: 67.0 / 255.0, opacity: 1.0)
    /// Tint for full-window and popover roots. Deliberately light: the system material and
    /// the desktop have to show through, so the classic hue reads as a cast on the glass
    /// rather than as a filled panel.
    static let surfaceTint = surface.opacity(0.15)
    /// Slightly stronger tint for cards, rows and panels, so they stay a step more defined
    /// than the window they sit on without becoming opaque.
    static let cardTint = surface.opacity(0.20)
    /// Update indicator and copy confirmation.
    static let success = Color.green
    /// URLs, webcam selection and the About button.
    static let link = Color.blue

    static let cornerLarge: CGFloat = 22
    static let cornerMedium: CGFloat = 16
    static let cornerSmall: CGFloat = 10
    /// The popover tile's corner. The native reference's hovered row measures ~14 px (5-7 pt)
    /// in the screenshot, and 6 pt is that value: it is used for the tile's hover highlight
    /// and for the clip that trims the tile.
    static let cornerControl: CGFloat = 6
    /// The tile's shape, defined once so the hover highlight and the clip that trims the tile
    /// draw the same rectangle. The continuous (squircle) curve is stated explicitly rather
    /// than left to `RoundedRectangle`'s default: the app deploys back to macOS 13 and that
    /// default is not the same across the range - the current SDK already defaults to
    /// continuous, older ones default to circular.
    static func controlShape(radius: CGFloat = cornerControl) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// The tile icon's badge: the reference's 54 px (27 pt) circle, mine at 52 px, so 27 pt.
    static let badgeDiameter: CGFloat = 27
    /// The badge's fill. The reference has exactly two states: a vivid blue for the connected
    /// (primary) item and a neutral grey for the rest. Both are semantic: the system accent
    /// (`controlAccentColor`, 0,122,255 here against the reference's measured 0,147,255) and,
    /// for the neutral state, `quaternaryLabelColor` - white at 10 % over a panel of the
    /// reference's own tone (51,52,55) composites to 71,72,75 against the reference's measured
    /// 65,66,70. (`secondarySystemFill` measures 67,68,71, closer, but it is macOS 14+ and this
    /// app deploys to macOS 13; the difference is 5-6 units in one grey step.)
    static func badgeFill(primary: Bool) -> Color {
        primary ? Color(nsColor: .controlAccentColor) : Color(nsColor: .quaternaryLabelColor)
    }
    /// The badge glyph's colour. White on the accent badge, exactly as the reference draws the
    /// connected item. On the neutral badge the reference's glyph measures as a lighter grey
    /// than its fill, and the label colour is that colour in dark appearance (white at 85 %,
    /// compositing to 224) - and, crucially, it inverts in light appearance (black at 85 % on
    /// the light neutral fill), where a fixed white glyph would measure 1.4:1 contrast and
    /// vanish. The port keeps light and dark working instead of hard-coding white.
    static func badgeGlyph(primary: Bool) -> Color {
        primary ? .white : Color(nsColor: .labelColor)
    }

    /// When true the helpers use their translucent-material fallback even on macOS 26+.
    /// Only the render harness sets this: offscreen captures cannot rasterise several
    /// Liquid Glass layers at once (a glass background wipes the siblings drawn before
    /// it), so `scripts/render-check.sh` measures the material rendering instead. The app
    /// itself never changes this, so it always gets real glass on macOS 26+.
    static var useMaterialFallback = false
}

extension View {
    /// Liquid Glass on macOS 26+, a translucent material below it.
    ///
    /// The glass is applied as a background layer rather than by wrapping the view in
    /// `glassEffect`. Both look identical on screen, but a view that is *inside* a glass
    /// effect has its content composited by the glass layer, which no offscreen renderer
    /// can capture (`cacheDisplay` and `ImageRenderer` both return an empty surface, which
    /// would make the design checks blind). Behind the content, the glass is captured
    /// normally and the text stays crisp.
    @ViewBuilder
    func vizGlassSurface(cornerRadius: CGFloat = VizTheme.cornerLarge, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *), !VizTheme.useMaterialFallback {
            self.background {
                if let tint {
                    Color.clear.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
                } else {
                    Color.clear.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                }
            }
        } else {
            // The fallback has to apply the tint too, otherwise the restored palette would
            // only show on macOS 26+ and the material path would render neutral grey.
            self
                // The tint sits directly behind the content and the material behind it, so
                // the surface keeps the material's translucency and the restored hue.
                .background(tint ?? .clear, in: RoundedRectangle(cornerRadius: cornerRadius))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Glass that reacts to hover/press, for custom controls; material fallback below macOS 26.
    @ViewBuilder
    func vizGlassInteractive(cornerRadius: CGFloat = VizTheme.cornerMedium, tint: Color = VizTheme.accent) -> some View {
        if #available(macOS 26.0, *), !VizTheme.useMaterialFallback {
            self.background {
                Color.clear.glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Glass button style on macOS 26+, a matching material button style below it.
    ///
    /// The system styles are used here (rather than a hand-built glass background) because
    /// they also keep the surrounding content intact in offscreen captures, which the
    /// design checks rely on. If a future macOS changes that, the material fallback below
    /// renders the same capsule.
    @ViewBuilder
    func vizGlassButton(prominent: Bool = false, tint: Color = VizTheme.accent) -> some View {
        if #available(macOS 26.0, *), !VizTheme.useMaterialFallback {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            self.buttonStyle(VizMaterialButtonStyle(prominent: prominent, tint: tint))
        }
    }

    /// The popover tile's own surface, ported from the reference: **nothing at rest** - the
    /// reference's rows carry no fill, so the panel's material shows through - and the system's
    /// unemphasized selection fill while hovered, which the reference's hovered row measures
    /// 71,76,86 for. The fill is `unemphasizedSelectedContentBackgroundColor` (a flat grey: 70,70,70
    /// over a dark panel, 220,220,220 over a light one, both fully opaque) so the highlight is
    /// the system's own colour in either appearance.
    ///
    /// This replaces the interactive glass the tile used to sit on: the reference's selected row
    /// is a plain system highlight, not a glass layer, and glass is what made our row look like a
    /// different family. The corner is the continuous reference radius above.
    @ViewBuilder
    func vizTileHighlight(cornerRadius: CGFloat = VizTheme.cornerControl, hovered: Bool) -> some View {
        self.background {
            if hovered {
                VizTheme.controlShape(radius: cornerRadius)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            }
        }
    }

    /// Circular glass control surface (the header bubbles). Neutral by default; pass a
    /// tint for a meaningful state such as an available update.
    @ViewBuilder
    func vizGlassBubble(size: CGFloat = 28, tint: Color? = nil) -> some View {
        self
            .frame(width: size, height: size)
            .vizGlassSurface(cornerRadius: size / 2, tint: tint)
            .contentShape(Circle())
    }

    /// Capsule used for shortcut hints and small labels. Glass like every other surface:
    /// a real capsule glass effect on macOS 26+, and the material-plus-border fallback
    /// below it, so no part of the chrome is a bare material fill.
    @ViewBuilder
    func vizPill() -> some View {
        if #available(macOS 26.0, *), !VizTheme.useMaterialFallback {
            self
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background { Color.clear.glassEffect(.regular, in: .capsule) }
                // Primary, not .secondary: the shortcut hints are meant to read as labels.
                // That is white in the dark popover and black in light, so it stays legible.
                .foregroundStyle(.primary)
        } else {
            self
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .foregroundStyle(.primary)
        }
    }
}

/// Fallback button style used below macOS 26: a capsule with a material fill and an
/// accent tint that matches the Liquid Glass buttons.
struct VizMaterialButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var tint: Color = VizTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, prominent ? 12 : 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .background(
                Capsule().fill(prominent ? tint.opacity(configuration.isPressed ? 0.55 : 0.35) : tint.opacity(configuration.isPressed ? 0.25 : 0.12))
            )
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
