//
//  GrabberApp.swift
//  Grabber
//
//  Created by Alin Lupascu on 4/5/24.
//

import SwiftUI
import Combine
import KeyboardShortcuts
import AlinFoundation

@main
struct VizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var appState = AppState.shared
    @StateObject private var updater = AppServices.shared.updater

    var body: some Scene {
        // The menu bar item is owned by `StatusItemController` instead of a `MenuBarExtra`
        // scene: only an AppKit status item can tell a right click from a left click, and
        // the right click carries the settings and quit menu. The `Settings` scene stays so
        // the app keeps a scene of its own.
        Settings {
            SettingsView()
                .tint(VizTheme.accent)
                .environmentObject(appState)
                .environmentObject(HistoryState.shared)
                .environmentObject(updater)
                .toolbarBackground(.clear)
                .movableByWindowBackground()
        }
    }
}


class AppDelegate: NSObject, NSApplicationDelegate {
    @Environment(\.dismiss) private var dismiss
    @State private var windowController = WindowManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {

        StatusItemController.shared.start(updater: AppServices.shared.updater)

        KeyboardShortcuts.onKeyUp(for: .captureContent) {
            CaptureService.shared.captureContent()
        }

        KeyboardShortcuts.onKeyUp(for: .captureWebcam) {
            self.dismiss()
            openWebcamCapture()
        }

        KeyboardShortcuts.onKeyUp(for: .eyedropper) {
            processColor()
        }

        KeyboardShortcuts.onKeyUp(for: .history) {
            self.windowController.open(id: "history", with: HistoryView(), width: 500, height: 600, material: .sidebar)
            self.dismiss()
        }

        KeyboardShortcuts.onKeyUp(for: .clear) {
            clearClipboard()
        }

#if !DEBUG
        ensureApplicationSupportFolderExists()
#endif

    }

}



/// The popover panel. It is borderless and non-activating, sits above normal windows and
/// closes on Esc; `canBecomeKey` is true so it can receive the key press.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Owns the menu bar status item. A left click toggles a transient popover hosting the
/// capture actions; a right click shows a menu with the settings and quit items. The app
/// has to own the item itself because `MenuBarExtra` offers no way to tell which mouse
/// button was pressed.
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    /// What the last handled click did. The render harness asserts on this instead of
    /// synthesising mouse events.
    enum Presentation {
        case none
        case popover
        case menu
    }

    private(set) var statusItem: NSStatusItem?
    /// The popover panel and the visual-effect view that draws its background with the
    /// menu bar's own material.
    private(set) var panel: MenuPanel?
    private(set) var effectView: NSVisualEffectView?
    /// The menu shown on a right click.
    private(set) var menu: NSMenu?
    private(set) var lastPresentation: Presentation = .none

    /// The mask installed on the status button: both mouse-up kinds reach the same action,
    /// which then branches on `NSApp.currentEvent`.
    let actionMask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]

    private var updaterCancellable: AnyCancellable?

    /// The popover content, kept in one place so its size and environment match the app.
    @ViewBuilder
    private var popoverContent: some View {
        ContentView()
            .tint(VizTheme.accent)
            .environmentObject(AppServices.shared.updater)
            .environmentObject(AppState.shared)
            .environmentObject(HistoryState.shared)
    }

    func start(updater: Updater) {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        updateStatusIcon(updateAvailable: updater.updateAvailable)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: actionMask)
        }

        let measured = NSHostingView(rootView: popoverContent).fittingSize
        let size = NSSize(width: Self.popoverWidth, height: measured.height)
        panel = makePanel(size: size)

        // Click-away and app-switch dismissal; NSPopover's .transient behaviour used to
        // provide this for free.
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSApplication.didResignActiveNotification, object: nil)

        menu = makeMenu()

        // Keep the menu bar icon reflecting the update state.
        updaterCancellable = updater.$updateAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                self?.updateStatusIcon(updateAvailable: available)
            }
    }

    /// The symbol currently installed on the status button. `NSImage.name()` is nil for
    /// symbol images, so the controller keeps the name it used - which is also what the
    /// harness asserts on.
    private(set) var statusSymbolName: String = "eye"

    private func updateStatusIcon(updateAvailable: Bool) {
        statusSymbolName = updateAvailable ? "arrow.down.circle" : "eye"
        let image = NSImage(systemSymbolName: statusSymbolName, accessibilityDescription: "Viz")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// The right-click menu: settings and quit.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func statusButtonClicked(_ sender: Any?) {
        handle(eventType: NSApp.currentEvent?.type)
    }

    /// Branches on the mouse button. Split out from the action so the harness can drive it.
    func handle(eventType: NSEvent.EventType?) {
        switch eventType {
        case .rightMouseUp:
            showMenu()
        default:
            togglePopover()
        }
    }

    /// When true the controller only records what it would present instead of presenting
    /// it. The render harness sets this: `NSMenu.popUp` and `NSPopover.show` start real UI
    /// tracking, which would block the harness process.
    var recordsPresentationOnly = false

    func showMenu() {
        lastPresentation = .menu
        guard !recordsPresentationOnly else { return }
        guard let button = statusItem?.button, let menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    func togglePopover() {
        guard let panel else { return }
        if panel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// The panel frame for a given content size, centred under the status button and
    /// clamped so the panel stays inside the screen's visible frame.
    func panelFrame(for size: NSSize) -> NSRect {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            return NSRect(origin: .zero, size: size)
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? buttonFrame
        var origin = NSPoint(x: buttonFrame.midX - size.width / 2,
                             y: buttonFrame.minY - size.height - 4)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSRect(origin: origin, size: size)
    }

    private func showPopover() {
        lastPresentation = .popover
        guard !recordsPresentationOnly else { return }
        guard let panel else { return }
        panel.setFrame(panelFrame(for: panel.frame.size), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel, used by the actions that used to dismiss the menu bar window.
    func closePopover() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        lastPresentation = .none
    }

    @objc private func panelResignedKey() {
        // Record the dismissal as well as hiding the panel: the harness posts the
        // notification to prove the observer is installed, and in its process the panel is
        // never on screen.
        lastPresentation = .none
        panel?.orderOut(nil)
    }

    /// Builds the borderless, non-activating panel and its menu-material background.
    private func makePanel(size: NSSize) -> MenuPanel {
        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        // The menu bar's own material, sampled from what is behind the window, so the
        // popover merges with the menu bar and follows the wallpaper automatically.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: popoverContent)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        panel.contentView = effect
        effectView = effect
        return panel
    }

    static let popoverWidth: CGFloat = 600

    @objc private func openSettings() {
        closePopover()
        openAppSettings(selectedTab: AppServices.shared.updater.updateAvailable ? 2 : 0)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

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