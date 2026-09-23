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

    /// Closes whatever presents the popover: the status item's popover now that the app
    /// owns the menu bar item, plus SwiftUI's dismiss for any other presentation.
    private func dismissPopover() {
        StatusItemController.shared.closePopover()
        dismiss()
    }
    @EnvironmentObject var updater: Updater
    @State private var windowController = WindowManager.shared


    var body: some View {

        VStack(alignment: .center, spacing: 0) {

            HStack(spacing: 8) {
                VStack(spacing: 4) {
                    Button("Capture") {
                        CaptureService.shared.captureContent()
                        dismissPopover()
                    }
                    .help("Capture section of screen to extract text and barcodes")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "viewfinder", size: 15))

                    ShortcutEditorView(name: .captureContent)

                }


                VStack(spacing: 4) {
                    Button("Webcam") {
                        dismissPopover()
                        openWebcamCapture()
                    }
                    .help("Open webcam capture window for OCR")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "camera", size: 15))

                    ShortcutEditorView(name: .captureWebcam)

                }

                VStack(spacing: 4) {
                    Button("Color") {
                        dismissPopover()
                        processColor()
                    }
                    .help("Capture hex/rgb value from click location")
                    .buttonStyle(RoundedRectangleButtonStyle(image: "eyedropper", size: 15))

                    ShortcutEditorView(name: .eyedropper)
                }

                VStack(spacing: 4) {
                    Button("History") {
                        openHistory()
                        dismissPopover()
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
        .frame(width: 600)
    }
}
