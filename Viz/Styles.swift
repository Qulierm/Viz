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


struct RoundedRectangleButtonStyle: ButtonStyle {
    @State private var isHovered = false
    let image: String
    let size: CGFloat
    /// True for the popover's primary action (Capture): the reference gives that item's badge
    /// the accent fill and every other item the neutral one.
    let primary: Bool

    /// SF Symbols have different intrinsic proportions at the same point size - the camera
    /// draws about 20 % wider than the viewfinder - so a single shared size makes the row
    /// look uneven. These point sizes bring the five popover symbols to the same ink width
    /// (measured at 2x: 31 device px each); anything not listed uses `size`.
    private static let symbolPointSizes: [String: CGFloat] = [
        "viewfinder": 16,
        "camera": 13,
        "eyedropper": 15,
        "clock": 15.5,
        "delete.left": 14.5
    ]

    /// The box every symbol is drawn in, so all five share one vertical centre and the
    /// labels below them start at the same y.
    private static let iconSlot = CGSize(width: 24, height: 18)

    /// How long the tile's hover feedback takes (the hover highlight fading in). The system's
    /// own control feedback sits in the 0.1-0.15 s range, and it replaced a 0.3 s ease that
    /// made the row feel hand-animated next to the rest of the menu bar. Not private on
    /// purpose: the render harness's `nativetiles` check asserts this value is still inside
    /// the system's band.
    static let hoverDuration: TimeInterval = 0.15

    private var pointSize: CGFloat {
        Self.symbolPointSizes[image] ?? size
    }
    let color: Color?
    let shortcut: KeyboardShortcuts.Shortcut?

    init(image: String, size: CGFloat, color: Color? = .primary,
         shortcut: KeyboardShortcuts.Shortcut? = nil, primary: Bool = false) {
        self.image = image
        self.size = size
        self.color = color
        self.shortcut = shortcut
        self.primary = primary
    }

    /// The tile's icon, in the reference's circular badge: a 27 pt circle with the glyph inside
    /// it. The badge is drawn as a *background* of the icon slot rather than as a layout
    /// element, so it grows into the tile's own padding (4.5 pt above and below the 18 pt slot)
    /// and the popover keeps its measured 99 pt height instead of growing for it. The slot
    /// stays the layout slot, which is what keeps the five glyphs optically normalised.
    @ViewBuilder
    private var badge: some View {
        Image(systemName: image)
            // A `.resizable()` symbol image has no intrinsic size, so it is the first
            // thing a tight popover height squeezes on macOS 27, collapsing the icon
            // to nothing while the labels survive. Font-based sizing keeps the symbol
            // at its point size, and `.fixedSize()` makes the slot rigid.
            .font(.system(size: pointSize))
            .foregroundStyle(VizTheme.badgeGlyph(primary: primary))
            .frame(width: Self.iconSlot.width, height: Self.iconSlot.height)
            .fixedSize()
            .background {
                Circle()
                    .fill(VizTheme.badgeFill(primary: primary))
                    .frame(width: VizTheme.badgeDiameter, height: VizTheme.badgeDiameter)
            }
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .center, spacing: 10) {
                badge
                configuration.label
                    .font(.footnote)
                    .foregroundStyle(.primary)

                if let shortcut = shortcut {
                    Text(shortcut.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        // 12 pt rather than 16: the popover is 480 pt wide, and at 16 the five buttons'
        // intrinsic width overflowed it and the outer buttons were clipped. The vertical
        // padding is asymmetric on purpose: the label's 13 pt line box reserves descender
        // space below its ink, so the block needs one point less underneath to look centred.
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
        // The tile is the reference's row, ported: **no fill at rest** - the panel's material is
        // what shows through - and the system's unemphasized selection colour while hovered, in
        // the reference's corner. The badge repeat is what keeps the row reading as five
        // controls without a resting fill, so nothing else is drawn here: the glass fill and
        // the hand-made ring the tile used to carry are both gone, and so is the press scale
        // (macOS dims or lightens a control while it is held down, it never scales it).
        .vizTileHighlight(cornerRadius: VizTheme.cornerControl, hovered: isHovered)
        .foregroundColor(.primary)
        // One continuous rounded rectangle for the tile and its hover highlight, so the
        // highlight's edge and the tile's own bounds cannot disagree.
        .clipShape(VizTheme.controlShape())
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
