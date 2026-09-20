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
}

extension View {
    /// Liquid Glass on macOS 26+, a translucent material below it.
    @ViewBuilder
    func vizGlassSurface(cornerRadius: CGFloat = VizTheme.cornerLarge, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Glass that reacts to hover/press, for custom controls; material fallback below macOS 26.
    @ViewBuilder
    func vizGlassInteractive(cornerRadius: CGFloat = VizTheme.cornerMedium, tint: Color = VizTheme.accent) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Glass button style on macOS 26+, a matching material button style below it.
    /// `.glass` and `.glassProminent` are different types, so the branches cannot be a
    /// ternary: each has to be applied on its own.
    @ViewBuilder
    func vizGlassButton(prominent: Bool = false, tint: Color = VizTheme.accent) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent).tint(tint)
            } else {
                self.buttonStyle(.glass).tint(tint)
            }
        } else {
            self.buttonStyle(VizMaterialButtonStyle(prominent: prominent, tint: tint))
        }
    }

    /// Capsule used for shortcut hints and small labels.
    func vizPill(tint: Color = VizTheme.accent) -> some View {
        self
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .foregroundStyle(.secondary)
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
