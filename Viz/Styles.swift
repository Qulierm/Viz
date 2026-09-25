//
//  Styles.swift
//  Viz
//
//  Created by Alin Lupascu on 6/3/24.
//

import Foundation
import SwiftUI
import KeyboardShortcuts
import AlinFoundation


struct InfoButton: View {
    @State private var isPopoverPresented: Bool = false
    let text: String
    let color: Color
    let label: String
    let warning: Bool

    init(text: String, color: Color = .primary, label: String = "", warning: Bool = false) {
        self.text = text
        self.color = color
        self.label = label
        self.warning = warning

    }

    var body: some View {
        Button(action: {
            self.isPopoverPresented.toggle()
        }) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: !warning ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundColor(!warning ? color.opacity(0.7) : color)
                    .frame(height: 16)
                    .fixedSize()
                if !label.isEmpty {
                    Text(label)
                        .font(.callout)
                        .foregroundColor(color.opacity(0.7))

                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            VStack {
                Spacer()
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding()
                Spacer()
            }
            .frame(width: 300)
        }
        .padding(.horizontal, 5)
    }
}


struct SimpleButtonBrightStyle: ButtonStyle {
    @State private var hovered = false
    let icon: String
    let help: String
    let color: Color
    let shield: Bool?

    init(icon: String, help: String, color: Color, shield: Bool? = nil) {
        self.icon = icon
        self.help = help
        self.color = color
        self.shield = shield
    }

    func makeBody(configuration: Self.Configuration) -> some View {
        HStack {
            Image(systemName: icon)
                // Same hardening as the popover buttons: size the symbol by font, give it a
                // square slot and make that slot rigid so it cannot be squeezed away.
                .font(.system(size: 20))
                .frame(width: 20, height: 20)
                .fixedSize()
                .foregroundColor(hovered ? color.opacity(0.5) : color)
        }
        .padding(5)
        .onHover { hovering in
            withAnimation() {
                hovered = hovering
            }
        }
        .scaleEffect(configuration.isPressed ? 0.95 : 1)
        .help(help)
    }
}


/// One row of the popover's vertical menu, in the native Wi-Fi panel's style: a leading 27 pt
/// circular badge, a 13 pt primary label and the shortcut hint right-aligned at the row's
/// trailing edge, with the system's unemphasized selection colour as the row's hover highlight.
///
/// The type name is left over from the horizontal row of tiles this replaces; what it draws now
/// is a row (the highlight is still a rounded rectangle). The harness's own renders construct it
/// by name, so the rename belongs with the check re-base.
struct RoundedRectangleButtonStyle: ButtonStyle {
    @State private var isHovered = false
    let image: String
    let size: CGFloat
    /// True for the popover's primary action (Capture): the reference gives that item's badge
    /// the accent fill and every other item the neutral one.
    let primary: Bool
    /// The shortcut whose hint is shown right-aligned in this row; nil draws the row without a
    /// hint (the harness's own renders, which only measure the badge and the fills).
    let shortcutName: KeyboardShortcuts.Name?

    /// SF Symbols have different intrinsic proportions at the same point size - the camera
    /// draws about 20 % wider than the viewfinder - so a single shared size makes a column of
    /// badges look uneven. These point sizes bring the five symbols to the same ink width
    /// (measured at 2x: 31 device px each); anything not listed uses `size`.
    private static let symbolPointSizes: [String: CGFloat] = [
        "viewfinder": 16,
        "camera": 13,
        "eyedropper": 15,
        "clock": 15.5,
        "delete.left": 14.5
    ]

    // MARK: Row geometry
    //
    // The reference's rows measure 64-72 px (32-36 pt) at 2x with a 54 px (27 pt) badge in
    // them, so 32 pt is the bottom of that family and leaves 2.5 pt above and below the badge.
    // These constants are the row's whole geometry: the harness reads them, which is why they
    // are not private.

    /// Height of one row.
    static let rowHeight: CGFloat = 32
    /// Gap between the badge and the row's label.
    static let badgeLabelGap: CGFloat = 10
    /// Inset from the row's own edges to its content.
    static let rowPadding: CGFloat = 10
    /// Padding between the rows and the panel's edges, so every row's hover highlight is inset
    /// from the panel the way the reference's is.
    static let panelPadding: CGFloat = 6
    /// Where the label column starts inside a row. The divider before the destructive row starts
    /// here too, which is what makes it read as a menu divider rather than a full-width rule.
    static var labelColumnInset: CGFloat { rowPadding + VizTheme.badgeDiameter + badgeLabelGap }
    /// How long the row's hover feedback takes (the highlight fading in). The system's own
    /// control feedback sits in the 0.1-0.15 s range. Not private on purpose: the render
    /// harness's `nativetiles` check asserts this value is still inside the system's band.
    static let hoverDuration: TimeInterval = 0.15

    private var pointSize: CGFloat {
        Self.symbolPointSizes[image] ?? size
    }
    let color: Color?

    init(image: String, size: CGFloat, color: Color? = .primary,
         shortcutName: KeyboardShortcuts.Name? = nil, primary: Bool = false) {
        self.image = image
        self.size = size
        self.color = color
        self.shortcutName = shortcutName
        self.primary = primary
    }

    /// The row's leading badge: the reference's 27 pt circle with the glyph inside it. It is a
    /// layout element of the row now (it was a background of an 18 pt icon slot when the popover
    /// was a row of tiles), so the row's height is what holds it; the per-symbol point sizes keep
    /// the five glyphs optically equal, and `.fixedSize()` keeps the badge rigid when the popover
    /// is squeezed vertically.
    @ViewBuilder
    private var badge: some View {
        Image(systemName: image)
            // A `.resizable()` symbol image has no intrinsic size and is the first thing a tight
            // height squeezes, collapsing the icon to nothing: font-based sizing plus a fixed
            // frame is what the badge-collapse guard in the harness protects.
            .font(.system(size: pointSize))
            .foregroundStyle(VizTheme.badgeGlyph(primary: primary))
            .frame(width: VizTheme.badgeDiameter, height: VizTheme.badgeDiameter)
            .fixedSize()
            .background {
                Circle()
                    .fill(VizTheme.badgeFill(primary: primary))
            }
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Self.badgeLabelGap) {
            badge
            configuration.label
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            // The hint sits at the row's trailing edge, so it never pushes the label: the label
            // column is fixed by the badge and the gap above. It stays the app's white hint pill
            // (an explicit earlier instruction) - the native secondary grey is a one-line change
            // here, and BUILDING.md records that.
            if let shortcutName {
                ShortcutEditorView(name: shortcutName)
            }
        }
        .padding(.horizontal, Self.rowPadding)
        .frame(height: Self.rowHeight)
        // The row is the reference's row: **no fill at rest** - the panel's material shows
        // through - and the system's unemphasized selection colour while hovered, in the
        // reference's corner. Nothing else is drawn: no glass fill, no hand-made ring and no
        // press scale (macOS dims or lightens a control while it is held down, it never scales).
        .vizTileHighlight(cornerRadius: VizTheme.cornerControl, hovered: isHovered)
        // The whole row is the hit target, as a menu row is.
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: Self.hoverDuration), value: isHovered)
        .onHover { inside in
            isHovered = inside
        }
    }
}


struct ShortcutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let name: KeyboardShortcuts.Name

    var body: some View {
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            HStack(spacing: 4) {
                Text(shortcut.description)
                    .font(.system(size: 10))
                    .vizPill()
                    .onTapGesture {
                        openAppSettings()
                        dismiss()
                    }
            }
        }
    }
}


struct PaddedProminentButtonStyle: PrimitiveButtonStyle {
    var icon: String? = nil
    var tint: Color? = .blue
    @State private var isHovered: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) {
            HStack(spacing: 5) {
                if let icon = icon {
                    Image(systemName: icon)
                        .imageScale(.medium)
                }
                configuration.label
            }
            .padding(5)

        }
        .buttonStyle(.borderedProminent)
        .tint(tint ?? .blue)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}


struct SpacedToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer() // Adds space between the label and the switch
            Switch(isOn: configuration.$isOn)
                .labelsHidden() // Hide default labels of the switch to use the custom label
        }
    }
}

struct SpacedProcessingToggle: ToggleStyle {
    @AppStorage("postcommands") var postCommands: String = "say [ocr];"
    @State private var showPopover = false

    func makeBody(configuration: Configuration) -> some View {
        HStack() {

            configuration.label

            Button("Edit") {
                showPopover.toggle()
            }
            .buttonStyle(.borderedProminent)
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

            Spacer()

            Switch(isOn: configuration.$isOn)
                .labelsHidden()
        }
    }
}

struct SpacedToggleSeconds: ToggleStyle {
    @AppStorage("previewSeconds") var seconds: Double = 5.0

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {

            configuration.label

            Picker("", selection: $seconds) {
                Text("3s").tag(3.0)
                Text("5s").tag(5.0)
                Text("10s").tag(10.0)
                Text("20s").tag(20.0)
                Text("30s").tag(30.0)
                Text("60s").tag(60.0)
            }
            .buttonStyle(.borderless)

            Spacer() // Adds space between the label and the switch

            Switch(isOn: configuration.$isOn)
                .labelsHidden() // Hide default labels of the switch to use the custom label
        }
    }
}

struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
    }
}


struct SimpleSearchStyle: TextFieldStyle {
    @State private var isHovered = false
    @State var trash: Bool = false
    @EnvironmentObject var appState: AppState
    @AppStorage("postcommands") private var text: String = "say [ocr];"

    func _body(configuration: TextField<Self._Label>) -> some View {

        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.clear)
                .allowsHitTesting(false)
                .frame(height: 30)

            ZStack {
                HStack {
                    configuration
                        .font(.title3)
                        .foregroundColor(.clear)
                        .textFieldStyle(PlainTextFieldStyle())

                    Spacer()

                    if trash && text != "" {
                        Button("") {
                            text = ""
                        }
                        .buttonStyle(SimpleButtonStyle(icon: "xmark.circle.fill", help: "Clear text", size: 14, padding: 0))
                    }
                }

            }
            .padding(.horizontal, 8)

        }
        .onHover { hovering in
            withAnimation(Animation.easeInOut(duration: 0.15)) {
                self.isHovered = hovering
            }
        }
    }
}

struct TrailingRoundedRectangle: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY + cornerRadius),
                    radius: cornerRadius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(0),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        path.addArc(center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
                    radius: cornerRadius,
                    startAngle: .degrees(0),
                    endAngle: .degrees(90),
                    clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()

        return path
    }
}

// Hide blinking textfield caret
extension NSTextView {
    open override var frame: CGRect {
        didSet {
            insertionPointColor = NSColor.textColor//.clear
        }
    }
}


struct SimpleButtonStyle: ButtonStyle {
    @State private var hovered = false
    let icon: String
    let iconFlip: String
    let label: String
    let help: String
    let color: Color
    let size: CGFloat
    let padding: CGFloat
    let rotate: Bool

    init(icon: String, iconFlip: String = "", label: String = "", help: String, color: Color = .primary, size: CGFloat = 20, padding: CGFloat = 5, rotate: Bool = false) {
        self.icon = icon
        self.iconFlip = iconFlip
        self.label = label
        self.help = help
        self.color = color
        self.size = size
        self.padding = padding
        self.rotate = rotate
    }

    func makeBody(configuration: Self.Configuration) -> some View {
        HStack(alignment: .center) {
            Image(systemName: (hovered && !iconFlip.isEmpty) ? iconFlip : icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .fixedSize()
                .scaleEffect(hovered ? 1.1 : 1.0)
                .rotationEffect(.degrees(rotate ? (hovered ? 90 : 0) : 0))
                .animation(.easeInOut(duration: 0.2), value: hovered)
            if !label.isEmpty {
                Text(label)
            }
        }
        .foregroundColor(hovered ? color : color.opacity(0.5))
        .padding(padding)
        .onHover { hovering in
            withAnimation() {
                hovered = hovering
            }
        }
        .scaleEffect(configuration.isPressed ? 0.95 : 1)
        .help(help)
    }
}
