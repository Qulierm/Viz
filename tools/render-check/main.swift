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
/// A pixel counts as "bright" when R + G + B exceeds this value. Text and symbols are
/// drawn in near-white on the dark popover background, while the button border
/// (primary at 20 % over the background) stays well below this threshold.
let brightThreshold = 430
/// Minimum bright pixels in the icon band for the check to consider an icon drawn.
let iconInkThreshold = 60
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

/// R + G + B of a bitmap pixel composited over a backdrop, or nil when the coordinates
/// are outside the bitmap. The app's surfaces are translucent by design (Liquid Glass /
/// materials over window vibrancy), and `colorAt` returns un-premultiplied components,
/// so a 10 % white fill would otherwise read as pure white. Compositing reproduces what
/// the user actually sees.
func pixelSum(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, backdrop: NSColor = Backdrop.dark) -> Int? {
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
    let alpha = color.alphaComponent
    let base = backdrop.usingColorSpace(.deviceRGB) ?? .black
    let red = color.redComponent * alpha + base.redComponent * (1 - alpha)
    let green = color.greenComponent * alpha + base.greenComponent * (1 - alpha)
    let blue = color.blueComponent * alpha + base.blueComponent * (1 - alpha)
    return Int(((red + green + blue) * 255).rounded())
}

/// Window backdrop a surface is drawn over, matching the appearance being rendered.
enum Backdrop {
    static let dark = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    static let light = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)

    static func forScheme(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark ? dark : light
    }
}

func brightCount(_ rep: NSBitmapImageRep, xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange where (pixelSum(rep, x, y) ?? 0) > brightThreshold {
            count += 1
        }
    }
    return count
}

// MARK: - Rendering

struct HarnessRoot: View {
    let updater: Updater

    var body: some View {
        ContentView()
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
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

func renderPopover(height: CGFloat, updater: Updater) -> RenderResult? {
    let frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)

    // The hosting view is rendered detached on purpose. Inside a window, a rigid SwiftUI
    // layout grows the window to its fitting height, so the tight heights would never be
    // exercised; with an explicit frame the content has to squeeze into the requested
    // size, which is exactly the popover situation this check measures.
    let hosting = NSHostingView(rootView: HarnessRoot(updater: updater))
    hosting.appearance = NSAppearance(named: .darkAqua)
    hosting.frame = frame
    hosting.layoutSubtreeIfNeeded()
    pumpRunLoop(0.5)
    hosting.frame = frame
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let raw = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        return nil
    }
    hosting.cacheDisplay(in: hosting.bounds, to: raw)

    let rep = compositedOverBackdrop(raw, backdrop: Backdrop.dark)
    let url = outputDirectory.appendingPathComponent("height-\(Int(height)).png")
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
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
        let count = brightCount(result.rep, xRange: x0...x1, yRange: y...y)
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
            brightCount(result.rep, xRange: x0...x1, yRange: run)
        }

        // The topmost run is the popover header ("V I Z"), which always renders. The
        // widest run below it is the button label. The icon band is everything between
        // the header and the label: when the symbol renders it fills that band with
        // ink, and when it collapses the band stays empty while the label survives.
        let headerRun = runs.first ?? 0...0
        let below = runs.filter { $0.lowerBound > headerRun.upperBound }
        let labelRun = below.max { ink(of: $0) < ink(of: $1) }
        let band: ClosedRange<Int>
        if let labelRun {
            band = (headerRun.upperBound + 1)...max(headerRun.upperBound + 1, labelRun.lowerBound - 1)
        } else {
            band = (headerRun.upperBound + 1)...(result.rep.pixelsHigh - 1)
        }
        let bandInk = brightCount(result.rep, xRange: x0...x1, yRange: band)

        if debugMode {
            print("  debug height \(Int(height)) scale=\(result.scale) bitmap=\(result.rep.pixelsWide)x\(result.rep.pixelsHigh) xband=\(x0)-\(x1)")
            print("  debug runs: \(runs.map { "\($0.lowerBound)-\($0.upperBound)[\(ink(of: $0))]" }.joined(separator: " "))")
            print("  debug header=\(headerRun.lowerBound)-\(headerRun.upperBound) label=\(labelRun.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "none") band=\(band.lowerBound)-\(band.upperBound) ink=\(bandInk)")
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
report("icons", iconsPass, "\(iconTable) (threshold \(iconInkThreshold) bright px per height)")
for measurement in measurements {
    print("    height-\(Int(measurement.height)).png ink=\(measurement.ink) path=\(measurement.pngPath)")
}

// 2. settings
let settings = checkSettings()
report("settings", settings.passed, settings.details)

// 3. clipboard
let clipboard = checkClipboard()
report("clipboard", clipboard.passed, clipboard.details)

print("==> Summary: \(failures.isEmpty ? "all checks passed" : "failed checks: \(failures.joined(separator: ", "))")")
exit(failures.isEmpty ? 0 : 1)
