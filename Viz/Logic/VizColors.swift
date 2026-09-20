//
//  VizColors.swift
//  Viz
//
//  Colors formerly supplied by Viz/Assets.xcassets. They are defined in code so the
//  Xcode-free SwiftPM build does not depend on `actool`, which ships with Xcode only.
//  Values mirror bg.colorset and mode.colorset (Display P3).
//

import SwiftUI
import AppKit

extension Color {
    /// Replacement for the former `bg` asset lookups — display-P3 (0x31, 0x34, 0x43),
    /// alpha 1.0, identical in light and dark appearance.
    static let vizBackground = Color(.displayP3, red: 49.0 / 255.0, green: 52.0 / 255.0, blue: 67.0 / 255.0, opacity: 1.0)
}

extension NSColor {
    /// Replacement for the former `mode` asset lookup — black in light appearance,
    /// white in dark.
    static let vizInsertionPoint: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }
}
