//
//  Windows.swift
//  Viz
//
//  Created by Alin Lupascu on 3/27/25.
//

import SwiftUI
import AlinFoundation
import AVFoundation

func openHistory() {
    WindowManager.shared.open(id: "history", with: HistoryView(), width: 500, height: 600)
}

func openAbout() {
    WindowManager.shared.open(id: "about", with: AboutView(), width: 400, height: 450)
}

func openAppSettings(selectedTab: Int = 0) {
    // SwiftUI's `openSettings` environment action only exists inside a View, so calling it
    // from here silently did nothing on macOS 27 (the click just stored the tab and
    // stopped). The settings therefore open in a regular window through WindowManager,
    // exactly like the History and About windows.
    UserDefaults.standard.set(selectedTab, forKey: "settingsSelectedTab")
    WindowManager.shared.open(
        id: "settings",
        with: SettingsView()
            .environmentObject(AppState.shared)
            .environmentObject(HistoryState.shared)
            .environmentObject(AppServices.shared.updater),
        width: 520,
        height: 460,
        material: .sidebar
    )
    NSApp.activate(ignoringOtherApps: true)
}

private var webcamWindow: NSWindow?

func openWebcamCapture() {
    // Show existing window if already open
    if let existingWindow = webcamWindow, existingWindow.isVisible {
        DispatchQueue.main.async {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return
    }
    
    // Close existing window
    webcamWindow?.close()
    webcamWindow = nil
    
    // Create window on main thread (SwiftUI requirement)
    DispatchQueue.main.async {
        let hostingController = NSHostingController(rootView: WebcamCaptureView())
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 650, height: 450))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.center()
        window.minSize = NSSize(width: 320, height: 240)
        
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        webcamWindow = window
    }
}
