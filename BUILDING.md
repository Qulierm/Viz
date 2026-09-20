# Building Viz

Two build paths are supported and they do not interfere with each other:

| Path | Toolchain | Output | Use it when |
| --- | --- | --- | --- |
| `Viz.xcodeproj` | Xcode | `Viz.app` built by Xcode | You have Xcode and want the canonical project, asset catalog, icon composer and iCloud entitlements |
| Headless SwiftPM (`Package.swift` + `scripts/`) | Command Line Tools only | `build/Viz.app`, ad-hoc signed | You have no Xcode installed, or you just want a scriptable, one-command build |

The Xcode project is **unchanged** by the headless path. `Package.swift`, `BUILDING.md` and the scripts under `scripts/` are purely additive; nothing in `Viz.xcodeproj` was edited.

## Requirements

- macOS 13.0 or newer (Apple silicon, see [Limitations](#limitations))
- Xcode Command Line Tools, which provide `swift`, `clang`, and the macOS SDK:
  ```
  xcode-select --install
  ```
  Verify the active developer directory points at the Command Line Tools:
  ```
  xcode-select -p
  ```
- The tools the scripts call: `swift`, `python3`, `codesign`, `plutil`, `iconutil`, `sips` (all part of macOS or the Command Line Tools)
- No Xcode, no Apple Developer account and no signing certificate are needed
- Network access is only required for the first dependency fetch (SwiftPM then keeps everything under `build/swiftpm/` and `.build/`)

## Quick start

```
# Build build/Viz.app (release, ad-hoc signed)
bash scripts/build-app.sh

# Optional flags
bash scripts/build-app.sh --clean     # remove build/ and .build/ first, then build from scratch
bash scripts/build-app.sh --debug     # build the Debug configuration instead of Release
bash scripts/build-app.sh --install   # additionally copy the bundle to ~/Applications

# Prove the packaged app starts and stays alive for 6 seconds
bash scripts/smoke-test.sh
```

After launching `build/Viz.app`, Viz appears in the **menu bar** — there is no Dock icon and no main window, because the bundle is built with `LSUIElement = true`. Use the menu bar icon (or the configured global hotkeys) to capture.

## What the scripts do

`scripts/prepare-deps.sh`

1. Resolves the SwiftPM dependencies with all caches inside the repository (`build/swiftpm/cache`, `build/swiftpm/config`, `build/swiftpm/security`) and the scratch path at `.build`.
2. Patches the `KeyboardShortcuts` checkout so it compiles without Xcode (see below).
3. Is idempotent: a second run skips the patch and still exits 0.

`scripts/build-app.sh`

1. Checks that every required tool is on `PATH` and prints `swift --version`.
2. Runs `scripts/prepare-deps.sh`, then `swift build -c release` (or `-c debug`).
3. Assembles `build/Viz.app` from scratch:
   - `Contents/MacOS/Viz` — the SwiftPM binary
   - `Contents/Resources/water.mp3` — the capture sound, loaded through `NSSound(named: "water")`, which only searches the main bundle
   - `Contents/Resources/Viz.icns` — generated with `iconutil` from the PNGs in `Viz/Assets.xcassets/AppIcon.appiconset/`
   - `Contents/Info.plist` — copied from `Viz/Info.plist` so `NSCameraUsageDescription` and `NSUbiquitousContainers` stay single-sourced, then extended with the keys Xcode would otherwise inject (`CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion`, `LSUIElement`, …)
4. Signs the bundle ad-hoc (`codesign --force --sign -`), without `--deep` and without entitlements.
5. Self-checks the result: `plutil -lint`, every required Info.plist key, the sound and icon resources, `file` on the binary, and `codesign --verify --verbose=2`.

`scripts/smoke-test.sh`

Launches `build/Viz.app/Contents/MacOS/Viz` directly, verifies with `kill -0` that the process is still alive after 6 seconds, fails on crash signatures in the log, and then terminates the process and confirms it is gone. It never needs `open`, `ps` or `pgrep`.

## Why the workarounds exist

### `actool` is Xcode-only, so the asset catalog cannot be compiled

Xcode compiles `Viz/Assets.xcassets` into `Assets.car` with `actool`. That tool ships with Xcode, and without it every string-based lookup such as `Color("bg")` or `NSColor(named: "mode")` would silently return nothing at runtime. The headless build therefore defines those two colors in code in `Viz/Logic/VizColors.swift` (`Color.vizBackground` and `NSColor.vizInsertionPoint`), with values that mirror `bg.colorset` and `mode.colorset` exactly (Display P3, `0x31/0x34/0x43`, and black in light / white in dark). App icons are converted from the catalog PNGs into a plain `Viz.icns` with `iconutil`, which is part of the Command Line Tools. `Viz/Assets.xcassets` is left untouched and is still used by the Xcode build; it is merely excluded from the SwiftPM target.

### `KeyboardShortcuts` 2.4.0 needs Xcode's `PreviewsMacros` plugin

The package contains `#Preview { … }` blocks in `Sources/KeyboardShortcuts/Recorder.swift`, and those require Apple's `PreviewsMacros` compiler plugin, which is only shipped with Xcode. The block sits inside `#if os(macOS)`, so it breaks release builds too, not just previews. `scripts/prepare-deps.sh` removes the affected blocks from the SwiftPM checkout after resolving (making the read-only checkout file writable first) and fails loudly if a `#Preview` block is still present afterwards. Because both dependencies are pinned (`AlinFoundation` at revision `f61241c2ea1856ef41cbfc965afe9d756121456f`, `KeyboardShortcuts` at exactly `2.4.0`), the patch stays stable across runs.

### SwiftPM's manifest sandbox and `~/Library` caches

SwiftPM normally evaluates package manifests inside `sandbox-exec`, which some restricted environments refuse to apply:

```
sandbox-exec: sandbox_apply: Operation not permitted
```

and SwiftPM's default caches (`~/Library/org.swift.swiftpm`, `~/Library/Caches/org.swift.swiftpm`) can be read-only. The scripts therefore pass `--disable-sandbox` together with explicit in-repository `--cache-path`, `--config-path` and `--security-path` values under `build/swiftpm/`, so a build never depends on `~/Library` being writable and never trips over the manifest sandbox.

Where the environment does permit it, the sandbox can be switched back on:

```
VIZ_SWIFTPM_SANDBOX=on bash scripts/build-app.sh
```

## Limitations

- **No entitlements are applied.** `Viz/Viz.entitlements` declares restricted iCloud entitlements (`com.apple.developer.icloud-*`). Those require a provisioning profile, and combining them with an ad-hoc signature makes macOS kill the app at launch. Ad-hoc builds therefore ship without them, which means `FileManager.url(forUbiquityContainerIdentifier:)` returns `nil`: **iCloud history sync is unavailable** and history is stored locally in `~/Library/Application Support/Viz/historyItems.json`.
- **Permissions are re-requested after every rebuild.** The ad-hoc signature changes with each build, so macOS treats the app as new and asks again for Screen Recording (used by `/usr/sbin/screencapture`) and Camera access.
- **arm64 only.** The headless build produces a single-architecture arm64 binary; there is no universal build and no Intel slice.
- **Not notarized, not distributable.** The bundle is ad-hoc signed, so it is meant for local use. Shipping it to other Macs requires a Developer ID identity and a provisioning profile; pass your identity with `VIZ_SIGN_IDENTITY="Developer ID Application: …"`. Note that a Developer ID signature still needs the entitlements to be dropped unless the app is provisioned for iCloud.

## Versioning

The defaults live in `scripts/build-app.sh` and match the Xcode project:

| Setting | Default | Xcode equivalent |
| --- | --- | --- |
| `VIZ_VERSION` | `2.3.3` | `MARKETING_VERSION` |
| `VIZ_BUILD` | `18` | `CURRENT_PROJECT_VERSION` |

Both are kept in sync manually with `Viz.xcodeproj/project.pbxproj`. Override them for a one-off build:

```
VIZ_VERSION=2.3.4 VIZ_BUILD=19 bash scripts/build-app.sh
```

Other environment overrides: `VIZ_SIGN_IDENTITY` (default `-`, ad-hoc), `VIZ_INSTALL_DIR` (default `~/Applications`, used by `--install`) and `VIZ_SWIFTPM_SANDBOX` (set to `on` to re-enable SwiftPM's sandbox).

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '…/CommandLineTools' is a command line tools instance` | You invoked the `Viz.xcodeproj` path without Xcode installed. Use `bash scripts/build-app.sh`, which only needs the Command Line Tools |
| `PreviewsMacros plugin not found` / `external macro implementation … not found` | The `#Preview` blocks are still in the `KeyboardShortcuts` checkout. Run `bash scripts/prepare-deps.sh` (or `bash scripts/build-app.sh --clean`) to re-apply the patch |
| `not accessible or not writable` cache warnings | SwiftPM cannot use its default `~/Library` caches. Make sure you build through the scripts, which pass in-repo `--cache-path`, `--config-path` and `--security-path` values |
| `sandbox-exec: sandbox_apply: Operation not permitted` | SwiftPM's manifest sandbox is denied in this environment. The default (`--disable-sandbox`) already avoids it, so build through the scripts; only set `VIZ_SWIFTPM_SANDBOX=on` where the sandbox is actually permitted |
| `codesign` failures such as `code object is not signed at all` or `resource fork … not allowed` | Delete the stale bundle and rebuild: `bash scripts/build-app.sh --clean`. If you pass your own `VIZ_SIGN_IDENTITY`, make sure the identity is in the keychain (`security find-identity -v -p codesigning`) |
| The app launches but shows no window | Expected: Viz is a menu bar app (`LSUIElement = true`). Look for its icon in the menu bar, not in the Dock |
| `Address already in use`-style leftovers, or a smoke test that fails because a previous Viz is still running | An earlier run was not cleaned up. Terminate the leftover process (for example by quitting it from the menu bar) and re-run `bash scripts/smoke-test.sh` |
| Port/process leftovers after an interrupted smoke test | `scripts/smoke-test.sh` kills its own child via an `EXIT` trap; if the script itself was killed with `SIGKILL`, close the app manually and re-run the script |
| Popover buttons without icons, a gear that does nothing, or captured text that never reaches the clipboard | Run `bash scripts/render-check.sh`. It names the failing check (`icons`, `settings` or `clipboard`) and exits non-zero; see [Verifying UI behaviour without a GUI](#verifying-ui-behaviour-without-a-gui) |
| The popover looks unstyled, or icons/accents are missing | Run `bash scripts/render-check.sh` and open `build/render-check/design-popover-*.png`: the `design` check fails when a surface renders blank, when the blue accent is missing where it belongs, or when the removed flat background colour comes back. The `icons` check fails when the popover symbols collapse again |

## Unchanged Xcode path

The headless build is additive only. `Viz.xcodeproj/project.pbxproj`, its shared schemes (`Viz Debug`, `Viz Release`), `Viz.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, `Viz/Info.plist`, `Viz/Viz.entitlements` and `Viz/Assets.xcassets` are untouched, so opening the project in Xcode still builds exactly as before. The only source change made for the headless path is `Viz/Logic/VizColors.swift` plus the seven call sites that used to look up colors in the asset catalog; those colors resolve identically under Xcode.

## macOS 27 compatibility fixes

Three defects appeared when Viz 2.3.3 was run on macOS 27. All three are fixed in the shared sources, so both build paths (Xcode and headless) get the fixes.

### Popover button icons disappeared

**Symptom:** the five action buttons in the menu bar popover showed their labels and shortcut pills but no SF Symbols, while the header gear/close icons still rendered.

**Root cause:** `RoundedRectangleButtonStyle` sized its symbol with `.resizable().aspectRatio(contentMode: .fit).frame(width: size)`. A resizable symbol has no intrinsic size, so it is the first thing the layout squeezes when vertical space is tight — and the popover on macOS 27 hands out less height than the content asks for. Measuring the real `ContentView` at decreasing heights showed the icon band going from ink to nothing while the labels survived.

**Fix:** the symbol is now font-sized with an explicit square slot and made rigid — `.font(.system(size: size))`, `.frame(width: size, height: size)`, `.fixedSize()`. Point sizes, paddings and spacing are unchanged, so the popover looks exactly as before wherever the old code rendered correctly. The same hardening was applied to `SimpleButtonBrightStyle`, `SimpleButtonStyle` and `InfoButton`.

### The gear never opened the settings window

**Symptom:** clicking the gear stored the selected tab but nothing appeared.

**Root cause:** `openAppSettings()` in `Viz/Logic/Windows.swift` declared `@Environment(\.openSettings)` inside a free function. That property wrapper only resolves inside a `View` body; anywhere else SwiftUI hands back the default action, which does not present the `Settings` scene, so the call was silently swallowed.

**Fix:** the settings now open in a regular window through the same `WindowManager.shared.open(...)` path that already works for History and About, with `AppState.shared`, `HistoryState.shared` and a single shared `Updater` from `AppServices.shared` injected as environment objects. `VizApp` uses that same shared updater, so both windows observe one instance.

### Captured text did not reach the clipboard

**Symptom:** text recognised by OCR was not available to paste, even though captures succeeded.

**Root cause:** two separate issues. The pasteboard write in `copyTextItemsToClipboard(textItems:)` was never verified — a failed write left the clipboard cleared with no error anywhere — and the preview window was a borderless `NSWindow`, which cannot become key, so its selectable text could never receive ⌘C.

**Fix:** the write is now verified by reading the value back, and falls back to writing through `/usr/bin/pbcopy` in a separate process; failures are surfaced through `printOS` and `AppState.shared.cmdOutput` instead of being ignored. The preview window is now a `KeyablePreviewWindow` (`canBecomeKey == true`, `canBecomeMain == false`) with identical visuals, and its auto-hide is postponed while the window is key so it is not pulled away mid-selection.

## Verifying UI behaviour without a GUI

`bash scripts/render-check.sh` checks the three behaviours above objectively, without a human at the screen. It builds the application's **real sources** — every Swift file under `Viz/` except `VizApp.swift`, which carries `@main`, plus `tools/render-check/*.swift` — in a temporary SwiftPM package under `${TMPDIR:-/tmp}/viz-render-check`, reusing the repository's caches and the same `#Preview` patch as `scripts/prepare-deps.sh`. The repository itself is never modified.

The three checks:

| Check | What it does |
| --- | --- |
| `icons` | Renders the real `ContentView` at 600 pt wide with popover heights 172, 165, 158 and 150 and counts bright pixels (R+G+B > 430) in the first button's icon band. The band is located from the render itself: the topmost ink run is the always-present header and the widest run below it is the label, so the rows in between are exactly where a symbol must draw. A symbol that collapses leaves that band empty. |
| `settings` | Calls the app's own `openAppSettings(selectedTab: 1)` and then looks for a window created by that call that is visible and hosts `SettingsView` (found through the view tree, because a window created with a material keeps its hosting view inside a visual-effect container). |
| `clipboard` | Calls the app's own `copyTextItemsToClipboard(textItems:)` and reads the value back from a **separate** `/usr/bin/pbpaste` process, then shows the preview window and asserts `previewWindow?.canBecomeKey == true`. |

Each check prints one `CHECK <name>: PASS|FAIL <details>` line with the numbers it measured, followed by a summary; the script exits non-zero when any check fails, so it can be used in a loop or as a pre-release gate. The rendered popover images are written to `build/render-check/height-<H>.png` (2x, so 1200 px wide) next to `build/render-check/render-check.log`, which makes a failure diagnosable by eye. The harness writes its per-user state into a throwaway home inside `$TMPDIR`, so it does not touch the real `~/Library`.

The harness instantiates the same dependency (`Updater`) as the app, so on first run it fetches the pinned packages just like a normal build.

## Design system

Viz follows a small, explicit design system so every surface looks the same and can be checked automatically. It lives in `Viz/Logic/VizColors.swift` (kept under its original name because `Viz.xcodeproj` lists its sources explicitly).

### Palette and geometry

| Token | Value | Use |
| --- | --- | --- |
| `VizTheme.accent` | display-P3 (0.20, 0.52, 1.00) | The single accent: symbols, selection, focused controls, prominent buttons |
| `VizTheme.accentBright` | display-P3 (0.45, 0.75, 1.00) | Lighter shade, only for the title gradients (popover and About) |
| `VizTheme.accentSoft` | `accent` at 18 % opacity | Panel strokes, hover rings, subtle tints |
| `VizTheme.cornerLarge` / `cornerMedium` / `cornerSmall` | 22 / 16 / 10 pt | Panels, buttons and rows respectively |

Rules: the blue accent is the only accent colour, and `.red` is reserved for destructive or denied states (the History trash button, the camera-permission-denied text). Supporting text uses `.primary`/`.secondary`; no other hardcoded colours, no heavy shadows, and no gradients beyond the two title treatments.

### Liquid Glass strategy

Liquid Glass is macOS 26+, while Viz deploys to macOS 13, so the availability branching lives inside the theme instead of at the call sites. Three helpers cover everything:

| Helper | macOS 26+ | macOS 13–25 |
| --- | --- | --- |
| `.vizGlassSurface(cornerRadius:tint:)` | `glassEffect(.regular[.tint(tint)], in: .rect(cornerRadius:))` behind the content | `.ultraThinMaterial` in a rounded rectangle |
| `.vizGlassInteractive(cornerRadius:tint:)` | `glassEffect(.regular.tint(tint.opacity(0.35)).interactive(), …)` | an accent tint at 15 % |
| `.vizGlassButton(prominent:tint:)` | `.buttonStyle(.glassProminent)` / `.buttonStyle(.glass)` | `VizMaterialButtonStyle`, a capsule with a material fill and a pressed state |

Use `vizGlassSurface` for panels (settings sections, history rows, preview and About panels), `vizGlassInteractive` for custom controls that must react to hover/press (the popover action buttons), and `vizGlassButton` for anything that is a real `Button`. `.vizPill()` styles the small capsule labels (shortcut hints, the webcam camera picker). The glass is applied as a *background* layer rather than by wrapping a view in `glassEffect`, because content that is inside a glass effect is composited by the glass layer and cannot be captured by any offscreen renderer — the design checks would be blind to it.

### System appearance

The legacy flat background (`bg.colorset` / `mode.colorset`, display-P3 49, 52, 67) and the forced dark appearance are gone: the app follows the system appearance and the windows keep the vibrancy they already get from `WindowManager`/`.material(.sidebar)`. That is why the design checks render every surface in **both** appearances — a surface that only looks right in one of them is a bug.

### Design checks

`bash scripts/render-check.sh` (see [Verifying UI behaviour without a GUI](#verifying-ui-behaviour-without-a-gui)) renders every surface — popover, settings, history, about, preview — in light and dark and writes `build/render-check/design-<surface>-<appearance>.png`. The `design` check fails when a surface renders blank (less than 5 % of its pixels differ from the window backdrop), when a surface that carries the accent shows fewer than 60 accent pixels (hue within 30° of 220, saturation > 0.35, brightness > 0.45), or when the removed flat background colour reappears on more than 8 % of any render. The `icons` check measures the popover symbol the same way — accent pixels inside the first button's icon band — which is the colour the redesign draws there (this supersedes the earlier brightness-based description of that check).

Note that the checks render the material path: offscreen captures cannot rasterise several Liquid Glass layers at once (a glass background wipes the siblings drawn before it), so the harness sets `VizTheme.useMaterialFallback` and measures the same layout and palette. The glass appearance itself is confirmed by the user on screen.
