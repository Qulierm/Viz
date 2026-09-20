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

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
                .opacity(0.4)
            ScrollView {
                tabContent
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The minimum keeps the window at the size `openAppSettings` asks for: without it
        // AppKit shrinks the window to the content's fitting size and the tab strip and
        // rows end up cramped, which is the layout problem this rebuild fixes.
        .frame(minWidth: 560, minHeight: 520)
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
        .padding(.top, 12)
        .padding(.bottom, 8)
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
            .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 18) {
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
        VStack(alignment: .center) {
            VStack(spacing: 10) {
                    HStack {
                        Text("Capture Content")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .captureContent)
                    }
                    HStack {
                        Text("Capture Webcam")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .captureWebcam)
                    }
                    HStack {
                        Text("Color Picker")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .eyedropper)
                    }
                    HStack {
                        Text("History Window")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .history)
                    }
                    HStack {
                        Text("Clear Clipboard")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .clear)
                    }
                }
                .padding()
                .vizGlassSurface(cornerRadius: VizTheme.cornerLarge)
                .overlay(
                    RoundedRectangle(cornerRadius: VizTheme.cornerLarge)
                        .strokeBorder(VizTheme.accentSoft, lineWidth: 1)
                )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}



struct UpdaterSettingsView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {

                    HStack {
                        FrequencyView(updater: updater)
                        if updater.updateAvailable {
                            Divider()
                                .padding(.trailing, 8)
                            UpdateBadge(updater: updater, hideLabel: true)
                        }

                    }
                    .padding()
                    .vizGlassSurface(cornerRadius: VizTheme.cornerSmall)

                    RecentReleasesView(updater: updater)
                        .frame(height: 380)
                        .frame(maxWidth: .infinity)

                    // === Buttons ==============================================================================================

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
                .padding()
                .vizGlassSurface(cornerRadius: VizTheme.cornerLarge)
                .overlay(
                    RoundedRectangle(cornerRadius: VizTheme.cornerLarge)
                        .strokeBorder(VizTheme.accentSoft, lineWidth: 1)
                )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
