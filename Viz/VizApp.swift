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

    /// A non-activating panel can receive spurious resignations in the moment it is ordered
    /// front - the click that opened it also deactivates the previously active app. A
    /// resignation inside this window is therefore ignored; after it, a resignation means
    /// the user moved on and closes the panel.
    static let showGracePeriod: TimeInterval = 0.35
    /// The click that closes the panel is the same click that reaches the button action: the
    /// panel resigns key first, we dismiss it, and the action would then reopen it. Do not
    /// reopen inside this window - a later click opens the popover normally.
    static let toggleSuppressionWindow: TimeInterval = 0.3
    /// When the panel was last shown, used for the grace period.
    private var shownAt: Date?
    /// When the panel was last dismissed, used for the toggle suppression window.
    private var lastDismissalAt: Date?
    /// Click-away monitor, installed while the panel is shown.
    private(set) var clickAwayMonitor: Any?
    /// True once a monitor could not be installed, so the fallback is only logged once.
    private var loggedMonitorFallback = false
    /// Test hook: when set, the grace period is skipped so the harness can exercise the
    /// dismissal paths without waiting.
    var ignoresGracePeriod = false
    /// Test hook: when set, the toggle suppression window is skipped so the harness can
    /// assert that a later click reopens the popover.
    var ignoresToggleSuppression = false

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

        // Dismissal: a resignation after the grace period, a click outside (the global
        // monitor below), Esc and the toggle. The application-deactivation notification is
        // deliberately NOT observed: it fires immediately after the menu bar click that
        // opened the panel, and dismissing on it made the popover invisible.
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)

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
            return
        }
        // The click that closed the panel also reaches this action. Reopening here is what
        // made a second click appear to do nothing, so a dismissal inside the suppression
        // window means "this is that click" - do not reopen.
        if !ignoresToggleSuppression, let lastDismissalAt,
           Date().timeIntervalSince(lastDismissalAt) < Self.toggleSuppressionWindow {
            return
        }
        showPopover()
    }

    /// The panel frame for a given content size, centred under the status button and
    /// clamped so the panel stays inside the screen's visible frame.
    /// The status button's frame in screen coordinates, or nil when the item is not in a
    /// window yet.
    func statusButtonFrame() -> NSRect? {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// True when a screen point is on the status item. The click-away monitor uses this so
    /// the click that belongs to the button action is not also treated as a click outside.
    func isPointOnStatusButton(_ point: NSPoint) -> Bool {
        statusButtonFrame()?.contains(point) ?? false
    }

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
        shownAt = Date()
        guard !recordsPresentationOnly else { return }
        guard let panel else { return }
        panel.setFrame(panelFrame(for: panel.frame.size), display: true)
        panel.makeKeyAndOrderFront(nil)
        installClickAwayMonitor()
    }

    /// Closes the panel, used by the actions that used to dismiss the menu bar window.
    func closePopover() {
        guard let panel, panel.isVisible else {
            removeClickAwayMonitor()
            return
        }
        dismissPanel()
    }

    @objc private func panelResignedKey() {
        // Ignore resignations that arrive in the moment the panel is ordered front: the
        // menu bar click deactivates the previously active app, which would otherwise hide
        // the panel as soon as it appears.
        if !ignoresGracePeriod, let shownAt, Date().timeIntervalSince(shownAt) < Self.showGracePeriod {
            return
        }
        dismissPanel()
    }

    /// Hides the panel and records it. The harness calls this directly for the Esc and
    /// click-away paths.
    func dismissPanel() {
        lastPresentation = .none
        lastDismissalAt = Date()
        panel?.orderOut(nil)
        removeClickAwayMonitor()
    }

    /// Click-away dismissal. A global monitor for mouse-down events needs no permissions and
    /// does not depend on the panel being key, unlike the resign-key path.
    private func installClickAwayMonitor() {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let location = NSEvent.mouseLocation
            // A click on the status item belongs to the button action, not to click-away.
            if !panel.frame.contains(location) && !self.isPointOnStatusButton(location) {
                self.dismissPanel()
            }
            _ = event
        }
        if clickAwayMonitor == nil, !loggedMonitorFallback {
            loggedMonitorFallback = true
            // Without the monitor the panel still closes on the post-grace resignation.
            print("StatusItemController: no global mouse monitor available, relying on resign-key dismissal")
        }
    }

    private func removeClickAwayMonitor() {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
            self.clickAwayMonitor = nil
        }
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
        // AppKit would otherwise hide the panel on the deactivation that follows the menu
        // bar click, independently of our own dismissal logic.
        panel.hidesOnDeactivate = false
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

    static let popoverWidth: CGFloat = 480

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