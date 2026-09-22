//
//  MainView.swift
//  Viz
//
//  Created by Alin Lupascu on 4/9/24.
//

import Foundation
import SwiftUI
import KeyboardShortcuts
import AlinFoundation

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var historyState: HistoryState
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var updater: Updater
    @State private var windowController = WindowManager.shared


    var body: some View {

        VStack(alignment: .center, spacing: 0) {

            // The header holds only the two bubbles now: the app carries no in-UI branding.
            HStack(alignment: .center, spacing: 10) {

                Spacer()

                HStack() {

                    Button {
                        openAppSettings(selectedTab: updater.updateAvailable ? 2 : 0)
                        dismiss()
                    } label: {
                        Image(systemName: updater.updateAvailable ? "arrow.down.circle" : "gear")
                            .font(.system(size: 17))
                            .vizGlassBubble(tint: updater.updateAvailable ? VizTheme.success.opacity(0.35) : nil)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(updater.updateAvailable ? VizTheme.success : .secondary)

                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "x.circle.fill")
                            .font(.system(size: 18))
                            .vizGlassBubble()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(4)
                .padding(.horizontal, 2)
            }
            .padding(5)
            // The header keeps its height when the popover is squeezed: a tight popover must
            // never swallow the title or make the settings/quit buttons unreachable.
            .fixedSize(horizontal: false, vertical: true)


            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Button("Capture") {
                        CaptureService.shared.captureContent()
                        dismiss()
                    }
                    .help("Capture section of screen to extract text and barcodes")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "viewfinder", size: 15))

                    ShortcutEditorView(name: .captureContent)

                }


                VStack(spacing: 4) {
                    Button("Webcam") {
                        dismiss()
                        openWebcamCapture()
                    }
                    .help("Open webcam capture window for OCR")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "camera", size: 15))

                    ShortcutEditorView(name: .captureWebcam)

                }

                VStack(spacing: 4) {
                    Button("Color") {
                        dismiss()
                        processColor()
                    }
                    .help("Capture hex/rgb value from click location")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "eyedropper", size: 15))

                    ShortcutEditorView(name: .eyedropper)
                }

                VStack(spacing: 4) {
                    Button("History") {
                        openHistory()
                        dismiss()
                    }
                    .help("Show history of captures from this session")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "clock", size: 15))

                    ShortcutEditorView(name: .history)

                }

                VStack(spacing: 4) {
                    Button("Clear") {
                        clearClipboard()
                    }
                    .help("Clear clipboard contents and stored captures")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "delete.left", size: 15))

                    ShortcutEditorView(name: .clear)
                }

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)


        }
        // The popover keeps the classic Viz surface as a translucent glass tint: the panel
        // reads as the app's dark blue-grey while still sampling what is behind it.
        .vizGlassSurface(cornerRadius: 0, tint: VizTheme.surfaceTint)
        .frame(width: 600)
    }
}
