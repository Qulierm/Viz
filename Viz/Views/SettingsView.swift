//
//  SettingsView.swift
//  Viz
//
//  Created by Alin Lupascu on 3/27/25.
//

import Foundation
import SwiftUI
import AlinFoundation
import KeyboardShortcuts
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var updater: Updater
    @AppStorage("appendRecognizedText") var appendRecognizedText: Bool = false
    @AppStorage("keepLineBreaks") var keepLineBreaks: Bool = true
    @AppStorage("showPreview") var showPreview: Bool = true
    @AppStorage("previewSeconds") var seconds: Double = 5.0
    @AppStorage("processing") var processingIsEnabled: Bool = false
    @AppStorage("postcommands") var postCommands: String = "say [ocr];"
    @AppStorage("mute") var mute: Bool = false
    @AppStorage("viewWidth") var viewWidth: Double = 300.0
    @AppStorage("viewHeight") var viewHeight: Double = 200.0
    @EnvironmentObject var appState: AppState
    @AppStorage("settingsSelectedTab") private var selectedTab: Int = 0

    /// Width that fits the widest tab (the Updates tab needs about 686 pt).
    static let windowWidth: CGFloat = 520
    /// Floor for the window content, used when the screen cannot fit a whole tab.
    static let minimumContentHeight: CGFloat = 380
    static let minimumContentWidth: CGFloat = 480
    /// Height of the compact tab strip (8 pt top + item + 6 pt bottom) and of its divider.
    static let tabStripHeight: CGFloat = 59
    static let dividerHeight: CGFloat = 1
    static let contentPadding: CGFloat = 16
    /// Vertical gap between sections inside a tab.
    static let sectionSpacing: CGFloat = 12

    @State private var window: NSWindow?
    @State private var contentHeight: CGFloat = 0
    /// The window is fitted once when it is captured (plus two short retries); later
    /// updates only re-fit when the tab or the measured content height changes.
    @State private var hasFittedWindow = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
                .opacity(0.4)
            ScrollView {
                tabContent
                    .padding(Self.contentPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: SettingsContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
        }
        // The minimum keeps the layout usable on a screen that cannot fit the whole tab;
        // the window is then clamped and this scrolls instead of clipping.
        .frame(minWidth: Self.minimumContentWidth, minHeight: Self.minimumContentHeight)
        .background(SettingsWindowAccessor { window in
            window?.title = "Viz Settings"
            window?.titleVisibility = .visible
            self.window = window
            // On the first open of a fresh process the content-height preference fires
            // before the accessor has stored the window, so that fit is lost and nothing
            // runs again: the window would stay at its initial size with the lower
            // sections clipped. Fit once as soon as the window is captured, again on the
            // next run-loop turn and once after the first layout pass. All three are
            // idempotent - `fitWindowToContent()` only applies a frame that differs by
            // more than half a point - and they run once per window, so a later user
            // resize is not fought.
            if !hasFittedWindow, window != nil {
                hasFittedWindow = true
                fitWindowToContent()
                DispatchQueue.main.async { fitWindowToContent() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fitWindowToContent() }
            }
        })
        .onPreferenceChange(SettingsContentHeightKey.self) { height in
            contentHeight = height
            fitWindowToContent()
        }
        .onChange(of: selectedTab) { _ in
            fitWindowToContent()
        }
    }

    /// Sizes the window to the selected tab: as wide as the widest tab needs, as tall as
    /// the current tab's content, clamped so it can never leave the screen. The top-left
    /// corner is kept so switching tabs does not make the window jump.
    private func fitWindowToContent() {
        guard let window else { return }
        DispatchQueue.main.async {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            // The title bar sits outside the content area, so it is added on top of the
            // height the content asks for.
            let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
            // The hosting view reports exactly how much room the current tab needs (it
            // includes the title-bar safe area). The measured content height is the
            // fallback for the case where the view tree is not available.
            let requiredContent = Self.hostingView(in: window.contentView)?.fittingSize.height
                ?? (Self.tabStripHeight + Self.dividerHeight + contentHeight)
            let maxContent = max(Self.minimumContentHeight, visible.height - 100)
            let contentHeight = min(max(requiredContent, Self.minimumContentHeight), maxContent)
            let height = contentHeight + chrome

            let oldFrame = window.frame
            var frame = NSRect(x: oldFrame.minX, y: oldFrame.maxY - height, width: Self.windowWidth, height: height)
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))

            if abs(frame.height - oldFrame.height) > 0.5 || abs(frame.width - oldFrame.width) > 0.5 || frame.origin != oldFrame.origin {
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }

    /// The tab strip is drawn explicitly instead of using the stock tab bar: inside a
    /// 560x520 window that bar collapsed into an unreadable blob, so the tabs are an icon
    /// over a label with a rounded selection behind the active one.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            tabButton(index: 0, icon: "gear", title: "General")
            tabButton(index: 1, icon: "keyboard", title: "Shortcuts")
            tabButton(index: 2, icon: "arrow.down.circle", title: "Updates")
            tabButton(index: 3, icon: "info.circle", title: "About")
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func tabButton(index: Int, icon: String, title: String) -> some View {
        Button {
            selectedTab = index
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(minWidth: 92)
            .padding(.vertical, 6)
            .background {
                if selectedTab == index {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.12))
                }
            }
            .foregroundStyle(selectedTab == index ? VizTheme.accent : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 1:
            ShortcutsSettingsView()
        case 2:
            UpdaterSettingsView()
                .environmentObject(updater)
        case 3:
            AboutView()
        default:
            GeneralSettingsView(
                appendRecognizedText: $appendRecognizedText,
                keepLineBreaks: $keepLineBreaks,
                showPreview: $showPreview,
                seconds: $seconds,
                processingIsEnabled: $processingIsEnabled,
                postCommands: $postCommands,
                mute: $mute,
                viewWidth: $viewWidth,
                viewHeight: $viewHeight
            )
        }
    }
}

/// A titled group of settings rows: a semibold heading above a glass panel.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .vizGlassSurface(cornerRadius: 14)
        }
    }
}

/// One settings row: a title with an optional subtitle on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// Thin separator drawn between rows, never after the last one.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.35)
            .padding(.leading, 14)
    }
}

/// Post-processing command editor. The settings rows host their controls directly now, so
/// the editor that used to live in the `SpacedProcessingToggle` style lives here.
private struct PostProcessingEditor: View {
    @Binding var postCommands: String
    @State private var showPopover = false

    var body: some View {
        Button("Edit") {
            showPopover.toggle()
        }
        .vizGlassButton()
        .popover(isPresented: $showPopover) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $postCommands)
                    .monospaced()
                    .frame(width: 350, height: 100)
                    .scrollContentBackground(.hidden)
                Divider()
                Text("Execute any shell commands after capture is completed. You may also use the [ocr] token in the commands.\nExample: say [ocr]; echo [ocr] > capture.txt")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
            .vizGlassSurface(cornerRadius: VizTheme.cornerMedium)
            .padding()
        }
    }
}

struct GeneralSettingsView: View {
    @Binding var appendRecognizedText: Bool
    @Binding var keepLineBreaks: Bool
    @Binding var showPreview: Bool
    @Binding var seconds: Double
    @Binding var processingIsEnabled: Bool
    @Binding var postCommands: String
    @Binding var mute: Bool
    @Binding var viewWidth: Double
    @Binding var viewHeight: Double
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsView.sectionSpacing) {
            recognitionSection
            capturesSection
            postProcessingSection
            systemSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recognitionSection: some View {
        SettingsSection(title: "Recognition") {
            SettingsRow(title: "OCR Language", subtitle: "Language used for text recognition") {
                LanguagePickerView()
                    .frame(width: 200)
            }
            SettingsRowDivider()
            SettingsRow(title: "OCR Quality", subtitle: "Fast is quicker, Accurate is more precise") {
                QualityPickerView()
                    .frame(width: 200)
            }
        }
    }

    private var capturesSection: some View {
        SettingsSection(title: "Captures") {
            SettingsRow(title: "Append consecutive captures", subtitle: "New captures are added to the previous text") {
                Toggle("", isOn: $appendRecognizedText)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("When enabled, consecutive captures will be added on to the previous capture")
            }
            SettingsRowDivider()
            SettingsRow(title: "Keep line breaks", subtitle: "Preserve the original line structure") {
                Toggle("", isOn: $keepLineBreaks)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("New lines will be kept from scanned text")
            }
            SettingsRowDivider()
            SettingsRow(title: "Show capture window", subtitle: "The preview appears and hides automatically") {
                HStack(spacing: 8) {
                    Picker("", selection: $seconds) {
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                        Text("20s").tag(20.0)
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                    }
                    .buttonStyle(.borderless)
                    .labelsHidden()
                    .frame(width: 72)
                    Toggle("", isOn: $showPreview)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("When enabled, captured content preview will show and close after \(Int(seconds)) seconds. Otherwise it's not shown at all.")
                }
            }
            SettingsRowDivider()
            SettingsRow(title: "Mute capture sound", subtitle: "Silence the capture chime") {
                Toggle("", isOn: $mute)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Mute the screen capture notification sound")
            }
        }
    }

    private var postProcessingSection: some View {
        SettingsSection(title: "Post-processing") {
            SettingsRow(title: "Post-processing", subtitle: "Run shell commands after each capture") {
                HStack(spacing: 8) {
                    PostProcessingEditor(postCommands: $postCommands)
                    Toggle("", isOn: $processingIsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("When enabled, you can execute shell functions after capture")
                }
            }
        }
    }

    private var systemSection: some View {
        SettingsSection(title: "System") {
            SettingsRow(title: "Launch at login", subtitle: "Start Viz when you log in") {
                Toggle("", isOn: Binding(
                    get: { appState.isLaunchAtLoginEnabled },
                    set: { newValue in
                        updateOnMain {
                            appState.isLaunchAtLoginEnabled = newValue
                            updateLaunchAtLoginStatus(newValue: newValue)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(title: "Capture window size", subtitle: "Width and height of the floating preview") {
                HStack(spacing: 8) {
                    Text("W:")
                    Stepper("\(Int(viewWidth))", value: $viewWidth, in: 200...1000, step: 10)
                        .frame(width: 60, alignment: .trailing)
                    Text("H:")
                    Stepper("\(Int(viewHeight))", value: $viewHeight, in: 100...1000, step: 10)
                        .frame(width: 60, alignment: .trailing)

                    Button {
                        viewWidth = 300.0
                        viewHeight = 200.0
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset dimensions to default")

                    Button {
                        showPreviewWindow(contentView: PreviewContentView())
                    } label: {
                        Image(systemName: "macwindow")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show example window")
                }
            }
        }
    }
}

struct ShortcutsSettingsView: View {
    var body: some View {
        SettingsSection(title: "Shortcuts") {
            SettingsRow(title: "Capture Content", subtitle: "Extract text from a screen selection") {
                KeyboardShortcuts.Recorder(for: .captureContent)
            }
            SettingsRowDivider()
            SettingsRow(title: "Capture Webcam", subtitle: "Recognize content from the camera") {
                KeyboardShortcuts.Recorder(for: .captureWebcam)
            }
            SettingsRowDivider()
            SettingsRow(title: "Color Picker", subtitle: "Copy the colour under the cursor") {
                KeyboardShortcuts.Recorder(for: .eyedropper)
            }
            SettingsRowDivider()
            SettingsRow(title: "History Window", subtitle: "Open the capture history") {
                KeyboardShortcuts.Recorder(for: .history)
            }
            SettingsRowDivider()
            SettingsRow(title: "Clear Clipboard", subtitle: "Clear the clipboard and stored captures") {
                KeyboardShortcuts.Recorder(for: .clear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}



struct UpdaterSettingsView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsView.sectionSpacing) {
            SettingsSection(title: "Updates") {
                SettingsRow(title: "Check for updates", subtitle: "How often Viz looks for a newer release") {
                    HStack(spacing: 8) {
                        FrequencyView(updater: updater)
                        if updater.updateAvailable {
                            Divider()
                                .padding(.trailing, 8)
                            UpdateBadge(updater: updater, hideLabel: true)
                        }
                    }
                    // AlinFoundation's frequency view reports a wide intrinsic size (about
                    // 678 pt), which would force the window wider; the explicit ideal keeps
                    // the fitting size compact while the view still lays out at the width it
                    // is actually given.
                    .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
                }
            }

            SettingsSection(title: "Releases") {
                VStack(alignment: .leading, spacing: 12) {
                    // The releases list is hosted in an overlay on a flexible clear view,
                    // so it takes the width it is given instead of its intrinsic width -
                    // the intrinsic width is what used to force a 690 pt window.
                    Color.clear
                        .frame(height: 300)
                        .overlay {
                            RecentReleasesView(updater: updater)
                        }
                        .clipped()

                    HStack(alignment: .center, spacing: 20) {
                        Spacer()
                        Button {
                            updater.checkForUpdates(sheet: true, force: true)
                        } label: {
                            Label("Refresh", systemImage: "arrow.uturn.left.circle")
                        }
                        .vizGlassButton(prominent: true)

                        Button {
                            NSWorkspace.shared.open(URL(string: "https://github.com/alienator88/Viz/releases")!)
                        } label: {
                            Label("Releases", systemImage: "link")
                        }
                        .vizGlassButton()
                        Spacer()
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


extension SettingsView {
    /// Finds the SwiftUI hosting view in the window's view tree; its `fittingSize` is the
    /// size the current tab actually needs.
    static func hostingView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if String(describing: type(of: view)).contains("NSHostingView") {
            return view
        }
        for subview in view.subviews {
            if let found = hostingView(in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Reports the height of the settings content so the window can be sized to it.
struct SettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Captures the window that hosts the settings so the view can size it to its content.
/// `WindowManager` creates the window, so the size cannot be set at creation time.
struct SettingsWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
