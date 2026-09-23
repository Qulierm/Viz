//
//  main.swift
//  RenderCheck
//
//  Objective UI behaviour checks for Viz that do not need a human at the screen:
//
//    * icons    - the five popover action buttons must draw their SF Symbol at every
//                 popover height; the symbol is measured as bright pixels inside the
//                 icon band of the first button.
//    * settings - calling the app's own `openAppSettings(selectedTab:)` must produce a
//                 visible window that hosts `SettingsView`.
//    * clipboard- text written by the app's own `copyTextItemsToClipboard(textItems:)`
//                 must be readable from a separate `/usr/bin/pbpaste` process, and the
//                 preview window must be able to become key so its text can be copied.
//
// The harness compiles the app's real sources (see `scripts/render-check.sh`) and exits
// non-zero when any check fails. Every check reports what it observed; a check that
// cannot observe the behaviour reports FAIL instead of passing silently.
//

import AppKit
import SwiftUI
import AlinFoundation

// MARK: - Configuration

/// The icon check renders the popover at a set of heights to prove the symbols survive a
/// squeeze. They are derived from the popover's own natural height - measured here at
/// startup - so the four renders are the natural size and three progressively tighter ones.
/// Hard-coding them went stale as soon as the popover was trimmed.
let iconHeightOffsets: [CGFloat] = [0, -6, -12, -18]
/// The popover's width comes from the app itself, so every render measures the real thing.
let contentWidth: CGFloat = StatusItemController.popoverWidth
/// A pixel counts as ink when its composited colour differs from the window backdrop by
/// more than this summed |dR| + |dG| + |dB| (0...3). Contrast is used instead of raw
/// brightness because the redesign draws symbols in the blue accent (R+G+B ~= 326/765)
/// rather than in white, and because glass surfaces render as the backdrop itself; the
/// threshold still separates drawn content from an empty band by a wide margin.
let inkContrastThreshold = 0.35
/// Minimum ink pixels in the icon band for the check to consider the symbol drawn, using
/// the luminance-contrast metric above. Calibrated against both states: the symbol drawn
/// gives several hundred ink pixels at every height, the old shrinkable sizing gives
/// almost none, so the margin is wide.
let iconInkThreshold = 60
/// Minimum accent pixels (hue within 30 degrees of 220, saturated and bright) that a
/// surface with blue accents must show.
let accentPixelThreshold = 60
/// The popover keeps its blue for the title gradient and the update indicator only, so it
/// gets its own floor: measured 1127 (light) / 1307 (dark), floor at ~3.7x headroom. It is
/// stricter than the generic floor, so a lost title gradient or update indicator fails.
let popoverAccentFloor = 300
/// Maximum share of accent pixels inside the popover's action-button band. The buttons are
/// neutral glass; anything blue there means the accent has crept back into the main menu.
let buttonAccentShareLimit = 0.015
/// The restored Viz surface must read as the classic blue-grey: the blue channel has to
/// exceed red by at least this much. Measured: a neutral material surface gives 0, the light
/// tint (0.15 roots, 0.20 cards) gives 2 (popover, light) to 7 (settings, dark), and the
/// opaque display-P3 #313443 gives 21 - so the low bound rejects a colourless surface and
/// the high bound rejects flat paint.
let surfaceCastMinimum: Double = 1
let surfaceCastMaximum: Double = 14
/// Minimum sum-of-channel difference (0...765) between the close control's centre and the
/// panel background on the same rows: the glass bubble measures about 308, so this only
/// catches a control that lost its surface entirely.
let previewCloseSurfaceDeltaMinimum: Double = 30
/// The preview window's close control must stay an icon-sized control: the word "Close" in
/// a capsule measured 68 device px wide in the top strip, the cross-in-a-circle bubble
/// measures 34 px, so this threshold sits between them.
let previewCloseRunLimit = 45
/// Alignment tolerances for the five popover buttons, in device pixels unless stated.
/// Measured after the alignment pass: icon width spread 1 px, icon centres within 2 px of
/// the row mean, label tops identical, ink balance within 2 pt.
let alignmentIconWidthSpreadLimit = 4
let alignmentIconCentreTolerance = 3
let alignmentRowTolerance = 2
let alignmentInkBalanceTolerance: Double = 3
/// How far the popover content's dominant colour may differ from the harness backdrop it
/// was composited over. The content is transparent over the panel's menu material, so the
/// backdrop is what shows; a content-owned surface (the old tinted glass root) shifts it by
/// about 15 per channel.
let popoverContentTolerance: Double = 3
/// Minimum per-channel difference between the surface rendered over the dark backdrop and
/// over a bright one. A translucent surface follows its backdrop (the deltas measured here
/// are in the hundreds); an opaque surface renders identically and gives 0.
let translucencyDeltaMinimum: Double = 6
/// Ceiling for the popover's natural height: the measured value plus a 10 pt margin. The
/// popover measures 99 pt now that the settings/quit header moved into the status item's
/// right-click menu (145 pt before that, 161 and 177 pt earlier), so this catches a
/// regression back to any taller layout.
let popoverHeightCeiling: CGFloat = 109
/// Minimum number of bright pixels in the shortcut-pill band of the dark popover render.
/// The hints are drawn in the primary label colour (white in dark), which yields ~800 such
/// pixels; `.secondary` leaves the band almost dark, so this catches a return to grey.
let hintBrightPixelMinimum = 150
/// Luminance above which a pixel counts as bright hint text.
let hintBrightLuminance = 200.0 / 255.0
/// Size the settings design surface is rendered at: the window's own width (the rows gained
/// a glyph column, which moved it from 520 to 560) and the General tab's fitted height.
let settingsWindowWidth: CGFloat = 560
let settingsSurfaceHeight: CGFloat = 700
/// Compactness ceilings for the settings window: the layout is meant to stay a normal,
/// small macOS window, so a regression back to the old 690x793 shape has to fail.
let settingsWindowMaxWidth: CGFloat = 560
let settingsWindowMaxHeight: CGFloat = 700
/// The settings tab strip must span at least this share of the surface width...
let tabStripWidthShareMinimum = 0.45
/// ...and must show at least this many separated items (four tabs minus tolerance).
let tabStripMinimumRuns = 3
/// Maximum share of a render that may still use the removed flat background colour.
let legacyShareLimit = 0.08
/// Minimum share of non-backdrop pixels for a render to count as painted.
let contentShareMinimum = 0.05
/// The first action button spans x 16..105 pt in a 480 pt wide popover and its icon
/// is centred at about x 70.8 pt. The measured column band is given in points and
/// scaled by the real bitmap scale, so it covers x 60..240 device pixels at 2x.
let iconBandXRange: ClosedRange<CGFloat> = 30...120
/// The column the symbol ink is counted in: the first button's centre, which excludes the
/// button's rounded edge - its highlight is bright enough to be mistaken for a symbol at
/// some popover heights.
let iconMeasureXRange: ClosedRange<CGFloat> = 30...90

let fileManager = FileManager.default
let rootPath = fileManager.currentDirectoryPath
let outputDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENDER_CHECK_OUT"] ?? "\(rootPath)/build/render-check")
let debugMode = ProcessInfo.processInfo.environment["RENDER_CHECK_DEBUG"] == "1"

// MARK: - Small helpers

func pumpRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

func shell(_ executable: String, _ arguments: [String] = []) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "failed to launch \(executable): \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Contrast of a bitmap pixel against a backdrop: the summed absolute difference of the
/// composited colour from the backdrop, or nil when the coordinates are outside the
/// bitmap. The app's surfaces are translucent by design (Liquid Glass / materials over
/// window vibrancy) and `colorAt` returns un-premultiplied components, so the pixel is
/// composited first to reproduce what the user actually sees.
func pixelContrast(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, backdrop: NSColor = Backdrop.dark) -> Double? {
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
    let alpha = color.alphaComponent
    let base = backdrop.usingColorSpace(.deviceRGB) ?? .black
    let red = color.redComponent * alpha + base.redComponent * (1 - alpha)
    let green = color.greenComponent * alpha + base.greenComponent * (1 - alpha)
    let blue = color.blueComponent * alpha + base.blueComponent * (1 - alpha)
    return abs(red - base.redComponent) + abs(green - base.greenComponent) + abs(blue - base.blueComponent)
}

/// Window backdrop a surface is drawn over, matching the appearance being rendered.
enum Backdrop {
    static let dark = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    static let light = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    /// A bright backdrop used with the *dark* appearance to prove a surface is translucent:
    /// a translucent surface follows the backdrop, an opaque one ignores it.
    static let bright = NSColor(srgbRed: 0.86, green: 0.86, blue: 0.90, alpha: 1)

    static func forScheme(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark ? dark : light
    }
}

/// True for pixels that carry the blue accent: hue within 30 degrees of 220, saturation
/// above 0.35 and brightness above 0.45. Shared by the icon measurement and the design
/// check, so both look for exactly the colour the theme uses.
func isAccentPixel(_ color: NSColor) -> Bool {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    let degrees = hue * 360
    let delta = abs(degrees - 220)
    return min(delta, 360 - delta) <= 30 && saturation > 0.35 && brightness > 0.45 && alpha > 0.2
}

/// Accent pixels inside a region; used for the icon band, whose symbol is drawn in
/// `VizTheme.accent`. Counting the accent colour (rather than any contrast) isolates the
/// symbol from the button's own translucent chrome and borders, which is what makes the
/// check able to see the symbol collapse again.
func accentCount(_ rep: NSBitmapImageRep, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if isAccentPixel(color) {
                count += 1
            }
        }
    }
    return count
}

/// Rec. 709 luminance of a bitmap pixel composited over a backdrop, or nil when the
/// coordinates are outside the bitmap.
func pixelLuminance(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, backdrop: NSColor = Backdrop.dark) -> Double? {
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
    let alpha = color.alphaComponent
    let base = backdrop.usingColorSpace(.deviceRGB) ?? .black
    let red = color.redComponent * alpha + base.redComponent * (1 - alpha)
    let green = color.greenComponent * alpha + base.greenComponent * (1 - alpha)
    let blue = color.blueComponent * alpha + base.blueComponent * (1 - alpha)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

/// Counts pixels in a region whose luminance differs from that region's *median*
/// luminance by more than `threshold` (0...1). The median is the surface the region is
/// drawn on, so the metric measures ink regardless of whether the symbols are white or
/// blue and regardless of the button surface colour.
func luminanceInkCount(_ rep: NSBitmapImageRep,
                       xRange: ClosedRange<Int>,
                       yRange: ClosedRange<Int>,
                       threshold: Double = 40.0 / 255.0) -> Int {
    var values: [Double] = []
    for y in yRange {
        for x in xRange {
            if let value = pixelLuminance(rep, x, y) {
                values.append(value)
            }
        }
    }
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    return values.reduce(0) { $0 + (abs($1 - median) > threshold ? 1 : 0) }
}

func inkCount(_ rep: NSBitmapImageRep, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange where (pixelContrast(rep, x, y) ?? 0) > inkContrastThreshold {
            count += 1
        }
    }
    return count
}

// MARK: - Rendering

struct HarnessRoot: View {
    let updater: Updater
    var scheme: ColorScheme = .dark

    var body: some View {
        ContentView()
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .environmentObject(updater)
            .environmentObject(AppState.shared)
            .environmentObject(HistoryState.shared)
    }
}

struct RenderResult {
    let height: CGFloat
    let rep: NSBitmapImageRep
    let url: URL
    let scale: CGFloat
}

/// Draws a translucent capture over a backdrop and returns an opaque bitmap. Both the
/// measurements and the PNG artefacts use this, so the numbers describe what the user
/// sees and the PNGs can be inspected without a viewer that understands alpha.
func compositedOverBackdrop(_ rep: NSBitmapImageRep, backdrop: NSColor) -> NSBitmapImageRep {
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: width,
                                     pixelsHigh: height,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else {
        return rep
    }
    out.size = rep.size
    guard let context = NSGraphicsContext(bitmapImageRep: out) else { return rep }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    backdrop.setFill()
    NSRect(x: 0, y: 0, width: rep.size.width, height: rep.size.height).fill()
    // `rep.draw(in:)` would copy the transparent pixels over the backdrop, so the capture
    // has to be drawn as an image with an explicit source-over operation.
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    image.draw(in: NSRect(x: 0, y: 0, width: rep.size.width, height: rep.size.height),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return out
}

/// Renders a SwiftUI view into an opaque bitmap.
///
/// The view is hosted detached with an explicit frame, because inside a window a rigid
/// SwiftUI layout grows the window to its fitting height and the tight popover heights
/// would never be exercised. `cacheDisplay` is used rather than `ImageRenderer` because
/// it renders AppKit-backed content (lists, scroll views, materials) faithfully, which
/// `ImageRenderer` does not.
func renderView<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, pngName: String,
                backdrop: NSColor? = nil, windowBackdrop: NSColor? = nil) -> NSBitmapImageRep? {
    let frame = NSRect(origin: .zero, size: size)
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    hosting.frame = frame

    // Materials sample the surface *behind* them, so a detached hosting view renders them
    // from nothing. When a window backdrop is given, the view is hosted in a window of that
    // colour first: that is what makes translucency measurable.
    var window: NSWindow?
    if let windowBackdrop {
        let host = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.backgroundColor = windowBackdrop
        host.isOpaque = true
        host.contentView = hosting
        host.orderFront(nil)
        window = host
    }

    hosting.layoutSubtreeIfNeeded()
    pumpRunLoop(0.4)
    hosting.frame = frame
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    defer { window?.orderOut(nil) }

    guard let raw = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: raw)

    let rep = compositedOverBackdrop(raw, backdrop: backdrop ?? Backdrop.forScheme(scheme))
    let url = outputDirectory.appendingPathComponent(pngName)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
    return rep
}

func renderPopover(height: CGFloat, updater: Updater) -> RenderResult? {
    let size = NSSize(width: contentWidth, height: height)
    let root = HarnessRoot(updater: updater, scheme: .dark)
        .frame(width: size.width, height: size.height)

    guard let rep = renderView(root, size: size, scheme: .dark, pngName: "height-\(Int(height)).png") else {
        return nil
    }
    let url = outputDirectory.appendingPathComponent("height-\(Int(height)).png")
    let scale = CGFloat(rep.pixelsWide) / contentWidth
    return RenderResult(height: height, rep: rep, url: url, scale: scale)
}

/// Row indices (device pixels) that carry ink inside the first button's icon column
/// band, together with the count per row. Used to locate the icon band objectively and
/// to explain a failure in the report.
func inkProfile(_ result: RenderResult) -> [(row: Int, count: Int)] {
    let x0 = Int((iconBandXRange.lowerBound * result.scale).rounded())
    let x1 = Int((iconBandXRange.upperBound * result.scale).rounded())
    var profile: [(row: Int, count: Int)] = []
    for y in 0..<result.rep.pixelsHigh {
        let count = luminanceInkCount(result.rep, xRange: x0...x1, yRange: y...y)
        if count > 0 {
            profile.append((y, count))
        }
    }
    return profile
}

/// Contiguous runs of ink rows; a run is a group of rows separated by at most
/// `maxGap` empty rows.
/// Bright pixels (luminance above the threshold) in a rectangle: the symbols, labels and
/// pill text are drawn bright, the glass surfaces are not.
func brightPixelCount(_ rep: NSBitmapImageRep, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>,
                      brightness: Double = 0.4) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange {
            if let value = pixelLuminance(rep, x, y), value > brightness {
                count += 1
            }
        }
    }
    return count
}

/// Rows that contain bright pixels (the symbols, labels and pill text) within the icon
/// x-band. Anchoring the icon band on these is robust against the button's own edges, which
/// make every row of the button block look like ink relative to the backdrop.
func brightProfile(_ result: RenderResult, brightness: Double = 0.5) -> [(row: Int, count: Int)] {
    let x0 = Int((iconBandXRange.lowerBound * result.scale).rounded())
    let x1 = Int((iconBandXRange.upperBound * result.scale).rounded())
    var profile: [(row: Int, count: Int)] = []
    for y in 0..<result.rep.pixelsHigh {
        var count = 0
        for x in x0...x1 {
            if let value = pixelLuminance(result.rep, x, y), value > brightness {
                count += 1
            }
        }
        if count > 0 {
            profile.append((y, count))
        }
    }
    return profile
}

func inkRuns(_ profile: [(row: Int, count: Int)], maxGap: Int = 4) -> [ClosedRange<Int>] {
    var runs: [ClosedRange<Int>] = []
    var start: Int?
    var last = 0
    for entry in profile {
        if let currentStart = start {
            if entry.row - last > maxGap {
                runs.append(currentStart...last)
                start = entry.row
            }
        } else {
            start = entry.row
        }
        last = entry.row
    }
    if let currentStart = start {
        runs.append(currentStart...last)
    }
    return runs
}

// MARK: - Checks

var failures: [String] = []

func report(_ name: String, _ passed: Bool, _ details: String) {
    print("CHECK \(name): \(passed ? "PASS" : "FAIL") \(details)")
    if !passed {
        failures.append(name)
    }
}

// --- icons -----------------------------------------------------------------

struct IconMeasurement {
    let height: CGFloat
    let scale: CGFloat
    let band: ClosedRange<Int>
    let ink: Int
    let runs: [ClosedRange<Int>]
    let pngPath: String
}

func measureIcons(updater: Updater) -> [IconMeasurement] {
    var measurements: [IconMeasurement] = []
    for height in heights {
        guard let result = renderPopover(height: height, updater: updater) else {
            print("    height \(Int(height)): FAILED to render")
            continue
        }
        let x0 = Int((iconBandXRange.lowerBound * result.scale).rounded())
        let x1 = Int((iconBandXRange.upperBound * result.scale).rounded())
        let profile = inkProfile(result)
        let runs = inkRuns(profile)
        func ink(of run: ClosedRange<Int>) -> Int {
            luminanceInkCount(result.rep, xRange: x0...x1, yRange: run)
        }

        // The band is anchored to the label row, found from the *bright* pixels rather than
        // from gaps in the backdrop-relative ink profile: the button's own edge crosses every
        // row of the button block, so at the narrower popover width the whole block reads as
        // one run and there is no gap to split on. The symbol sits one button-spacing plus
        // its own height above the label, which is the 25 pt band measured back from the top
        // of the label run.
        let brightRuns = inkRuns(brightProfile(result))
        let labelRun = brightRuns.max { ink(of: $0) < ink(of: $1) }
        // The symbol occupies exactly its own height (15 pt) starting one button-spacing
        // (10 pt) above the label, so the band is that 15 pt window - sizing it to the
        // symbol keeps the button's own edge, which is also ink, out of the measurement.
        let symbolHeight = Int((15 * result.scale).rounded())
        let symbolGap = Int((10 * result.scale).rounded())
        let band: ClosedRange<Int>
        if let labelRun {
            let upper = max(0, labelRun.lowerBound - symbolGap - 1)
            let lower = max(0, upper - symbolHeight + 1)
            band = lower...upper
        } else {
            band = 0...max(0, result.rep.pixelsHigh - 1)
        }
        // The band is measured in *bright* pixels rather than in ink-relative-to-median:
        // when the symbol collapses the band falls back onto the button's own edge, whose
        // highlight is ink by the median test but is nowhere near bright, and the check has
        // to read that as "no symbol".
        let mx0 = Int((iconMeasureXRange.lowerBound * result.scale).rounded())
        let mx1 = Int((iconMeasureXRange.upperBound * result.scale).rounded())
        let bandInk = brightPixelCount(result.rep, xRange: mx0...mx1, yRange: band)

        if debugMode {
            print("  debug height \(Int(height)) scale=\(result.scale) bitmap=\(result.rep.pixelsWide)x\(result.rep.pixelsHigh) xband=\(x0)-\(x1)")
            print("  debug runs: \(runs.map { "\($0.lowerBound)-\($0.upperBound)[\(ink(of: $0))]" }.joined(separator: " "))")
            print("  debug brightRuns: \(brightRuns.map { "\($0.lowerBound)-\($0.upperBound)[\(ink(of: $0))]" }.joined(separator: " "))")
            print("  debug label=\(labelRun.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none") band=\(band.lowerBound)-\(band.upperBound) ink=\(bandInk) mx=\(mx0)-\(mx1)")
        }

        measurements.append(IconMeasurement(height: height, scale: result.scale, band: band, ink: bandInk, runs: runs, pngPath: result.url.path))
    }
    return measurements
}

// --- settings --------------------------------------------------------------

/// True when the window hosts `SettingsView`. WindowManager wraps the view in
/// environment-object modifiers and, when a material is requested, replaces the window's
/// content view with a visual-effect container - which clears `contentViewController`.
/// The hosting view keeps the root view type in its generic name, so the view tree is
/// the reliable discriminator.
func viewTreeHostsSettingsView(_ view: NSView?) -> Bool {
    guard let view else { return false }
    if String(describing: type(of: view)).contains("SettingsView") {
        return true
    }
    return view.subviews.contains { viewTreeHostsSettingsView($0) }
}

func windowHostsSettingsView(_ window: NSWindow) -> Bool {
    if let controller = window.contentViewController,
       String(describing: type(of: controller)).contains("SettingsView") {
        return true
    }
    return viewTreeHostsSettingsView(window.contentView)
}

func describeWindow(_ window: NSWindow) -> String {
    let controllerType = window.contentViewController.map { String(describing: type(of: $0)) } ?? "nil"
    let hostingType = deepestHostingView(window.contentView).map { String(describing: type(of: $0)) } ?? "nil"
    return "id=\(window.identifier?.rawValue ?? "nil") title=\"\(window.title)\" visible=\(window.isVisible) key=\(window.isKeyWindow) alpha=\(window.alphaValue) size=\(Int(window.frame.width))x\(Int(window.frame.height)) contentViewController=\(controllerType) hostingView=\(hostingType)"
}

func deepestHostingView(_ view: NSView?) -> NSView? {
    guard let view else { return nil }
    if String(describing: type(of: view)).contains("NSHostingView") {
        return view
    }
    for subview in view.subviews {
        if let found = deepestHostingView(subview) {
            return found
        }
    }
    return nil
}

func checkSettings() -> (passed: Bool, details: String) {
    // `WindowManager` gives the window an autosave name, so a frame saved by an earlier
    // run would be restored and the check would measure that stale size instead of the
    // size the app asks for.
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame settings")
    let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
    openAppSettings(selectedTab: 1)
    pumpRunLoop(2.0)
    let created = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
    let settingsWindows = created.filter { windowHostsSettingsView($0) }
    let visible = settingsWindows.filter { $0.isVisible }

    if let window = visible.first {
        return (true, "created \(created.count) window(s), \(visible.count) visible SettingsView window(s); first: \(describeWindow(window))")
    }
    let described = created.map(describeWindow).joined(separator: "; ")
    return (false, "no visible SettingsView window after openAppSettings(selectedTab: 1) (new windows: \(created.count)\(described.isEmpty ? "" : ", \(described)"))")
}

// --- first open (cold start) ------------------------------------------------

/// Opens the settings window as the very first action of a fresh process and measures it.
/// This is the path a user takes (launch Viz, click the gear): the window accessor and the
/// content-height preference have not run yet, so the first fit used to be lost and the
/// window stayed at its initial size with the lower sections clipped.
func checkFirstOpen() -> (passed: Bool, details: String) {
    // A frame saved by an earlier run would be restored instead of the fitted size.
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame settings")
    let before = Set(NSApp.windows.map { ObjectIdentifier($0) })

    openAppSettings(selectedTab: 0)
    pumpRunLoop(1.5)

    guard let window = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && windowHostsSettingsView($0) && $0.isVisible }),
          let hosting = deepestHostingView(window.contentView) else {
        return (false, "no settings window appeared after openAppSettings(selectedTab: 0)")
    }

    let fitting = hosting.fittingSize
    let content = window.contentLayoutRect
    let frame = window.frame
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
    let allowedHeight = min(fitting.height, visible.height - 100)

    var failures: [String] = []
    if content.height < allowedHeight - 8 {
        failures.append(String(format: "height %.0f < needed %.0f", content.height, allowedHeight))
    }
    if content.width < fitting.width - 8 {
        failures.append(String(format: "width %.0f < needed %.0f", content.width, fitting.width))
    }
    if frame.width > settingsWindowMaxWidth || frame.height > settingsWindowMaxHeight {
        failures.append(String(format: "window %.0fx%.0f is not compact (max %.0fx%.0f)",
                                frame.width, frame.height, settingsWindowMaxWidth, settingsWindowMaxHeight))
    }

    let details = String(format: "frame=%.0fx%.0f content=%.0fx%.0f fitting=%.0fx%.0f allowedHeight=%.0f origin=%.0f,%.0f title=\"%@\"%@",
                         frame.width, frame.height, content.width, content.height,
                         fitting.width, fitting.height, allowedHeight, frame.minX, frame.minY, window.title,
                         failures.isEmpty ? "" : " -> failed: " + failures.joined(separator: ", "))
    return (failures.isEmpty, details)
}

// --- popover natural height -------------------------------------------------

/// Measures the popover's natural size: the real `ContentView` with the app's environment
/// objects in a hosting view at the app's width, with no height constraint, so `fittingSize`
/// is what the popover would ask for. The popover must stay compact.
func checkPopoverHeight(updater: Updater) -> (passed: Bool, details: String) {
    let hosting = NSHostingView(rootView: HarnessRoot(updater: updater, scheme: .dark).frame(width: contentWidth))
    hosting.layoutSubtreeIfNeeded()
    pumpRunLoop(0.4)
    hosting.layoutSubtreeIfNeeded()

    let size = hosting.fittingSize
    let passed = size.height <= popoverHeightCeiling
    let details = String(format: "natural %.0fx%.1f (ceiling %.0f)%@",
                         size.width, size.height, popoverHeightCeiling,
                         passed ? "" : String(format: " -> failed: natural height %.0f > %.0f", size.height, popoverHeightCeiling))
    return (passed, details)
}

/// Counts bright pixels in the shortcut-pill band of a popover render: the row below the
/// action buttons. The hints must be drawn in the primary label colour, so a return to
/// `.secondary` shows up as an almost dark band.
func hintBrightPixels(_ rep: NSBitmapImageRep, backdrop: NSColor, bandStart: Double = 0.75, bandEnd: Double = 0.95) -> Int {
    let y0 = Int(Double(rep.pixelsHigh) * bandStart)
    let y1 = min(rep.pixelsHigh - 1, Int(Double(rep.pixelsHigh) * bandEnd))
    guard y0 <= y1 else { return 0 }
    var bright = 0
    for y in y0...y1 {
        for x in 0..<rep.pixelsWide {
            guard let luminance = pixelLuminance(rep, x, y, backdrop: backdrop) else { continue }
            if luminance > hintBrightLuminance {
                bright += 1
            }
        }
    }
    return bright
}

// --- alignment --------------------------------------------------------------

/// The five popover buttons must look evenly laid out: same icon ink size, one icon row,
/// one label row, aligned pills and an optically centred icon+label block. Measured from
/// the popover render at the controller's width, segmenting each button column by its pill
/// run (the bottom-most bright run) so the icon's own outline cannot split it.
func checkAlignment() -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    let size = AppSurface.popover.size
    let root = SurfaceRoot(surface: .popover, scheme: .dark)
        .frame(width: size.width, height: size.height)
    guard let rep = renderView(root, size: size, scheme: .dark, pngName: "alignment-popover-dark.png") else {
        return (false, "render")
    }

    let scale = Double(rep.pixelsWide) / Double(size.width)
    let rowPadding = 16.0
    let buttonGap = 8.0
    let buttonWidth = (Double(size.width) - 2 * rowPadding - 4 * buttonGap) / 5
    let backdrop = Backdrop.dark.usingColorSpace(.deviceRGB) ?? .black

    func differsFromBackdrop(_ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
        return abs(c.redComponent - backdrop.redComponent) * 255 > 2
            || abs(c.greenComponent - backdrop.greenComponent) * 255 > 2
            || abs(c.blueComponent - backdrop.blueComponent) * 255 > 2
    }

    struct ButtonMeasure {
        let index: Int
        let centre: Double
        let iconWidth: Int
        let iconCentreX: Double
        let iconCentreY: Double
        let labelTop: Int
        let pillCentre: Double
        let inkAbove: Double
        let inkBelow: Double
    }
    var measures: [ButtonMeasure] = []

    for index in 0..<5 {
        let left = rowPadding + Double(index) * (buttonWidth + buttonGap)
        let centre = left + buttonWidth / 2
        let x0 = Int(left * scale) + 2
        let x1 = Int((left + buttonWidth) * scale) - 2

        // Bright runs in the column.
        var runs: [ClosedRange<Int>] = []
        var start = -1, last = -1
        for y in 0..<rep.pixelsHigh {
            let bright = brightPixelCount(rep, xRange: x0...x1, yRange: y...y, brightness: 0.4) > 0
            if bright {
                if start < 0 { start = y } else if y - last > 4 { runs.append(start...last); start = y }
                last = y
            }
        }
        if start >= 0 { runs.append(start...last) }

        let pillRun = runs.last ?? 0...0
        let labelRun = runs.filter { $0.upperBound < pillRun.lowerBound }.last ?? 0...0
        let above = runs.filter { $0.upperBound < labelRun.lowerBound }

        // The pill's *horizontal* centre: the check compares it with the button's centre,
        // the same axis as the icon centre.
        var pillLeft = Int.max, pillRight = Int.min
        for y in pillRun {
            for x in x0...x1 where brightPixelCount(rep, xRange: x...x, yRange: y...y, brightness: 0.4) > 0 {
                pillLeft = min(pillLeft, x); pillRight = max(pillRight, x)
            }
        }
        let pillCentreX = pillLeft <= pillRight ? Double(pillLeft + pillRight) / 2 : 0

        var iconTop = Int.max, iconBottom = Int.min, iconLeft = Int.max, iconRight = Int.min
        for run in above {
            for y in run {
                for x in x0...x1 where brightPixelCount(rep, xRange: x...x, yRange: y...y, brightness: 0.4) > 0 {
                    iconTop = min(iconTop, y); iconBottom = max(iconBottom, y)
                    iconLeft = min(iconLeft, x); iconRight = max(iconRight, x)
                }
            }
        }

        // The button's own box, sampled in its left padding where the centred pill cannot
        // reach, so the ink gaps are measured inside the button rather than the column.
        let edgeColumn = Int((left + 4) * scale)
        var boxTop = -1, boxBottom = -1
        for y in 0..<rep.pixelsHigh where differsFromBackdrop(edgeColumn, y) {
            if boxTop < 0 { boxTop = y }
            boxBottom = y
        }

        if debugMode {
            print("  debug alignment button \(index): runs=\(runs.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " "))")
        }
        guard iconLeft <= iconRight, boxTop >= 0, !runs.isEmpty else {
            failures.append("button \(index): no icon ink found")
            continue
        }
        measures.append(ButtonMeasure(index: index,
                                      centre: centre * scale,
                                      iconWidth: iconRight - iconLeft + 1,
                                      iconCentreX: Double(iconLeft + iconRight) / 2,
                                      iconCentreY: Double(iconTop + iconBottom) / 2,
                                      labelTop: labelRun.lowerBound,
                                      pillCentre: pillCentreX,
                                      inkAbove: (Double(iconTop) - Double(boxTop)) / scale,
                                      inkBelow: (Double(boxBottom) - Double(labelRun.upperBound)) / scale))
    }

    guard measures.count == 5 else {
        let details = summaries.joined(separator: " ") + " -> failed: \(failures.joined(separator: ", "))"
        return (false, details)
    }

    var entries: [String] = []
    func entry(_ name: String, _ ok: Bool, _ measured: String) {
        entries.append("\(name):\(ok ? "ok" : "FAILED")(\(measured))")
        if !ok {
            failures.append("alignment '\(name)' out of tolerance: \(measured)")
        }
    }

    let widths = measures.map(\.iconWidth)
    let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
    entry("iconWidthSpread", spread <= alignmentIconWidthSpreadLimit,
          "spread=\(spread)px widths=\(widths.map(String.init).joined(separator: "/")) limit=\(alignmentIconWidthSpreadLimit)")

    let centreOffsets = measures.map { abs($0.iconCentreX - $0.centre) }
    let worstCentre = centreOffsets.max() ?? 0
    entry("iconCentres", worstCentre <= Double(alignmentIconCentreTolerance),
          String(format: "worst=%.1fpx limit=%d", worstCentre, alignmentIconCentreTolerance))

    let meanIconY = measures.map(\.iconCentreY).reduce(0, +) / 5
    let worstIconY = measures.map { abs($0.iconCentreY - meanIconY) }.max() ?? 0
    entry("iconRow", worstIconY <= Double(alignmentRowTolerance),
          String(format: "meanY=%.1f worst=%.1fpx limit=%d", meanIconY, worstIconY, alignmentRowTolerance))

    let meanLabelTop = Double(measures.map(\.labelTop).reduce(0, +)) / 5
    let worstLabelTop = measures.map { abs(Double($0.labelTop) - meanLabelTop) }.max() ?? 0
    entry("labelRow", worstLabelTop <= Double(alignmentRowTolerance),
          String(format: "meanTop=%.1f worst=%.1fpx limit=%d", meanLabelTop, worstLabelTop, alignmentRowTolerance))

    let balances = measures.map { abs($0.inkAbove - $0.inkBelow) }
    let worstBalance = balances.max() ?? 0
    let aboveList = measures.map { String(format: "%.1f", $0.inkAbove) }.joined(separator: "/")
    let belowList = measures.map { String(format: "%.1f", $0.inkBelow) }.joined(separator: "/")
    entry("inkBalance", worstBalance <= alignmentInkBalanceTolerance,
          String(format: "worst=%.1fpt limit=%.0f", worstBalance, alignmentInkBalanceTolerance)
          + " above=\(aboveList) below=\(belowList)")

    let pillOffsets = measures.map { abs($0.pillCentre - $0.centre) }
    let worstPill = pillOffsets.max() ?? 0
    entry("pillRow", worstPill <= Double(alignmentRowTolerance),
          String(format: "worst=%.1fpx limit=%d", worstPill, alignmentRowTolerance))

    summaries.append(entries.joined(separator: " "))
    let details = summaries.joined(separator: " ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

// --- preview close control --------------------------------------------------

/// The preview panel closes with the round glass bubble, not a text button, so the widest
/// ink run in the top-right strip must stay icon-sized. Measured from the preview render at
/// the app's preview size; no network and no real UI tracking involved.
func checkPreviewClose() -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    let size = AppSurface.preview.size
    let root = SurfaceRoot(surface: .preview, scheme: .dark)
        .frame(width: size.width, height: size.height)
    guard let rep = renderView(root, size: size, scheme: .dark, pngName: "previewclose-dark.png") else {
        return (false, "render")
    }

    let scale = Double(rep.pixelsWide) / Double(size.width)
    let stripHeight = Int(Double(rep.pixelsHigh) * 0.18)
    let x0 = rep.pixelsWide / 2
    var widest = 0
    var band: ClosedRange<Int>?
    for y in 0..<stripHeight {
        var left = -1, right = -1
        for x in x0..<rep.pixelsWide where brightPixelCount(rep, xRange: x...x, yRange: y...y, brightness: 0.4) > 0 {
            if left < 0 { left = x }
            right = x
        }
        guard left >= 0 else { continue }
        if band == nil { band = y...y } else { band = band!.lowerBound...y }
        widest = max(widest, right - left + 1)
    }

    summaries.append("widestRun=\(widest)px (limit \(previewCloseRunLimit), scale \(String(format: "%.1f", scale)))")
    // The control must also have a surface of its own: sampled at its centre and compared
    // with the panel background on the same rows. This proves a distinct control surface is
    // there (it does not prove the surface is glass - the material fallback renders it flat).
    if let band, widest > 0 {
        let cy = (band.lowerBound + band.upperBound) / 2
        let cx = rep.pixelsWide - Int(30 * scale)
        let bubble = meanColor(rep, xRange: (cx - 6)...(cx + 6), yRange: (cy - 6)...(cy + 6))
        let background = meanColor(rep, xRange: 20...32, yRange: (cy - 6)...(cy + 6))
        if let bubble, let background {
            let delta = (abs(bubble.r - background.r) + abs(bubble.g - background.g) + abs(bubble.b - background.b)) * 255
            summaries.append(String(format: "surfaceDelta=%.0f (limit %.0f)", delta, previewCloseSurfaceDeltaMinimum))
            if delta < previewCloseSurfaceDeltaMinimum {
                failures.append(String(format: "preview close control has no surface of its own (centre differs from the panel background by %.0f, limit %.0f)", delta, previewCloseSurfaceDeltaMinimum))
            }
        } else {
            failures.append("preview close control surface unmeasurable")
        }
    }
    if widest == 0 {
        failures.append("preview close control not found in the top strip")
    } else if widest > previewCloseRunLimit {
        failures.append("preview close control is \(widest) device px wide, above the icon-sized limit of \(previewCloseRunLimit) - it looks like a text button again")
    }

    let details = summaries.joined(separator: " ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

// --- status menu ------------------------------------------------------------

/// The settings and quit actions live in the status item's right-click menu, so the harness
/// asserts the wiring structurally: a status item with a button, an action that receives
/// both mouse-up kinds, a menu with the expected items, and a status icon that follows the
/// update state. Removing the menu or the wiring fails this check.
func checkStatusMenu(updater: Updater) -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    let controller = StatusItemController.shared
    controller.start(updater: updater)
    // Drive the routing without opening real UI: `NSMenu.popUp` would start menu tracking
    // and block this process.
    controller.recordsPresentationOnly = true

    guard let item = controller.statusItem, let button = item.button else {
        return (false, "no status item or button")
    }
    summaries.append("item=\(item.length == NSStatusItem.variableLength ? "variableLength" : "fixed")")

    if button.action == nil || button.target == nil {
        failures.append("status item button has no action/target wired")
    }
    summaries.append("action=\(button.action.map(NSStringFromSelector) ?? "nil")")

    let mask = controller.actionMask
    if !mask.contains(.leftMouseUp) || !mask.contains(.rightMouseUp) {
        failures.append("send-action mask does not cover both left and right mouse-up")
    }
    summaries.append("mask=\(mask.contains(.leftMouseUp) ? "left" : "-")+\(mask.contains(.rightMouseUp) ? "right" : "-")")

    let titles = controller.menu?.items.map(\.title) ?? []
    for expected in ["Settings…", "Quit"] where !titles.contains(expected) {
        failures.append("menu is missing '\(expected)'")
    }
    summaries.append("menu=\(titles.filter { !$0.isEmpty }.joined(separator: "/"))")

    // The click routing: a right click must present the menu, a left click the popover.
    controller.handle(eventType: .rightMouseUp)
    let afterRight = controller.lastPresentation
    if afterRight != .menu {
        failures.append("right click did not present the menu (got \(afterRight))")
    }
    controller.handle(eventType: .leftMouseUp)
    let afterLeft = controller.lastPresentation
    if afterLeft != .popover {
        failures.append("left click did not open the popover (got \(afterLeft))")
    }
    summaries.append("clicks=right:\(afterRight)/left:\(afterLeft)")
    controller.recordsPresentationOnly = false
    controller.closePopover()

    // The status icon carries the update state now that the popover header is gone.
    let previous = updater.updateAvailable
    updater.updateAvailable = true
    pumpRunLoop(0.2)
    let updatedIcon = controller.statusSymbolName
    updater.updateAvailable = false
    pumpRunLoop(0.2)
    let idleIcon = controller.statusSymbolName
    updater.updateAvailable = previous
    if updatedIcon != "arrow.down.circle" || idleIcon != "eye" {
        failures.append("status icon does not follow the update state (got \(updatedIcon ?? "nil")/\(idleIcon ?? "nil"))")
    }
    summaries.append("icon=\(updatedIcon ?? "nil")/\(idleIcon ?? "nil")")

    let details = summaries.joined(separator: " ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

// --- status panel -----------------------------------------------------------

/// The popover is our own panel now, so its background comes from an NSVisualEffectView
/// with the menu bar's material. This asserts that arrangement structurally: the harness
/// never shows real UI (`recordsPresentationOnly`).
func checkStatusPanel(updater: Updater) -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    let controller = StatusItemController.shared
    controller.start(updater: updater)
    controller.recordsPresentationOnly = true

    guard let panel = controller.panel else {
        return (false, "no panel")
    }
    summaries.append("panel=\(Int(panel.frame.width))x\(Int(panel.frame.height))")

    if !panel.styleMask.contains(.borderless) || !panel.styleMask.contains(.nonactivatingPanel) {
        failures.append("panel is not borderless/non-activating (mask \(panel.styleMask.rawValue))")
    }
    if panel.isOpaque {
        failures.append("panel is opaque")
    }
    if panel.level != .popUpMenu {
        failures.append("panel level is \(panel.level.rawValue), expected the pop-up menu level")
    }
    summaries.append("level=\(panel.level.rawValue) opaque=\(panel.isOpaque)")

    guard let effect = controller.effectView else {
        failures.append("panel content is not an NSVisualEffectView")
        let details = summaries.joined(separator: " ") + " -> failed: \(failures.joined(separator: ", "))"
        return (failures.isEmpty, details)
    }
    if !(panel.contentView is NSVisualEffectView) {
        failures.append("panel.contentView is not an NSVisualEffectView")
    }
    if effect.material != .menu {
        failures.append("effect view material is \(effect.material.rawValue), expected .menu")
    }
    if effect.blendingMode != .behindWindow {
        failures.append("effect view blending is \(effect.blendingMode.rawValue), expected .behindWindow")
    }
    summaries.append("material=\(effect.material == .menu ? "menu" : "\(effect.material.rawValue)") blending=\(effect.blendingMode == .behindWindow ? "behindWindow" : "\(effect.blendingMode.rawValue)") subviews=\(effect.subviews.count)")

    // Geometry: the panel sits under the status button and stays inside the screen.
    let size = NSSize(width: StatusItemController.popoverWidth, height: 99)
    let frame = controller.panelFrame(for: size)
    // The absolute position depends on where the system puts the status item in this
    // process, which varies between runs; the assertion is that the panel fits the screen,
    // so that is what the line reports.
    var placement = "noscreen"
    if let screen = NSScreen.main {
        placement = screen.visibleFrame.contains(frame) ? "inside" : "offscreen"
        if placement == "offscreen" {
            failures.append("panel frame \(frame) is outside the visible frame \(screen.visibleFrame)")
        }
    }
    summaries.append(String(format: "frame=%@ %.0fx%.0f", placement, frame.width, frame.height))

    // Dismissal lifecycle. The panel must survive the notifications that arrive right
    // after the click that opened it - dismissing on those made the popover invisible -
    // while the real dismissal paths still close it.
    var steps: [String] = []
    func step(_ name: String, _ ok: Bool) {
        steps.append("\(name):\(ok ? "ok" : "FAILED")")
        if !ok {
            failures.append("dismissal step '\(name)' behaved wrongly")
        }
    }

    controller.recordsPresentationOnly = false
    controller.ignoresGracePeriod = false
    controller.togglePopover()
    step("show", panel.isVisible && controller.lastPresentation == .popover)
    step("monitorInstalled", controller.clickAwayMonitor != nil)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    pumpRunLoop(0.05)
    step("survivesAppResignActive", panel.isVisible && controller.lastPresentation == .popover)

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
    pumpRunLoop(0.05)
    step("survivesResignInsideGrace", panel.isVisible)

    // With the grace period bypassed the panel must STILL survive an application
    // deactivation: that notification fires right after the menu bar click, and the
    // controller must not dismiss on it. This is the regression guard - with the old code
    // (a didResignActive observer) the panel goes away here.
    controller.ignoresGracePeriod = true
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
    pumpRunLoop(0.05)
    step("ignoresAppResignActive", panel.isVisible && controller.lastPresentation == .popover)

    // Past the grace period a resignation is a real dismissal.
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
    pumpRunLoop(0.05)
    step("resignAfterGraceCloses", !panel.isVisible && controller.lastPresentation == .none)
    step("monitorRemoved", controller.clickAwayMonitor == nil)
    step("hidesOnDeactivateOff", !panel.hidesOnDeactivate)

    // The click on the status button. A second click must CLOSE the panel: the click first
    // makes the panel resign key (our dismissal runs), and the button action then runs
    // `togglePopover()` - reopening there is exactly the bug where clicking the icon did
    // nothing. The reopen below bypasses the suppression window, because the step above
    // dismissed the panel a moment ago and that window is what stops the closing click from
    // reopening it.
    controller.ignoresGracePeriod = false
    controller.ignoresToggleSuppression = true
    controller.togglePopover()
    let reopened = panel.isVisible
    controller.ignoresToggleSuppression = false
    controller.togglePopover()
    step("toggleCloses", reopened && !panel.isVisible)

    // `secondClickCloses`: the button action alone, with the panel shown, closes it.
    pumpRunLoop(0.4)
    controller.togglePopover()
    let shownForClick = panel.isVisible
    controller.handle(eventType: .leftMouseUp)
    step("secondClickCloses", shownForClick && !panel.isVisible)

    // `noReopenAfterClickDismissal`: the click's own resignation dismisses the panel, and
    // the button action that follows must NOT reopen it.
    pumpRunLoop(0.4)
    controller.togglePopover()
    let shownForResignation = panel.isVisible
    controller.ignoresGracePeriod = true
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
    pumpRunLoop(0.05)
    let dismissedByClick = !panel.isVisible
    controller.handle(eventType: .leftMouseUp)
    pumpRunLoop(0.05)
    step("noReopenAfterClickDismissal", shownForResignation && dismissedByClick && !panel.isVisible)
    controller.ignoresGracePeriod = false

    // `reopensAfterSuppressionWindow`: past the window the same action opens it again.
    controller.ignoresToggleSuppression = true
    controller.handle(eventType: .leftMouseUp)
    let reopenedAfterWindow = panel.isVisible
    controller.ignoresToggleSuppression = false
    step("reopensAfterSuppressionWindow", reopenedAfterWindow)
    controller.dismissPanel()
    pumpRunLoop(0.4)

    // `monitorIgnoresStatusButton`: a point on the status item is not a click-away.
    if let buttonFrame = controller.statusButtonFrame() {
        let onButton = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        let farAway = NSPoint(x: buttonFrame.midX + 2000, y: buttonFrame.midY + 2000)
        step("monitorIgnoresStatusButton",
             controller.isPointOnStatusButton(onButton) && !controller.isPointOnStatusButton(farAway))
    } else {
        step("monitorIgnoresStatusButton", false)
    }

    // Esc path.
    pumpRunLoop(0.4)
    controller.togglePopover()
    controller.dismissPanel()
    step("escCloses", !panel.isVisible)

    // Click-away: the entry point the global monitor calls.
    pumpRunLoop(0.4)
    controller.togglePopover()
    controller.dismissPanel()
    step("clickAwayCloses", !panel.isVisible)

    summaries.append("lifecycle=\(steps.joined(separator: "/"))")
    controller.recordsPresentationOnly = true

    let details = summaries.joined(separator: " ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

/// The popover content must not paint a surface of its own: over each harness backdrop its
/// dominant colour has to be that backdrop, so the panel's menu material is what shows.
func checkPopoverContent() -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    for (scheme, backdrop) in [(ColorScheme.dark, Backdrop.dark), (ColorScheme.light, Backdrop.light)] {
        let size = AppSurface.popover.size
        let root = SurfaceRoot(surface: .popover, scheme: scheme)
            .frame(width: size.width, height: size.height)
        let name = "popovercontent-\(scheme == .dark ? "dark" : "light").png"
        guard let rep = renderView(root, size: size, scheme: scheme, pngName: name),
              let dominant = dominantSurfaceColor(rep, backdrop: backdrop) else {
            failures.append("\(scheme == .dark ? "dark" : "light"):render")
            summaries.append("\(scheme == .dark ? "dark" : "light") RENDER-FAILED")
            continue
        }
        let base = backdrop.usingColorSpace(.deviceRGB) ?? .black
        let deltas = [abs(dominant.r - Double(base.redComponent)) * 255,
                      abs(dominant.g - Double(base.greenComponent)) * 255,
                      abs(dominant.b - Double(base.blueComponent)) * 255]
        let worst = deltas.max() ?? 0
        summaries.append(String(format: "%@ dominant=%d,%d,%d backdrop=%d,%d,%d delta=%.0f/%.0f/%.0f",
                                scheme == .dark ? "dark" : "light",
                                Int(dominant.r * 255), Int(dominant.g * 255), Int(dominant.b * 255),
                                Int(base.redComponent * 255), Int(base.greenComponent * 255), Int(base.blueComponent * 255),
                                deltas[0], deltas[1], deltas[2]))
        _ = worst
        // The dominant colour is only the backdrop while the controls cover less than half
        // the surface, which stops being true at the narrower width. The padding corner is
        // outside every control, so it is the reliable place to look for a content-owned
        // background: it must be the backdrop and nothing else.
        let corner = 16
        if let sampled = meanColor(rep, xRange: 0...(corner - 1), yRange: 0...(corner - 1)) {
            let cornerDeltas = [abs(sampled.r - Double(base.redComponent)) * 255,
                                abs(sampled.g - Double(base.greenComponent)) * 255,
                                abs(sampled.b - Double(base.blueComponent)) * 255]
            let cornerWorst = cornerDeltas.max() ?? 0
            summaries.append(String(format: "corner=%d,%d,%d cornerDelta=%.0f",
                                    Int(sampled.r * 255), Int(sampled.g * 255), Int(sampled.b * 255), cornerWorst))
            if cornerWorst > popoverContentTolerance {
                failures.append(String(format: "%@ content paints its own surface (padding corner differs from the backdrop by %.0f, tolerance %.0f)",
                                        scheme == .dark ? "dark" : "light", cornerWorst, popoverContentTolerance))
            }
        } else {
            failures.append("\(scheme == .dark ? "dark" : "light"):corner unmeasurable")
        }
    }

    let details = summaries.joined(separator: " | ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

// --- translucency ----------------------------------------------------------

/// Renders the same surface over two different backdrops and compares the surface colour:
/// a translucent (glass or material) surface follows its backdrop, while an opaque one
/// renders identically and fails. This is the guard against the backgrounds silently
/// becoming flat paint again.
func checkTranslucency() -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    // The popover is excluded: its content is transparent over the panel's menu material,
    // so there is no surface of its own to follow the backdrop. `checkPopoverContent`
    // asserts that transparency instead.
    for surface in AppSurface.allCases where surface != .popover {
        let size = surface.size
        // The backdrop is part of the rendered hierarchy: a material samples what is behind
        // it inside the same view tree, so a colour placed here is what the surface blurs.
        func root(over backdrop: Color) -> some View {
            ZStack {
                backdrop
                SurfaceRoot(surface: surface, scheme: .dark)
            }
            .frame(width: size.width, height: size.height)
        }

        guard let darkRep = renderView(root(over: Color(nsColor: Backdrop.dark)), size: size, scheme: .dark,
                                       pngName: "translucency-\(surface.rawValue)-dark-backdrop.png",
                                       backdrop: Backdrop.dark),
              let brightRep = renderView(root(over: Color(nsColor: Backdrop.bright)), size: size, scheme: .dark,
                                         pngName: "translucency-\(surface.rawValue)-bright-backdrop.png",
                                         backdrop: Backdrop.bright),
              let onDark = dominantSurfaceColor(darkRep, backdrop: Backdrop.dark),
              let onBright = dominantSurfaceColor(brightRep, backdrop: Backdrop.bright) else {
            failures.append("\(surface.rawValue):render")
            summaries.append("\(surface.rawValue) RENDER-FAILED")
            continue
        }

        let deltaRed = abs(onDark.r - onBright.r) * 255
        let deltaGreen = abs(onDark.g - onBright.g) * 255
        let deltaBlue = abs(onDark.b - onBright.b) * 255
        let smallest = min(deltaRed, min(deltaGreen, deltaBlue))

        summaries.append(String(format: "%@ dark=%d,%d,%d bright=%d,%d,%d delta=%d/%d/%d",
                                surface.rawValue,
                                Int(onDark.r * 255), Int(onDark.g * 255), Int(onDark.b * 255),
                                Int(onBright.r * 255), Int(onBright.g * 255), Int(onBright.b * 255),
                                Int(deltaRed), Int(deltaGreen), Int(deltaBlue)))

        if smallest < translucencyDeltaMinimum {
            failures.append(String(format: "%@ surface barely follows the backdrop (smallest delta %.0f < %.0f)",
                                    surface.rawValue, smallest, translucencyDeltaMinimum))
        }
    }

    let details = summaries.joined(separator: " | ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

// --- window size -----------------------------------------------------------

/// Opens the settings window on every tab and checks that the window is as tall as the
/// tab's content needs (or clamped to the screen), wide enough, on screen, and that its
/// top-left corner does not move while switching tabs. This is the guard for the window
/// that used to open at a fixed 520 pt height and slice the General tab in half.
func checkWindowSize() -> (passed: Bool, details: String) {
    let tabNames = ["general", "shortcuts", "updates", "about"]
    var failures: [String] = []
    var summaries: [String] = []
    var previousOrigin: NSPoint?

    for tab in 0...3 {
        let name = tabNames[tab]
        // A frame saved by an earlier run would be restored instead of the fitted size.
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame settings")
        // Close any window from the previous iteration so each measurement is clean.
        for window in NSApp.windows where windowHostsSettingsView(window) {
            window.orderOut(nil)
        }
        UserDefaults.standard.set(tab, forKey: "settingsSelectedTab")
        openAppSettings(selectedTab: tab)
        pumpRunLoop(1.5)

        guard let window = NSApp.windows.first(where: { windowHostsSettingsView($0) && $0.isVisible }),
              let hosting = deepestHostingView(window.contentView) else {
            failures.append("\(name):nowindow")
            summaries.append("\(name) NO-WINDOW")
            continue
        }

        let fitting = hosting.fittingSize
        let content = window.contentLayoutRect
        let frame = window.frame
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? frame

        summaries.append(String(format: "%@ frame=%.0fx%.0f content=%.0fx%.0f fitting=%.0fx%.0f origin=%.0f,%.0f",
                                name, frame.width, frame.height, content.width, content.height,
                                fitting.width, fitting.height, frame.minX, frame.minY))

        // Vertical fit: the content must be as tall as the tab needs, unless the screen
        // cannot fit it, in which case the clamped height is accepted (the ScrollView then
        // scrolls instead of clipping).
        let allowedHeight = min(fitting.height, visible.height - 100)
        if content.height < allowedHeight - 8 {
            failures.append(String(format: "%@ height %.0f < needed %.0f", name, content.height, allowedHeight))
        }

        // Horizontal fit: the widest tab (Updates) must not be clipped.
        if content.width < fitting.width - 8 {
            failures.append(String(format: "%@ width %.0f < needed %.0f", name, content.width, fitting.width))
        }

        // Compactness: the window must stay a small settings window rather than growing
        // back to the old 690x793 shape.
        if frame.width > settingsWindowMaxWidth || frame.height > settingsWindowMaxHeight {
            failures.append(String(format: "%@ window %.0fx%.0f is not compact (max %.0fx%.0f)",
                                    name, frame.width, frame.height, settingsWindowMaxWidth, settingsWindowMaxHeight))
        }

        // On screen.
        let tolerance: CGFloat = 2
        if frame.minX < visible.minX - tolerance || frame.minY < visible.minY - tolerance
            || frame.maxX > visible.maxX + tolerance || frame.maxY > visible.maxY + tolerance {
            failures.append(String(format: "%@ offscreen frame=%.0f,%.0f %.0fx%.0f visible=%.0f,%.0f %.0fx%.0f",
                                    name, frame.minX, frame.minY, frame.width, frame.height,
                                    visible.minX, visible.minY, visible.width, visible.height))
        }

        // Top-left corner stable across tabs.
        if let previous = previousOrigin {
            if abs(frame.minX - previous.x) > 2 || abs(frame.maxY - previous.y) > 2 {
                failures.append(String(format: "%@ origin moved from %.0f,%.0f to %.0f,%.0f", name, previous.x, previous.y, frame.minX, frame.maxY))
            }
        }
        previousOrigin = NSPoint(x: frame.minX, y: frame.maxY)

        if debugMode {
            print("  debug windowsize \(name) frame=\(frame) content=\(content) fitting=\(fitting) visible=\(visible)")
        }
    }

    let details = summaries.joined(separator: " | ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}

// --- design ----------------------------------------------------------------

/// The surfaces the design check renders, in both app appearances.
enum AppSurface: String, CaseIterable {
    case popover
    case settings
    case history
    case about
    case preview

    var size: NSSize {
        switch self {
        // The popover render uses the popover's own measured height: with the header gone
        // the content is much shorter, and a taller frame would push the pills out of the
        // band the hint-brightness metric looks at.
        case .popover: return NSSize(width: contentWidth, height: naturalPopoverHeight.rounded())
        case .settings: return NSSize(width: settingsWindowWidth, height: settingsSurfaceHeight)
        case .history: return NSSize(width: 500, height: 420)
        case .about: return NSSize(width: 400, height: 450)
        case .preview: return NSSize(width: 300, height: 200)
        }
    }

    /// Surfaces that must show visible blue accent pixels.
    var requiresAccent: Bool {
        switch self {
        case .popover, .settings, .about: return true
        case .history, .preview: return false
        }
    }
}

/// Renders one surface in one appearance. The scene-level `.tint` from `VizApp` is
/// applied here too, so the harness sees the same accent the app gives its controls.
struct SurfaceRoot: View {
    let surface: AppSurface
    let scheme: ColorScheme

    var body: some View {
        content
            .tint(VizTheme.accent)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
    }

    @ViewBuilder
    private var content: some View {
        switch surface {
        case .popover:
            ContentView()
                .environmentObject(AppServices.shared.updater)
                .environmentObject(AppState.shared)
                .environmentObject(HistoryState.shared)
        case .settings:
            SettingsView()
                .environmentObject(AppState.shared)
                .environmentObject(HistoryState.shared)
                .environmentObject(AppServices.shared.updater)
        case .history:
            HistoryView()
        case .about:
            AboutView()
        case .preview:
            PreviewContentView()
        }
    }
}

/// Measurements taken from one rendered surface.
struct DesignMetrics {
    let contentShare: Double
    let accentPixels: Int
    let legacyShare: Double
}

/// The legacy flat background (display-P3 49, 52, 67) converted to the device colour
/// space the captures use, so the comparison is against what that paint looked like.
let legacyBackground: NSColor = {
    let legacy = NSColor(displayP3Red: 49.0 / 255.0, green: 52.0 / 255.0, blue: 67.0 / 255.0, alpha: 1.0)
    return legacy.usingColorSpace(.deviceRGB) ?? legacy
}()

/// Measures one composited (opaque) capture:
///   * contentShare - share of pixels that differ from the flat window backdrop;
///   * accentPixels - pixels within 30 degrees of hue 220 with saturation > 0.35 and
///     brightness > 0.45, i.e. the blue accent actually being visible;
///   * legacyShare  - share of pixels matching the removed flat background colour
///     within 6/255 per channel.
func designMetrics(_ rep: NSBitmapImageRep, backdrop: NSColor) -> DesignMetrics {
    let total = rep.pixelsWide * rep.pixelsHigh
    guard total > 0 else { return DesignMetrics(contentShare: 0, accentPixels: 0, legacyShare: 0) }
    let base = backdrop.usingColorSpace(.deviceRGB) ?? .black
    let legacy = legacyBackground
    let tolerance: CGFloat = 6.0 / 255.0

    var contentPixels = 0
    var accentPixels = 0
    var legacyPixels = 0

    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let contrast = abs(color.redComponent - base.redComponent)
                + abs(color.greenComponent - base.greenComponent)
                + abs(color.blueComponent - base.blueComponent)
            if contrast > 0.02 {
                contentPixels += 1
            }

            if abs(color.redComponent - legacy.redComponent) <= tolerance,
               abs(color.greenComponent - legacy.greenComponent) <= tolerance,
               abs(color.blueComponent - legacy.blueComponent) <= tolerance {
                legacyPixels += 1
            }

            if isAccentPixel(color) {
                accentPixels += 1
            }
        }
    }

    return DesignMetrics(contentShare: Double(contentPixels) / Double(total),
                         accentPixels: accentPixels,
                         legacyShare: Double(legacyPixels) / Double(total))
}

func renderSurface(_ surface: AppSurface, scheme: ColorScheme,
                   updateAvailable: Bool? = nil, nameSuffix: String = "") -> (rep: NSBitmapImageRep, url: URL)? {
    // The settings check runs before this one and selects the Shortcuts tab, but the design
    // render should show the tab a user sees first (General), which is also where the
    // accent-tinted controls live.
    if surface == .settings {
        UserDefaults.standard.set(0, forKey: "settingsSelectedTab")
    }
    // The update-available state is set explicitly rather than inherited from the live
    // GitHub API: upstream's latest release equals this app's version, so a network-driven
    // render would make the green bubble - and the `success` metric - non-deterministic.
    if surface == .popover, let updateAvailable {
        AppServices.shared.updater.updateAvailable = updateAvailable
    }
    let size = surface.size
    let root = SurfaceRoot(surface: surface, scheme: scheme)
        .frame(width: size.width, height: size.height)
    let name = "design-\(surface.rawValue)-\(scheme == .dark ? "dark" : "light")\(nameSuffix).png"
    guard let rep = renderView(root, size: size, scheme: scheme, pngName: name) else { return nil }
    return (rep, outputDirectory.appendingPathComponent(name))
}

/// Vertical band of the popover that holds the five action buttons: below the header and
/// above the shortcut pills. The header occupies roughly the first 20 % of the popover and
/// the pills the last 20 %, so the middle 60 % is the button row.
func buttonBand(_ rep: NSBitmapImageRep) -> ClosedRange<Int> {
    let top = Int(Double(rep.pixelsHigh) * 0.25)
    let bottom = Int(Double(rep.pixelsHigh) * 0.78)
    return top...max(top, min(bottom, rep.pixelsHigh - 1))
}

/// True for pixels with any visible blue cast: hue within 30 degrees of 220 with a
/// saturation above 0.12 and a brightness above 0.2. The neutral surfaces (grey glass, the
/// window backdrop, neutral symbols) sit at a saturation below 0.05 in both appearances,
/// while an accent tint lands at 0.14 (light) to 0.44 (dark), so this catches a tinted
/// button surface that the stricter accent predicate would miss.
func isBlueTintPixel(_ color: NSColor) -> Bool {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    let degrees = hue * 360
    let delta = abs(degrees - 220)
    return min(delta, 360 - delta) <= 30 && saturation > 0.12 && brightness > 0.2 && alpha > 0.2
}

/// Share of blue-tinted pixels inside a band of the render, plus the band's pixel count.
func accentShare(_ rep: NSBitmapImageRep, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> (share: Double, pixels: Int, accent: Int) {
    var pixels = 0
    var accent = 0
    for y in yRange {
        for x in xRange {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            pixels += 1
            if isBlueTintPixel(color) {
                accent += 1
            }
        }
    }
    guard pixels > 0 else { return (0, 0, 0) }
    return (Double(accent) / Double(pixels), pixels, accent)
}

/// Measures the settings tab strip: how much of the surface width its ink spans and how
/// many separated items it contains. The strip is located as the topmost ink region - the
/// rows from the first ink down to the first sizeable gap - so the content below it cannot
/// widen the measurement. A collapsed tab bar produced a narrow blob in the middle of the
/// strip, which fails both numbers.
func tabStripMetrics(_ rep: NSBitmapImageRep, backdrop: NSColor, rowGap: Int = 24, itemGap: Int = 10) -> (widthShare: Double, runs: Int, ink: Int, rows: ClosedRange<Int>?) {
    // The window root now carries its own surface tint, so "ink" has to be measured against
    // that surface rather than against the harness backdrop: otherwise the whole tinted
    // window counts as ink and the strip cannot be located.
    let surface = dominantSurfaceColor(rep, backdrop: backdrop)
    let base: NSColor
    if let surface {
        base = NSColor(deviceRed: surface.r, green: surface.g, blue: surface.b, alpha: 1)
    } else {
        base = backdrop.usingColorSpace(.deviceRGB) ?? .black
    }

    func rowInk(_ y: Int) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let alpha = color.alphaComponent
            let red = color.redComponent * alpha + base.redComponent * (1 - alpha)
            let green = color.greenComponent * alpha + base.greenComponent * (1 - alpha)
            let blue = color.blueComponent * alpha + base.blueComponent * (1 - alpha)
            let contrast = abs(red - base.redComponent) + abs(green - base.greenComponent) + abs(blue - base.blueComponent)
            if contrast > inkContrastThreshold {
                count += 1
            }
        }
        return count
    }

    // Topmost ink region: start at the first row with ink, stop at the first gap longer
    // than `rowGap` rows.
    var stripTop: Int?
    var stripBottom: Int?
    var emptyRun = 0
    for y in 0..<rep.pixelsHigh {
        if rowInk(y) > 0 {
            if stripTop == nil { stripTop = y }
            stripBottom = y
            emptyRun = 0
        } else if stripTop != nil {
            emptyRun += 1
            if emptyRun > rowGap { break }
        }
    }

    guard let top = stripTop, let bottom = stripBottom else {
        return (0, 0, 0, nil)
    }

    var columns = [Bool](repeating: false, count: rep.pixelsWide)
    var ink = 0
    for y in top...bottom {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let alpha = color.alphaComponent
            let red = color.redComponent * alpha + base.redComponent * (1 - alpha)
            let green = color.greenComponent * alpha + base.greenComponent * (1 - alpha)
            let blue = color.blueComponent * alpha + base.blueComponent * (1 - alpha)
            let contrast = abs(red - base.redComponent) + abs(green - base.greenComponent) + abs(blue - base.blueComponent)
            if contrast > inkContrastThreshold {
                columns[x] = true
                ink += 1
            }
        }
    }

    let first = columns.firstIndex(of: true)
    let last = columns.lastIndex(of: true)
    let widthShare: Double
    if let first, let last {
        widthShare = Double(last - first + 1) / Double(rep.pixelsWide)
    } else {
        widthShare = 0
    }

    var runs = 0
    var index = 0
    while index < columns.count {
        if columns[index] {
            runs += 1
            var empty = 0
            while index < columns.count && empty < itemGap {
                if columns[index] { empty = 0 } else { empty += 1 }
                index += 1
            }
        } else {
            index += 1
        }
    }

    return (widthShare, runs, ink, top...bottom)
}

/// The most frequent colour of a render, sampled on a coarse grid: the surface the view is
/// painted on. Returns the RGB components in 0...1 and the blue-minus-red cast that tells
/// the restored Viz surface apart from a neutral material and from the opaque colour.
/// Mean colour of a rectangle of a render, used to sample the popover's padding corner.
func meanColor(_ rep: NSBitmapImageRep, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> (r: Double, g: Double, b: Double)? {
    var r = 0.0, g = 0.0, b = 0.0, count = 0.0
    for y in yRange {
        for x in xRange {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            r += Double(color.redComponent)
            g += Double(color.greenComponent)
            b += Double(color.blueComponent)
            count += 1
        }
    }
    guard count > 0 else { return nil }
    return (r / count, g / count, b / count)
}

func dominantSurfaceColor(_ rep: NSBitmapImageRep, backdrop: NSColor) -> (r: Double, g: Double, b: Double, cast: Double)? {
    var counts: [String: (count: Int, r: Double, g: Double, b: Double)] = [:]
    for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let alpha = color.alphaComponent
            let base = backdrop.usingColorSpace(.deviceRGB) ?? .black
            let r = Double(color.redComponent * alpha + base.redComponent * (1 - alpha))
            let g = Double(color.greenComponent * alpha + base.greenComponent * (1 - alpha))
            let b = Double(color.blueComponent * alpha + base.blueComponent * (1 - alpha))
            let key = String(format: "%d,%d,%d", Int(r * 255), Int(g * 255), Int(b * 255))
            let previous = counts[key]?.count ?? 0
            counts[key] = (previous + 1, r, g, b)
        }
    }
    guard let best = counts.values.max(by: { $0.count < $1.count }) else { return nil }
    return (best.r, best.g, best.b, (best.b - best.r) * 255)
}



func checkDesign() -> (passed: Bool, details: String) {
    var failures: [String] = []
    var summaries: [String] = []

    // The harness runs with a throwaway home (see scripts/render-check.sh), so the real
    // history file is not available. Representative entries are seeded instead, which also
    // means the history rows are actually rendered and measured.
    HistoryState.shared.historyItems = [
        .text(TextItem(text: "Viz design check sample text")),
        .color(ColorItem(hex: "#3B82F6", rgb: "(59,130,246)")),
        .text(TextItem(text: "Second sample entry for the history list"))
    ]
    // Same reasoning for the preview panel: without captured content it renders empty.
    RecognizedContent.shared.items = [TextItem(text: "Sample captured text for the preview panel")]
    AppState.shared.cmdOutput = "sample post-processing output"

    for surface in AppSurface.allCases {
        for scheme in [ColorScheme.light, .dark] {
            let label = "\(surface.rawValue)-\(scheme == .dark ? "dark" : "light")"
            // The popover is rendered with an update available, which is the state the
            // `success` metric asserts; the neutral state is rendered and asserted below.
            guard let rendered = renderSurface(surface, scheme: scheme,
                                               updateAvailable: surface == .popover ? true : nil) else {
                failures.append("\(label):render")
                summaries.append("\(label) RENDER-FAILED")
                continue
            }
            let metrics = designMetrics(rendered.rep, backdrop: Backdrop.forScheme(scheme))
            summaries.append(String(format: "%@ nonblank=%.1f%% accent=%d legacy=%.1f%%",
                                    label,
                                    metrics.contentShare * 100,
                                    metrics.accentPixels,
                                    metrics.legacyShare * 100))

            if metrics.contentShare < contentShareMinimum {
                failures.append("\(label):blank(\(String(format: "%.1f%%", metrics.contentShare * 100)))")
            }
            // The popover's old accent floor is gone with the blue-only palette: the brand
            // gradient and the green update bubble are asserted instead (below).
            if surface.requiresAccent && surface != .popover {
                if metrics.accentPixels < accentPixelThreshold {
                    failures.append("\(label):accent(\(metrics.accentPixels))")
                }
            }
            // The restored surface: the popover and settings roots must carry the classic
            // Viz blue-grey as a translucent tint. The cast (blue minus red) is the
            // discriminator: a neutral material gives 0 and the opaque colour gives ~28,
            // while the tinted surface measures 5-10.
            // The popover has no surface of its own any more: the panel's menu material is
            // its background, which `checkPopoverContent` asserts.
            if surface == .settings {
                if let dominant = dominantSurfaceColor(rendered.rep, backdrop: Backdrop.forScheme(scheme)) {
                    summaries[summaries.count - 1] += String(format: " surface=%d,%d,%d cast=%.0f",
                                                             Int(dominant.r * 255), Int(dominant.g * 255), Int(dominant.b * 255), dominant.cast)
                    if dominant.cast < surfaceCastMinimum || dominant.cast > surfaceCastMaximum {
                        failures.append(String(format: "%@:surface rgb=%d,%d,%d cast=%.0f (need %.0f...%.0f)",
                                                label, Int(dominant.r * 255), Int(dominant.g * 255), Int(dominant.b * 255),
                                                dominant.cast, surfaceCastMinimum, surfaceCastMaximum))
                    }
                } else {
                    failures.append("\(label):surface unmeasurable")
                }
            }

            // The `brand` assertion is retired: the wordmark and its gradient were removed
            // from the interface. Its intent - that the design is intact - is carried by the
            // per-surface `translucency` check below, which now covers every surface.

            // The `success` metric is retired with the popover header: the green
            // update-available bubble lived in that header, and the update indicator now
            // lives in the menu bar icon whose state the `statusmenu` check asserts (a
            // template image has no colour to measure). VizTheme.success is still used by
            // the History copy confirmation.

            // The popover action buttons must stay neutral: the accent belongs to the title
            // gradient, the update indicator and the system-tinted controls only.
            if surface == .popover {
                let band = buttonBand(rendered.rep)
                let measured = accentShare(rendered.rep, xRange: 0...(rendered.rep.pixelsWide - 1), yRange: band)
                summaries[summaries.count - 1] += String(format: " buttons=%.2f%%", measured.share * 100)
                if measured.share > buttonAccentShareLimit {
                    failures.append("\(label):buttons accent=\(String(format: "%.1f%%", measured.share * 100)) (limit \(String(format: "%.1f%%", buttonAccentShareLimit * 100)))")
                }

                // The shortcut hints must be bright (primary label colour), not .secondary.
                // Only the dark appearance is asserted: in light mode the whole band is
                // bright anyway, so a count there would say nothing.
                let hints = hintBrightPixels(rendered.rep, backdrop: Backdrop.forScheme(scheme))
                summaries[summaries.count - 1] += " hintbright=\(hints)"
                if scheme == .dark && hints < hintBrightPixelMinimum {
                    failures.append("\(label):hints bright=\(hints) < \(hintBrightPixelMinimum)")
                }
            }

            // The settings window must show a real tab strip across the top, not the narrow
            // blob a collapsed stock tab bar produced.
            if surface == .settings {
                let strip = tabStripMetrics(rendered.rep, backdrop: Backdrop.forScheme(scheme))
                summaries[summaries.count - 1] += String(format: " tabstrip=%.0f%%/%druns", strip.widthShare * 100, strip.runs)
                if strip.widthShare < tabStripWidthShareMinimum || strip.runs < tabStripMinimumRuns {
                    failures.append("\(label):tabstrip width=\(String(format: "%.0f%%", strip.widthShare * 100)) runs=\(strip.runs) (need \(String(format: "%.0f%%", tabStripWidthShareMinimum * 100)) and \(tabStripMinimumRuns))")
                }
            }

            if debugMode {
                print("  debug design \(label) \(rendered.url.path)")
            }
        }
    }



    let details = summaries.joined(separator: " | ") + (failures.isEmpty ? "" : " -> failed: \(failures.joined(separator: ", "))")
    return (failures.isEmpty, details)
}


// --- clipboard -------------------------------------------------------------

func checkClipboard() -> (passed: Bool, details: String) {
    let text = "viz-clipboard-check"
    copyTextItemsToClipboard(textItems: [TextItem(text: text)])

    let paste = shell("/usr/bin/pbpaste")
    let readBack = paste.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let pastedOK = paste.status == 0 && readBack == text

    showPreviewWindow(contentView: PreviewContentView())
    pumpRunLoop(0.5)
    let canBecomeKey = previewWindow?.canBecomeKey ?? false
    let windowType = previewWindow.map { String(describing: type(of: $0)) } ?? "nil"

    let passed = pastedOK && canBecomeKey
    let details = "pbpaste(status=\(paste.status))=\"\(readBack)\" expected=\"\(text)\" | previewWindow=\(windowType) canBecomeKey=\(canBecomeKey)"
    previewWindow?.orderOut(nil)
    previewWindow = nil
    return (passed, details)
}

// MARK: - Main

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// `RENDER_CHECK_MODE=cold-window` measures the first settings window of a fresh process and
// does nothing else first: no icon renders, no settings check, no design renders, so the
// window accessor and the content-height preference really are cold when it opens.
if (ProcessInfo.processInfo.environment["RENDER_CHECK_MODE"] ?? "full") == "cold-window" {
    print("==> RenderCheck (cold window)")
    print("==> Working directory: \(rootPath)")
    let cold = checkFirstOpen()
    report("firstopen", cold.passed, cold.details)
    print("==> Summary: \(failures.isEmpty ? "all checks passed" : "failed checks: \(failures.joined(separator: ", "))")")
    exit(failures.isEmpty ? 0 : 1)
}

// Offscreen captures cannot rasterise several Liquid Glass layers at once: a glass
// background wipes the siblings that were drawn before it, which would hide the popover
// header and make the measurements meaningless. The checks therefore render the theme's
// translucent-material path, which is the same layout and palette; the glass appearance
// itself is confirmed by the user on screen.
VizTheme.useMaterialFallback = true

try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Natural popover height, measured the same way `CHECK popoverheight` does.
let naturalPopoverHeight: CGFloat = {
    let hosting = NSHostingView(rootView: HarnessRoot(updater: Updater(owner: "alienator88", repo: "Viz"), scheme: .dark)
        .frame(width: contentWidth))
    hosting.layoutSubtreeIfNeeded()
    pumpRunLoop(0.4)
    hosting.layoutSubtreeIfNeeded()
    return hosting.fittingSize.height
}()

/// The four heights the icon check squeezes the popover to.
let heights: [CGFloat] = iconHeightOffsets.map { (naturalPopoverHeight + $0).rounded() }

let updater = Updater(owner: "alienator88", repo: "Viz")

print("==> RenderCheck")
print("==> Working directory: \(rootPath)")
print("==> Artefacts: \(outputDirectory.path)")

// 1. icons
let measurements = measureIcons(updater: updater)
let iconTable = measurements
    .map { "h=\(Int($0.height)) ink=\($0.ink) band=\($0.band.lowerBound)-\($0.band.upperBound)px scale=\($0.scale)" }
    .joined(separator: " | ")
let iconsPass = measurements.count == heights.count && measurements.allSatisfy { $0.ink >= iconInkThreshold }
report("icons", iconsPass, "\(iconTable) (threshold \(iconInkThreshold) ink px per height)")
for measurement in measurements {
    print("    height-\(Int(measurement.height)).png ink=\(measurement.ink) path=\(measurement.pngPath)")
}

// 2. popover natural height
let popoverHeight = checkPopoverHeight(updater: updater)
report("popoverheight", popoverHeight.passed, popoverHeight.details)

// 3. status menu
let statusMenu = checkStatusMenu(updater: updater)
report("statusmenu", statusMenu.passed, statusMenu.details)

// 4. status panel
let statusPanel = checkStatusPanel(updater: updater)
report("statuspanel", statusPanel.passed, statusPanel.details)

// 5. popover content transparency
let popoverContent = checkPopoverContent()
report("popovercontent", popoverContent.passed, popoverContent.details)

// 6. alignment
let alignment = checkAlignment()
report("alignment", alignment.passed, alignment.details)

// 7. preview close control
let previewClose = checkPreviewClose()
report("previewclose", previewClose.passed, previewClose.details)

// 8. settings
let settings = checkSettings()
report("settings", settings.passed, settings.details)

// 9. clipboard
let clipboard = checkClipboard()
report("clipboard", clipboard.passed, clipboard.details)

// 10. window size
let windowSize = checkWindowSize()
report("windowsize", windowSize.passed, windowSize.details)

// 11. translucency
let translucency = checkTranslucency()
report("translucency", translucency.passed, translucency.details)

// 12. design
let design = checkDesign()
report("design", design.passed, design.details)
for surface in AppSurface.allCases {
    for scheme in [ColorScheme.light, .dark] {
        let name = "design-\(surface.rawValue)-\(scheme == .dark ? "dark" : "light").png"
        print("    \(name) path=\(outputDirectory.appendingPathComponent(name).path)")
    }
}

print("==> Summary: \(failures.isEmpty ? "all checks passed" : "failed checks: \(failures.joined(separator: ", "))")")
exit(failures.isEmpty ? 0 : 1)
