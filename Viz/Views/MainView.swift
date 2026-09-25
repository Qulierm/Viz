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

    /// The rule native menus draw before a destructive item, inset to the label column so it
    /// reads as a menu divider rather than a full-width line.
    private var destructiveDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.leading, RoundedRectangleButtonStyle.labelColumnInset)
            .padding(.trailing, RoundedRectangleButtonStyle.rowPadding)
            .padding(.vertical, 4)
    }

    var body: some View {

        // The popover is a vertical menu in the native Wi-Fi panel's style: one row per action,
        // a divider before the destructive one, and every row's hover highlight inset from the
        // panel by the same padding.
        VStack(alignment: .leading, spacing: 0) {

            Button("Capture") {
                CaptureService.shared.captureContent()
                dismissPopover()
            }
            .help("Capture section of screen to extract text and barcodes")
            // Capture is the popover's primary action, so its badge takes the accent fill the
            // way the reference's connected network does; the rest are neutral.
            .buttonStyle(RoundedRectangleButtonStyle(image: "viewfinder", size: 15,
                                                    shortcutName: .captureContent, primary: true))

            Button("Webcam") {
                dismissPopover()
                openWebcamCapture()
            }
            .help("Open webcam capture window for OCR")
            .buttonStyle(RoundedRectangleButtonStyle(image: "camera", size: 15,
                                                    shortcutName: .captureWebcam))

            Button("Color") {
                dismissPopover()
                processColor()
            }
            .help("Capture hex/rgb value from click location")
            .buttonStyle(RoundedRectangleButtonStyle(image: "eyedropper", size: 15,
                                                    shortcutName: .eyedropper))

            Button("History") {
                openHistory()
                dismissPopover()
            }
            .help("Show history of captures from this session")
            .buttonStyle(RoundedRectangleButtonStyle(image: "clock", size: 15,
                                                    shortcutName: .history))

            destructiveDivider

            Button("Clear") {
                clearClipboard()
            }
            .help("Clear clipboard contents and stored captures")
            .buttonStyle(RoundedRectangleButtonStyle(image: "delete.left", size: 15,
                                                    shortcutName: .clear))

        }
        .padding(.vertical, RoundedRectangleButtonStyle.panelPadding)
        .padding(.horizontal, RoundedRectangleButtonStyle.panelPadding)
        // The popover width comes from the status item controller, so the panel and its
        // content always agree on how wide the popover is.
        .frame(width: StatusItemController.popoverWidth)
    }
}
