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
    private(set) var popover: NSPopover?
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
        if let button = item.button {
            button.image = statusImage(updateAvailable: updater.updateAvailable)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: actionMask)
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: popoverContent)
        let measured = NSHostingView(rootView: popoverContent).fittingSize
        popover.contentSize = NSSize(width: Self.popoverWidth, height: measured.height)
        self.popover = popover

        menu = makeMenu()

        // Keep the menu bar icon reflecting the update state.
        updaterCancellable = updater.$updateAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                self?.statusItem?.button?.image = self?.statusImage(updateAvailable: available)
                self?.statusItem?.button?.image?.isTemplate = true
            }
    }

    private func statusImage(updateAvailable: Bool) -> NSImage? {
        NSImage(systemSymbolName: updateAvailable ? "arrow.down.circle" : "eye",
                accessibilityDescription: "Viz")
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

    func showMenu() {
        guard let button = statusItem?.button, let menu else { return }
        lastPresentation = .menu
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            lastPresentation = .none
        } else {
            lastPresentation = .popover
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Closes the popover, used by the actions that used to dismiss the menu bar window.
    func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
        lastPresentation = .none
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