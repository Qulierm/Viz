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

let heights: [CGFloat] = [172, 165, 158, 150]
let contentWidth: CGFloat = 600
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
/// Ceiling for the popover's natural height. The popover measures about 161 pt after the
/// padding trim (it was 177 pt), so this catches a regression back to the taller layout.
let popoverHeightCeiling: CGFloat = 170
/// Minimum number of bright pixels in the shortcut-pill band of the dark popover render.
/// The hints are drawn in the primary label colour (white in dark), which yields ~800 such
/// pixels; `.secondary` leaves the band almost dark, so this catches a return to grey.
let hintBrightPixelMinimum = 150
/// Luminance above which a pixel counts as bright hint text.
let hintBrightLuminance = 200.0 / 255.0
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
/// The first action button spans x 16..125.6 pt in a 600 pt wide popover and its icon
/// is centred at about x 70.8 pt. The measured column band is given in points and
/// scaled by the real bitmap scale, so it covers x 60..240 device pixels at 2x.
let iconBandXRange: ClosedRange<CGFloat> = 30...120

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
func renderView<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, pngName: String) -> NSBitmapImageRep? {
    let frame = NSRect(origin: .zero, size: size)
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    hosting.frame = frame
    hosting.layoutSubtreeIfNeeded()
    pumpRunLoop(0.4)
    hosting.frame = frame
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let raw = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
    hosting.cacheDisplay(in: hosting.bounds, to: raw)

    let rep = compositedOverBackdrop(raw, backdrop: Backdrop.forScheme(scheme))
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

        // The topmost run is the popover header ("V I Z"), which always renders. The run
        // below it is the button's own top edge, and the widest run below that is the
        // label. The icon band is what lies between the button edge and the label: when the
        // symbol renders it fills that band with ink, and when it collapses the band keeps
        // only the flat button surface, whose pixels all match the band median.
        let headerRun = runs.first ?? 0...0
        let below = runs.filter { $0.lowerBound > headerRun.upperBound }
        let labelRun = below.max { ink(of: $0) < ink(of: $1) }
        let chromeRun = below.first { $0.upperBound < (labelRun?.lowerBound ?? Int.max) }
        let band: ClosedRange<Int>
        if let labelRun, let chromeRun, chromeRun.upperBound + 1 < labelRun.lowerBound {
            band = (chromeRun.upperBound + 1)...(labelRun.lowerBound - 1)
        } else if let labelRun {
            band = (headerRun.upperBound + 1)...max(headerRun.upperBound + 1, labelRun.lowerBound - 1)
        } else {
            band = (headerRun.upperBound + 1)...(result.rep.pixelsHigh - 1)
        }
        let bandInk = luminanceInkCount(result.rep, xRange: x0...x1, yRange: band)

        if debugMode {
            print("  debug height \(Int(height)) scale=\(result.scale) bitmap=\(result.rep.pixelsWide)x\(result.rep.pixelsHigh) xband=\(x0)-\(x1)")
            print("  debug runs: \(runs.map { "\($0.lowerBound)-\($0.upperBound)[\(ink(of: $0))]" }.joined(separator: " "))")
            print("  debug header=\(headerRun.lowerBound)-\(headerRun.upperBound) chrome=\(chromeRun.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none") label=\(labelRun.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none") band=\(band.lowerBound)-\(band.upperBound) ink=\(bandInk)")
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
        case .popover: return NSSize(width: contentWidth, height: 172)
        case .settings: return NSSize(width: 520, height: 700)   // the compact window, General tab
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

func renderSurface(_ surface: AppSurface, scheme: ColorScheme) -> (rep: NSBitmapImageRep, url: URL)? {
    // The settings check runs before this one and selects the Shortcuts tab, but the design
    // render should show the tab a user sees first (General), which is also where the
    // accent-tinted controls live.
    if surface == .settings {
        UserDefaults.standard.set(0, forKey: "settingsSelectedTab")
    }
    let size = surface.size
    let root = SurfaceRoot(surface: surface, scheme: scheme)
        .frame(width: size.width, height: size.height)
    let name = "design-\(surface.rawValue)-\(scheme == .dark ? "dark" : "light").png"
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
    let base = backdrop.usingColorSpace(.deviceRGB) ?? .black

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
            guard let rendered = renderSurface(surface, scheme: scheme) else {
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
            if surface.requiresAccent {
                let floor = surface == .popover ? popoverAccentFloor : accentPixelThreshold
                if metrics.accentPixels < floor {
                    failures.append("\(label):accent(\(metrics.accentPixels))")
                }
            }
            if metrics.legacyShare > legacyShareLimit {
                failures.append("\(label):legacy(\(String(format: "%.1f%%", metrics.legacyShare * 100)))")
            }

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

// 3. settings
let settings = checkSettings()
report("settings", settings.passed, settings.details)

// 4. clipboard
let clipboard = checkClipboard()
report("clipboard", clipboard.passed, clipboard.details)

// 5. window size
let windowSize = checkWindowSize()
report("windowsize", windowSize.passed, windowSize.details)

// 6. design
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
