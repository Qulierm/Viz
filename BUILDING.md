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
| The settings tabs are squashed or unreadable | Run `bash scripts/render-check.sh`: the `tabstrip` guard measures the settings render's top strip and fails when the items no longer span the width or merge into fewer than three runs. Open `build/render-check/design-settings-dark.png` to see the strip as rendered |
| The settings window is clipped the first time it opens | Run `bash scripts/render-check.sh`: its cold-window run starts a fresh process whose first action is opening the settings window and fails with `CHECK firstopen: FAIL ... height 488 < needed 761` if that first fit is lost again. The fit is triggered from `SettingsWindowAccessor` plus a short retry |
| The settings window is cut off or clipped | Run `bash scripts/render-check.sh`: the `windowsize` guard opens the real window on each tab and fails when the content is taller or wider than the window, when the window leaves the screen, or when its top-left corner moves between tabs (for example `windowsize: FAIL general height 488 < needed 761`). The window is sized to the tab by `SettingsView.fitWindowToContent()` |

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

### Revised rules: neutral controls, accent only where it means something

The first pass of the redesign tinted every control blue and that was too much, so the rules above are narrowed as follows (this supersedes the "symbols … prominent buttons" wording in the palette table and the `vizGlassInteractive` usage note):

- **Neutral by default.** The popover action buttons, the shortcut pills and the header controls are grey glass with `.primary` symbols and labels. Two extra helpers cover them:
  - `.vizGlassControl(cornerRadius:)` — neutral glass for custom controls (`glassEffect(.regular.interactive())` on macOS 26+, otherwise `.ultraThinMaterial` plus a `Color.primary.opacity(0.10)` hairline). This is what `RoundedRectangleButtonStyle` uses now.
  - `.vizGlassBubble(size:tint:)` — a circular glass surface for the header controls, neutral unless a `tint` is passed.
- **The blue accent is reserved for**: the app title gradients, the update-available indicator (the settings bubble tint and the arrow colour), selection states (the active settings tab, the History copy feedback and swatch outline) and the controls macOS tints itself through the app-wide `.tint` (switches, segmented selections, focus rings, the prominent buttons in the webcam overlay and the Updates tab).
- `.red` stays reserved for destructive or denied states.
- **The original Viz palette is restored as Liquid Glass tints.** The surface is the pre-redesign `bg` colour, display-P3 (49, 52, 67) / `#313443`: `VizTheme.surfaceTint` (0.40) on the window and popover roots and `VizTheme.cardTint` (0.22) on cards, rows and panels, so the hierarchy stays readable and the surfaces keep sampling the desktop. It is a **translucent tint, never an opaque paint** — the material path applies the tint above the material for the same reason. `VizTheme.brandGradient` (red → purple → blue) is back on the popover and About titles, `VizTheme.success` (green) marks the update-available bubble and the History copy confirmation, `VizTheme.link` (blue) is used by the History URL opener, the webcam selection rectangle and the About GitHub button, and red stays on the destructive trash button and the camera-permission-denied state. The app-wide control tint stays blue.
- **The shortcut hints are labels, not secondary text.** `.vizPill()` draws them in the primary label colour (`.foregroundStyle(.primary)`), which is white in the dark popover and black in light, so they stay readable in both appearances instead of fading into grey. The popover's vertical padding was tightened at the same time — the action buttons use 16/12 pt padding instead of a uniform 16, the action row 16/13 pt instead of a uniform 16, and each button column 6 pt spacing instead of 8 — which took the natural height from 177 to 161 pt without moving or resizing any element.

### Settings window layout

`SettingsView` no longer uses the stock tab bar: inside the 560x520 window `WindowManager` opens, that bar collapsed into an unreadable blob in the top strip, so the tabs are drawn explicitly as an `HStack` of icon-over-label buttons (17 pt symbol, 11 pt label, 92 pt minimum width) with a rounded selection behind the active one. The strip keeps the `settingsSelectedTab` binding, so `openAppSettings(selectedTab:)` still preselects the right tab.

Below the strip a divider is followed by a `ScrollView` holding the selected tab, built from three helpers in the same file:

| Helper | What it draws |
| --- | --- |
| `SettingsSection(title:)` | A semibold 13 pt heading above a `.vizGlassSurface(cornerRadius: 14)` panel |
| `SettingsRow(title:subtitle:control:)` | A 13 pt title with an optional 11 pt `.secondary` subtitle on the left, the control trailing, 14 pt horizontal and 10 pt vertical padding |
| `SettingsRowDivider` | A 0.35-opacity divider indented 14 pt, placed between rows and never after the last one |

Rows therefore read as *title / subtitle / control* (switches are `Toggle("").toggleStyle(.switch).labelsHidden()`, pickers and `KeyboardShortcuts.Recorder` sit in the trailing slot). The `Spaced*` toggle styles remain in `Viz/Styles.swift` but are no longer used by the settings window. The window asks for 560x520 and the settings root carries `.frame(minWidth: 560, minHeight: 520)`, without which AppKit shrinks the window to the content's fitting size and the strip and rows end up cramped.

#### The window follows the tab (supersedes the fixed size above)

A fixed 520 pt window could not show the General tab: that tab's content needs **771.5 pt** (measured from the hosting view's `fittingSize`), so roughly a third of it — including the whole "System" section — was cut off below the bottom edge. The window is therefore sized to the selected tab:

- **Width 690 pt**, fixed. The widest tab is Updates at 686.5 pt (AlinFoundation's `RecentReleasesView` has a large intrinsic width), so one width that fits every tab avoids horizontal resizing when switching.
- **Height per tab**: General ≈ 772, Updates ≈ 711 (715 in the harness measurement), Shortcuts and About ≈ 452–552 pt of content. `SettingsView.fitWindowToContent()` reads the hosting view's `fittingSize.height` (the measured content height is the fallback when the view tree is unavailable), clamps it to `screen.visibleFrame.height - 100` and never below 420, adds the title-bar chrome (`frame.height - contentLayoutRect.height`) and applies the new frame.
- **Clamping scrolls, never clips**: the content stays inside a `ScrollView`, so a screen too short for a tab scrolls the rest instead of cutting it off.
- **Top-left corner stays put**: the new origin is computed from the old frame's `maxY` (`newOriginY = oldMaxY - newHeight`) and then clamped into `screen.visibleFrame`, so switching tabs resizes the window downwards instead of making it jump.
- **Centred on open** (`WindowManager.open(..., center: true)`) and the title **"Viz Settings"** is shown, with the title bar still transparent.

The view re-fits on open, whenever the content height changes (a `GeometryReader` preference on the tab content) and whenever `settingsSelectedTab` changes.

**The compact metrics (supersede the 690 pt figures above).** The window is now **520 pt wide** — the figures quoted above describe the earlier, wider layout. Measured per tab after the compaction: General `520x698` frame / `520x666` content, Shortcuts `520x444` / `412`, Updates `520x687` / `655`, About `520x499` / `467`, all with the same fit rule (`contentLayoutRect.height >= min(fittingSize.height, screen.visibleFrame.height - 100) - 8`). The spacing was tightened rather than the content cut: content padding 20 → 16, section spacing 18 → 12, row vertical padding 10 → 7, section heading gap 8 → 4, tab strip 69 → 59 pt (strip padding 12/8 → 8/6, tab button padding 8 → 6) and the minimum content floor 420 → 380. Two AlinFoundation views would otherwise force the old width: `RecentReleasesView` (intrinsic width 678 pt) is hosted in a flexible `Color.clear` overlay and the frequency row carries an explicit `idealWidth: 200`, so both wrap to the width they are given instead of widening the window; the releases list height is 300 pt and it scrolls internally. A **compactness ceiling (max 560x700)** is now enforced by the harness, so the window cannot silently grow back to 690x793.

**The first open counts too.** The first open of a fresh process used to stay at the initial size with the lower sections clipped: the content-height preference fires before `SettingsWindowAccessor` has stored the window, so `fitWindowToContent()` returned early at its `guard let window` and nothing ran again. The accessor now fits the window as soon as it captures it, plus two retries — one on the next run-loop turn and one after 0.2 s — so the first layout pass is covered. That capture-time fit runs once per window (a `hasFittedWindow` flag), and every fit is inert unless the computed frame differs by more than half a point, so the retries cause no churn and a later user resize is not fought.

### Design-check additions

The `design` check gained two guards for the revised rules, and the icon check now uses a different metric:

- **`buttons`** — the share of blue-tinted pixels (hue within 30° of 220, saturation > 0.12, brightness > 0.2) inside the popover's action-button band must stay at or below 1.5 %. Neutral buttons measure 0.00 %; an accent-tinted button surface measures ~65 % and fails.
- **`tabstrip`** — the settings surface's topmost ink region must span at least 45 % of the surface width and contain at least three separated items. The real strip measures 58 % / 4 runs; a squashed strip measures 11 % and fails.
- The **`icons`** check now measures *luminance contrast*: pixels whose Rec. 709 luminance differs from the icon band's median by more than 40/255, counted inside the band between the button's top edge and the label. The band starts below the button's own top edge so the button chrome is not counted. The symbols are neutral now, so the earlier accent-based metric would be blind to them.
- The `windowsize` and `firstopen` checks assert **both fitting and compactness**: besides the vertical and horizontal fit rules above, the window must stay within `settingsWindowMaxWidth` 560 pt and `settingsWindowMaxHeight` 700 pt, failing with e.g. `windowsize: FAIL general window 690x698 is not compact (max 560x700)`. The settings surface used by the design check is rendered at the compact 520x700.
- **`firstopen`** — a separate process started with `RENDER_CHECK_MODE=cold-window` whose very first action is `openAppSettings(selectedTab: 0)`, exactly like a user clicking the gear right after launch: no icon renders, no settings check and no design renders run before it. It asserts the same vertical and horizontal fit as `windowsize` and reports the numbers, e.g. `CHECK firstopen: PASS frame=690x793 content=690x761 fitting=560x772 allowedHeight=761 origin=390,61 title="Viz Settings"`. Before the first-open fix it reported `FAIL frame=690x520 content=690x488 ... height 488 < needed 761`. `scripts/render-check.sh` runs the harness twice — the full suite and then this cold-window process — tees both into `build/render-check/render-check.log`, prints `==> RenderCheck (full) exit N` and `==> RenderCheck (cold window) exit N`, and fails if either run fails.
- **`windowsize`** — opens the settings window on each of the four tabs in turn (clearing the `NSWindow Frame settings` autosave entry first so no stale frame is restored) and asserts, per tab: the window's `contentLayoutRect.height` is at least `min(fittingSize.height, screen.visibleFrame.height - 100) - 8`; its width is at least `fittingSize.width - 8` (the Updates tab needs 686.5 pt); the frame stays inside `screen.visibleFrame`; and the top-left corner does not move by more than 2 pt between tabs. Measured values: General 690x793 frame / 690x761 content / 560x772 fitting, Shortcuts 690x484 / 690x452 / 560x452, Updates 690x747 / 690x715 / 686x715, About 690x517 / 690x485 / 560x485. It fails with e.g. `windowsize: FAIL general height 488 < needed 761` — the numbers the old fixed 520 pt window produced.
- The popover also has its own accent floor (300 pixels against the measured 1127 light / 1307 dark), stricter than the generic 60, so losing the title gradient or the update indicator fails.
- **`surface`** — the dominant colour of the popover and settings renders must read as the classic Viz blue-grey. It is measured as the blue-minus-red cast with a calibrated window of 4...15: a neutral material surface gives 0, the tinted surface measures 6-8, and the opaque `#313443` measures 21, so painting the surface flat fails while a merely neutral surface fails too. This supersedes the earlier `legacy` assertion, which required the old colour to be *absent* and directly contradicted the restored palette (the legacy line above is kept only as history).
- **`brand`** — the title band of the popover (30 %) and About (55 %) renders must contain at least 40 pixels in each of the red (~0°), purple (~285°) and blue (~220°) hue windows, proving the red-purple-blue gradient is back; a blue-only gradient measures 0 red and 0 purple and fails.
- **`success`** — the dark popover render must contain at least 40 green pixels (hue within 30° of 120°), which is the update-available bubble; removing the green state measures 0 and fails.
- **`popoverheight`** — renders the real `ContentView` in a hosting view at 600 pt wide with no height constraint and asserts the `fittingSize` height stays at or below 170 pt. The popover measures **600x161** after the vertical padding was tightened (it was 600x177), and the check fails with `natural height 177 > 170` if the taller padding comes back.
- **Hint brightness** — in the dark popover render, the shortcut-pill band (the row below the action buttons) must contain at least 150 pixels brighter than 200/255 luminance; the primary label colour yields ~550, while `.secondary` yields 0, so a silent return to grey fails with `popover-dark:hints bright=0 < 150`.

All artefacts — `build/render-check/design-<surface>-<appearance>.png`, `height-<H>.png` and `render-check.log` — are written under `build/render-check/`, which is gitignored.

**The popover no longer dismisses itself the moment it appears (supersedes the dismissal notes above).** Moving the popover from `NSPopover` to our own panel introduced a regression that made it invisible: the controller observed `NSApplication.didResignActiveNotification` and ran the same dismissal handler as the resign-key observer, but that notification fires immediately after the menu bar click that opened the panel, when the system restores the previously active app - so the panel was hidden as soon as it was shown. The panel also had `hidesOnDeactivate = true`, which let AppKit hide it on that same deactivation independently of our observers. The fix: that observer is removed, `hidesOnDeactivate` is `false`, resignations that arrive inside a named `showGracePeriod` (0.35 s) after showing are ignored - a non-activating panel can receive spurious resignations in that moment, and the grace separates "the click that opened it" from "the user clicked elsewhere" - a resignation after the grace still closes the panel, click-away dismissal is handled by a permission-free global monitor for `.leftMouseDown`/`.rightMouseDown`/`.otherMouseDown` installed while the panel is shown and removed when it closes (with a logged fallback to the resign-key path if no monitor can be installed), and Esc and the status-button toggle keep working. The panel's material, blending, level, opacity, corner radius, size (600x99) and position are unchanged.

In the design-check section the `statuspanel` check now asserts the **correct lifecycle** and prints every step: `lifecycle=show:ok/monitorInstalled:ok/survivesAppResignActive:ok/survivesResignInsideGrace:ok/ignoresAppResignActive:ok/resignAfterGraceCloses:ok/monitorRemoved:ok/hidesOnDeactivateOff:ok/toggleCloses:ok/escCloses:ok/clickAwayCloses:ok`. The previous version had encoded the buggy behaviour - it asserted that a resign-key notification *does* dismiss the panel, which is why it passed while the popover was invisible. The regression guard is the `ignoresAppResignActive` step, which posts the deactivation with the grace period bypassed: with the old observer restored the panel is dismissed there and the check fails naming that step. The printed frame is now `inside`/`offscreen`/`noscreen` rather than absolute coordinates, because the absolute position depends on where this process's status item lands and varied between runs.

**The popover is drawn with the menu bar's own material (supersedes the popover background notes above).** `NSPopover` was replaced because its chrome is system-drawn and its material cannot be set. `StatusItemController` now owns a `MenuPanel: NSPanel` - borderless, `.nonactivatingPanel`, `isFloatingPanel`, `level = .popUpMenu`, `collectionBehavior = [.transient, .ignoresCycle]`, `hidesOnDeactivate`, non-opaque with a clear background and a shadow - whose contentView is an `NSVisualEffectView` with `material = .menu` and `blendingMode = .behindWindow`, the material family the system uses for the menu bar itself. The effect view has a 12 pt corner radius and hosts the SwiftUI `ContentView` with the same environment objects and tint, sized from the measured content (600x99). Because the material samples what is behind the window, the popover merges with the menu bar and follows the wallpaper and appearance automatically.

The popover content deliberately paints **no background of its own**: the old `.vizGlassSurface(cornerRadius: 0, tint: VizTheme.surfaceTint)` on the popover root is gone, so the panel material is what the user sees. The classic tint still lives on the settings, history, about and preview surfaces and on the cards. Dismissal is reimplemented now that `NSPopover.behavior = .transient` is gone: the controller observes `NSWindow.didResignKeyNotification` for the panel and `NSApplication.didResignActiveNotification`, the panel subclass closes itself on Esc through `cancelOperation`, and a second left click toggles it closed. `panelFrame(for:)` centres the panel under the status button and clamps it into the screen's visible frame (measured 624,819 600x99 inside a 0,61 1470x861 visible frame). The right-click Settings…/Quit menu, the status icon's update-state symbol, the hotkeys and every capture flow are unchanged.

In the design-check section the popover's `surface` and `translucency` entries are **replaced**: with a transparent content they only measured the harness backdrop. A new **`statuspanel`** check asserts the panel structurally (exists at 600x99, borderless and non-activating, not opaque, pop-up menu level, contentView is an `NSVisualEffectView` with the `.menu` material and behind-window blending, frame inside the visible frame, left click opens it and a resign-key notification dismisses it), and a new **`popovercontent`** check renders the content over the dark and the light backdrop and requires each render's dominant colour to equal that backdrop within 3 per channel - a content-owned surface shifts the light render by about 15, so it fails. `translucency` now covers the four remaining surfaces (settings 186/185/190, history 105/103/106, about 105/103/106, preview 97/97/100) and the popover keeps its `nonblank`, `buttons` and `hintbright` entries, which still measure the drawn content.

**The app owns its status item, and the settings are a flat list (supersedes the popover and settings notes above).** `Viz/VizApp.swift` no longer uses a `MenuBarExtra` scene: a `StatusItemController` creates an `NSStatusItem` whose button sends its action on both mouse-up kinds, so a **left click toggles a transient popover** hosting `ContentView` and a **right click shows a menu with Settings… and Quit**. The status symbol follows the update state (`arrow.down.circle` when a release is available, otherwise `eye`), the hotkey registrations and the app-support setup are untouched, and `openAppSettings` still opens the settings window for its other callers. The popover lost its whole header (both bubbles), so it now contains only the five actions and their shortcut pills and measures **600x99** - 46 pt shorter than the 145 pt of the previous plan, with the harness ceiling lowered to **109 pt** (measured + 10). The actions close the popover through `StatusItemController.closePopover()` now that there is no menu bar window to dismiss.

The settings window is a **flat list**: the tinted glass root and the per-section cards are gone (the window's own material is the only background), `SettingsSection` is just a small grey 11 pt label over its rows, and every row has a leading accent-tinted SF Symbol in a fixed column (globe, textformat, square.stack, text.alignleft, macwindow, speaker.slash, terminal, power, arrow.up.left.and.arrow.down.right, viewfinder, camera, eyedropper, clock, trash, arrow.down.circle). Titles stay 13 pt primary with 11 pt grey subtitles, rows are separated by dividers, and the tab strip, selection styling, every `@AppStorage` key, the pickers, steppers, recorders, the post-processing editor and the updater views are unchanged. The window widened from 520 to **560 pt** (exactly the compactness ceiling) because the glyph column pushed the widest tab's fitting width to 552.

In the design-check section: a new **`statusmenu`** check asserts the status item, its button action, the both-mouse-up mask, the Settings…/Quit menu, the click routing and the update-state symbol - and it drives the routing with `recordsPresentationOnly` set, because `NSMenu.popUp` starts real menu tracking and would block the harness. The popover design surface is rendered at the popover's real measured height, the `success` metric is retired with the header it measured (the green update bubble is gone; the update indicator now lives in the template status icon, and `VizTheme.success` still marks the History copy confirmation), and the icon band detection needed no change - it derives the band from the topmost ink run and the widest label run, which is now the button row to label row span (heights 99/93/87/81, ink 89 each).

**The `success` check is deterministic.** It no longer depends on the live update state. The popover's update-available flag used to be inherited from a real `Updater` hitting the GitHub API, so the green bubble - and the metric - only rendered when a release newer than the app existed; upstream's latest release equals this app's version, and in a sandbox without API access the Updater answers 403, so the metric measured 0 and the suite failed non-deterministically. `renderSurface` now takes an explicit `updateAvailable` parameter and sets `AppServices.shared.updater.updateAvailable` before rendering: the design loop renders the popover with the state **on** (the case `success` asserts, currently `success=2408`) and a second render with it **off** reports `popover-neutral success-off=0` and is asserted to stay below the 40-pixel threshold, so the metric cannot pass vacuously. Repeated runs now produce identical numbers. The neutral render is written to `design-popover-dark-neutral.png`.

**No in-UI branding, every surface glass (supersedes the branding notes above).** The app carries no branding in its interface any more: the popover's `V I Z` wordmark and the About window's icon/app-name block are gone (`VizTheme.brandGradient` with them), while the bundle's app icon, the menu bar symbol, the version/build line, the repository link and the attribution line all stay. The popover header now holds only the settings/update bubble and the quit bubble, right-aligned, and the popover still measures **145 pt** with the **155 pt** ceiling (measured + 10 pt margin). Every surface goes through the theme's glass helpers: the shortcut pills are capsule glass on macOS 26+ (material-plus-border fallback below), the settings tab-strip selection is a glass surface instead of a flat `Color.primary.opacity(0.12)` fill, and the preview panels no longer stack AlinFoundation's `.material(.sidebar)` on top of their glass — that material made them render opaque, which the new per-surface translucency check caught. The only remaining material/opacity uses in `Viz/` are the theme helpers' own fallback branches, stroke borders and dividers.

In the design-check section: the **`brand`** assertion was retired with the wordmark (its intent is carried by the translucency proof below), and **`translucency`** now covers **all five surfaces** — popover, settings, history, about and preview — each rendered over a dark and a bright backdrop with a required per-channel difference of at least 6. Measured deltas: 105/103/106 for popover, settings, history and about, and 97/97/100 for preview; an opaque surface renders identically and fails with delta 0.

**Glass-first surfaces and the second popover trim (supersede the numbers above).** The surface tints were lightened so the backgrounds read as glass rather than as filled panels: `VizTheme.surfaceTint` is now the original colour at **0.15** on window and popover roots and `VizTheme.cardTint` at **0.20** on cards, rows and panels, so cards stay a step more defined than the window while the material and the desktop show through. The glass/material path is unchanged for both macOS 26+ and the fallback. The popover's natural height is now **145 pt** (it was 161, originally 177) with the ceiling lowered to **155 pt**, and the icon check derives its four test heights from the measured natural height (`natural, -6, -12, -18`, currently 145/139/133/127) instead of hard-coding them, so they keep squeezing as the popover changes.

Two check changes go with it:

- The **`surface`** cast window is recalibrated to **1...14**, justified by the measurements: a neutral material surface gives 0, the light tints measure 2 (popover-light) to 7 (settings-dark), and the opaque `#313443` measures 21 (16 on the settings surface) — so flat paint fails on the high side and a colourless surface fails on the low side. (This supersedes the 4...15 window quoted above.)
- A new **`translucency`** check renders the popover and settings surfaces over a dark and a bright backdrop and requires the dominant surface colour to differ by at least 6 counts per channel; the backdrops are part of the rendered view hierarchy, because a material samples what is behind it inside the same tree (a detached view renders it flat). Measured: dark 37,39,44 versus bright 142,142,150, deltas 105/103/106; an opaque surface renders identically and fails with delta 0. `scripts/render-check.sh` runs it in the full suite, and it participates in the non-zero exit.
