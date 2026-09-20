#!/usr/bin/env bash
#
# render-check.sh - build and run the objective UI behaviour checks for Viz.
#
# The harness compiles the application's real sources (everything under Viz/ except
# VizApp.swift, which carries @main) together with tools/render-check/*.swift inside a
# temporary SwiftPM package, then drives that code directly: it renders the popover at
# several heights and measures the button icons, it calls the app's own settings-window
# function and looks for the window it should create, and it writes to the clipboard
# and reads it back from a separate process.
#
# The repository is never modified. Rendered PNGs and logs are written to
# build/render-check/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${TMPDIR:-/tmp}/viz-render-check"
SCRATCH="$WORK/.build"
OUT_DIR="$ROOT/build/render-check"

echo "==> Preparing temporary harness package at $WORK"
rm -rf "$WORK"
mkdir -p "$WORK/Sources/RenderCheck"

# The harness package mirrors the repository manifest (same dependencies, same pins).
cat >"$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
// Temporary package created by scripts/render-check.sh - not part of the repository.
import PackageDescription

let package = Package(
    name: "RenderCheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/alienator88/AlinFoundation", revision: "f61241c2ea1856ef41cbfc965afe9d756121456f"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "RenderCheck",
            dependencies: [
                .product(name: "AlinFoundation", package: "AlinFoundation"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/RenderCheck"
        )
    ]
)
SWIFT

echo "==> Copying the application sources into the harness target"
# VizApp.swift declares @main, which an executable target cannot have twice, and the
# shortcut names it declares are reproduced in tools/render-check/ShortcutNames.swift.
cp "$ROOT/Viz/Styles.swift" "$ROOT/Viz/Logic/"*.swift "$ROOT/Viz/Views/"*.swift "$WORK/Sources/RenderCheck/"
cp "$ROOT/tools/render-check/"*.swift "$WORK/Sources/RenderCheck/"
echo "    $(ls "$WORK/Sources/RenderCheck" | wc -l | tr -d ' ') Swift files: $(ls "$WORK/Sources/RenderCheck" | tr '\n' ' ')"

# Same SwiftPM flags as scripts/prepare-deps.sh: in-repo caches, sandbox disabled unless
# VIZ_SWIFTPM_SANDBOX=on.
FLAGS=(
  --cache-path "$ROOT/build/swiftpm/cache"
  --config-path "$ROOT/build/swiftpm/config"
  --security-path "$ROOT/build/swiftpm/security"
  --scratch-path "$SCRATCH"
)
if [[ "${VIZ_SWIFTPM_SANDBOX:-off}" != "on" ]]; then
  FLAGS+=(--disable-sandbox)
fi

echo "==> Resolving harness dependencies"
# Resolution can fail when the network hiccups: SwiftPM then falls back to cached
# repository state and can leave a partial clone behind that makes the next attempt
# report "already exists in file system". Retry a couple of times after cleaning it.
attempt=1
while true; do
  if swift package --package-path "$WORK" resolve "${FLAGS[@]}"; then
    break
  fi
  if [[ "$attempt" -ge 3 ]]; then
    echo "error: dependency resolution failed after $attempt attempts" >&2
    exit 1
  fi
  echo "==> Resolution attempt $attempt failed, retrying after cleaning partial repositories"
  attempt=$((attempt + 1))
  rm -rf "$SCRATCH/repositories"
  sleep 2
done

# KeyboardShortcuts 2.4.0 ships '#Preview { ... }' blocks that need Apple's
# PreviewsMacros plugin, which only exists with Xcode. Same patch as prepare-deps.sh.
RECORDER="$SCRATCH/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift"
if [[ ! -f "$RECORDER" ]]; then
  echo "error: expected the KeyboardShortcuts checkout at $RECORDER" >&2
  exit 1
fi
if grep -q '^#Preview {' "$RECORDER"; then
  echo "==> Patching KeyboardShortcuts: removing the '#Preview { ... }' blocks"
  chmod u+w "$RECORDER"
  python3 - "$RECORDER" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

out = []
skipping = False
for line in lines:
    if not skipping and line.startswith("#Preview {"):
        skipping = True
        continue
    if skipping:
        if line.strip() == "#endif":
            skipping = False
            out.append(line)
        continue
    out.append(line)

if skipping:
    sys.stderr.write("error: unterminated #Preview block in %s\n" % path)
    sys.exit(1)

with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(out)
PY
fi
if grep -q '^#Preview {' "$RECORDER"; then
  echo "error: '#Preview {' is still present in $RECORDER" >&2
  exit 1
fi

echo "==> Building the harness (release)"
swift build --package-path "$WORK" -c release "${FLAGS[@]}"

echo "==> Running the checks"
mkdir -p "$OUT_DIR"
# The harness instantiates AlinFoundation's Updater, which creates the Application
# Support folder and other per-user state. CFFIXED_USER_HOME redirects those writes to a
# throwaway home inside the temporary work directory, so nothing outside the repository
# and $TMPDIR is touched. (HOME alone is not enough: Foundation resolves the real home.)
FAKE_HOME="$WORK/home"
rm -rf "$FAKE_HOME"
mkdir -p "$FAKE_HOME"
set +e
CFFIXED_USER_HOME="$FAKE_HOME" RENDER_CHECK_OUT="$OUT_DIR" "$SCRATCH/release/RenderCheck" 2>&1 | tee "$OUT_DIR/render-check.log"
STATUS=${PIPESTATUS[0]}
set -e

echo "==> RenderCheck exit code: $STATUS"
echo "==> Artefacts: $OUT_DIR"
exit "$STATUS"
