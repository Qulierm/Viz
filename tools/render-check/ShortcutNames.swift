//
//  ShortcutNames.swift
//  RenderCheck
//
//  The `KeyboardShortcuts.Name` extensions declared by `Viz/VizApp.swift`. That file is
//  excluded from this harness because it carries `@main`, so its shortcut names are
//  reproduced here verbatim to keep the app's real views compiling unchanged.
//

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let captureContent = Self("captureContent", default: .init(.one, modifiers: [.command, .control]))
}

extension KeyboardShortcuts.Name {
    static let captureWebcam = Self("captureWebcam", default: .init(.two, modifiers: [.command, .control]))
}

extension KeyboardShortcuts.Name {
    static let eyedropper = Self("eyedropper", default: .init(.three, modifiers: [.command, .control]))
}

extension KeyboardShortcuts.Name {
    static let history = Self("history", default: .init(.four, modifiers: [.command, .control]))
}

extension KeyboardShortcuts.Name {
    static let clear = Self("clear", default: .init(.five, modifiers: [.command, .control]))
}
