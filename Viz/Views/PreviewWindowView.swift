//
//  Notification.swift
//  Grabber
//
//  Created by Alin Lupascu on 4/5/24.
//

import Foundation
import AppKit
import SwiftUI
import AlinFoundation

var previewWindow: NSWindow?
var cmdOutputWindow: NSWindow?
var colorWindow: NSWindow?

/// Borderless windows cannot become key by default, which makes the preview's text
/// unselectable for copying. This subclass allows key without becoming main.
final class KeyablePreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}


struct PreviewContentView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var content = RecognizedContent.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()

                Button("Close") {
                    previewWindow?.orderOut(nil)
                    previewWindow = nil
                }
                .vizGlassButton()
                .help("Close")
            }
            .padding(2)

            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(content.items, id: \.id) { item in
                        let text = item.text
                        let trimmedText = text.last == "\n" ? String(text.dropLast()) : text
                        Text(trimmedText)
                            .textSelection(.enabled)
                    }
                }
            }
            .scrollIndicators(.visible)
            .padding([.horizontal, .bottom])
            .frame(minWidth: 200)

            Spacer()


            if !appState.cmdOutput.isEmpty {
                HStack(spacing: 0) {
                    Rectangle()
                        .frame(height: 1)
                        .opacity(0.2)

                    Text("Processing Output")
                        .textCase(.uppercase)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 150)

                    Rectangle()
                        .frame(height: 1)
                        .opacity(0.2)
                }
                .frame(minHeight: 35)

                ScrollView {
                    Text(appState.cmdOutput)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(width: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .padding([.horizontal, .bottom])


            }
        }
        .padding(6)
        .vizGlassSurface(cornerRadius: VizTheme.cornerLarge, tint: VizTheme.cardTint)
        .foregroundColor(.primary)
        .material(.sidebar)
    }
}


struct ColorPreviewView: View {

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()

                Button("Close") {
                    previewWindow?.orderOut(nil)
                    previewWindow = nil
                }
                .vizGlassButton()
                .help("Close")
            }
            .padding(2)

            VStack(alignment: .leading) {
                Text("Hex: \(AppState.shared.colorSample.hex)")
                Text("RGB: \(AppState.shared.colorSample.rgb)")
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppState.shared.colorSample.color)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(VizTheme.accent.opacity(0.45), lineWidth: 1)
                    }
                    .shadow(color: VizTheme.accent.opacity(0.25), radius: 4, x: 0, y: 1)
            }
            .padding([.horizontal, .bottom])
        }
        .padding(6)
        .vizGlassSurface(cornerRadius: VizTheme.cornerLarge, tint: VizTheme.cardTint)
        .foregroundColor(.primary)
        .material(.sidebar)
    }
}





func showPreviewWindow<Content: View>(contentView: Content) {
    @AppStorage("previewSeconds") var seconds: Double = 5.0
    @AppStorage("processing") var processingIsEnabled: Bool = false
    @AppStorage("showPreview") var showPreview: Bool = true
    @AppStorage("viewWidth") var viewWidth: Double = 300.0
    @AppStorage("viewHeight") var viewHeight: Double = 200.0

    guard showPreview else { return }

    previewWindow?.orderOut(nil)
    previewWindow = nil

    let height: CGFloat = (processingIsEnabled && contentView is PreviewContentView) ? viewHeight + 100 : viewHeight
    let hostingView = NSHostingView(rootView: contentView)
    hostingView.frame = CGRect(x: 0, y: 0, width: viewWidth, height: height)

    previewWindow = KeyablePreviewWindow(contentRect: NSRect(x: 0, y: 0, width: viewWidth, height: height),
                                        styleMask: .borderless,
                                        backing: .buffered,
                                        defer: false)
    previewWindow?.contentView = hostingView
    previewWindow?.contentView?.wantsLayer = true
    previewWindow?.contentView?.layer?.cornerRadius = 10
    previewWindow?.contentView?.layer?.masksToBounds = true
    previewWindow?.level = .floating
    previewWindow?.isOpaque = false
    previewWindow?.backgroundColor = .clear

    if let screen = NSScreen.main {
        let screenRect = screen.visibleFrame
        let windowX = screenRect.maxX - viewWidth - 30
        let windowY = screenRect.maxY - height - 30
        previewWindow?.setFrameOrigin(NSPoint(x: windowX, y: windowY))
    }

    previewWindow?.orderFront(nil)

    // Hide after the configured delay, but never while the user is working with the
    // preview: if the window is key (text selected, ⌘C pressed) the hide is postponed
    // once instead of pulling the window away mid-interaction.
    func hidePreview(after delay: Double, allowReschedule: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = previewWindow else { return }
            if window.isKeyWindow && allowReschedule {
                hidePreview(after: delay, allowReschedule: false)
                return
            }
            window.orderOut(nil)
            previewWindow = nil
        }
    }
    hidePreview(after: seconds, allowReschedule: true)
}
