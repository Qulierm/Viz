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

    static let cornerLarge: CGFloat = 22
    static let cornerMedium: CGFloat = 16
    static let cornerSmall: CGFloat = 10

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
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
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

    /// Neutral glass control surface: no accent tint, just the material. Used by the
    /// popover action buttons, which must stay grey so the blue accent keeps meaning.
    @ViewBuilder
    func vizGlassControl(cornerRadius: CGFloat = VizTheme.cornerMedium) -> some View {
        if #available(macOS 26.0, *), !VizTheme.useMaterialFallback {
            self.background {
                Color.clear.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
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

    /// Capsule used for shortcut hints and small labels.
    func vizPill() -> some View {
        self
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            // Primary, not .secondary: the shortcut hints are meant to read as labels. That
            // is white in the dark popover and black in light, so it stays readable in both.
            .foregroundStyle(.primary)
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
