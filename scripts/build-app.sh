#!/usr/bin/env bash
#
# build-app.sh - build Viz with SwiftPM (no Xcode required) and package the result into
# an ad-hoc-signed, runnable build/Viz.app.
#
# The Viz.xcodeproj build path is untouched; this script only produces a headless
# bundle from the same sources.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------------------------------------------------------------------------
# Configuration (environment overrides)
# ---------------------------------------------------------------------------
VIZ_VERSION="${VIZ_VERSION:-2.3.3}"
VIZ_BUILD="${VIZ_BUILD:-18}"
VIZ_SIGN_IDENTITY="${VIZ_SIGN_IDENTITY:--}"   # "-" means ad-hoc signing
VIZ_INSTALL_DIR="${VIZ_INSTALL_DIR:-$HOME/Applications}"

CONFIGURATION="release"
DO_CLEAN=0
DO_INSTALL=0

APP="$ROOT/build/Viz.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
ICONSET_DIR="$ROOT/build/icon.iconset"

# Keys Xcode would otherwise inject through INFOPLIST_KEY_* / GENERATE_INFOPLIST_FILE.
# Format: "KEY TYPE VALUE".
INFO_KEYS=(
  "CFBundleDevelopmentRegion string en"
  "CFBundleDisplayName string Viz"
  "CFBundleExecutable string Viz"
  "CFBundleIconFile string Viz"
  "CFBundleIdentifier string com.alienator88.Viz"
  "CFBundleInfoDictionaryVersion string 6.0"
  "CFBundleName string Viz"
  "CFBundlePackageType string APPL"
  "CFBundleShortVersionString string $VIZ_VERSION"
  "CFBundleVersion string $VIZ_BUILD"
  "LSApplicationCategoryType string public.app-category.utilities"
  "LSMinimumSystemVersion string 13.0"
  "LSUIElement bool YES"
  "NSHighResolutionCapable bool YES"
)

# Keys that must be readable from the finished bundle.
REQUIRED_KEYS=(
  CFBundleExecutable
  CFBundleIdentifier
  CFBundleShortVersionString
  CFBundleVersion
  CFBundleIconFile
  CFBundlePackageType
  LSMinimumSystemVersion
  LSUIElement
  NSCameraUsageDescription
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: bash scripts/build-app.sh [options]

Builds Viz with SwiftPM (Command Line Tools only, no Xcode) and packages
build/Viz.app, ad-hoc signed by default.

Options:
  --debug            Build the Debug configuration instead of Release
  --clean            Remove build/ and .build/ before building
  --install          Copy the finished bundle to \$VIZ_INSTALL_DIR (default ~/Applications)
  --help             Show this help

Environment:
  VIZ_VERSION            Marketing version        (default 2.3.3)
  VIZ_BUILD              Build number             (default 18)
  VIZ_SIGN_IDENTITY      codesign identity        (default "-", ad-hoc)
  VIZ_INSTALL_DIR        --install destination    (default \$HOME/Applications)
  VIZ_SWIFTPM_SANDBOX    "on" re-enables the SwiftPM sandbox (default off)
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

preflight() {
  echo "==> Checking required tools"
  local tool
  for tool in swift python3 codesign plutil iconutil sips; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' was not found on PATH"
  done
  swift --version
}

clean_all() {
  echo "==> Cleaning build/ and .build/"
  rm -rf "$ROOT/build" "$ROOT/.build"
}

# SwiftPM flag array, identical to scripts/prepare-deps.sh.
swift_flags() {
  SWIFT_FLAGS=(
    --cache-path "$ROOT/build/swiftpm/cache"
    --config-path "$ROOT/build/swiftpm/config"
    --security-path "$ROOT/build/swiftpm/security"
    --scratch-path "$ROOT/.build"
  )
  # This environment cannot apply SwiftPM's manifest sandbox
  # ("sandbox-exec: sandbox_apply: Operation not permitted") and its ~/Library caches
  # are not writable, so the sandbox is off by default and every cache lives in-repo.
  if [[ "${VIZ_SWIFTPM_SANDBOX:-off}" != "on" ]]; then
    SWIFT_FLAGS+=(--disable-sandbox)
  fi
}

build_binary() {
  echo "==> Building Viz ($CONFIGURATION) with SwiftPM"
  swift_flags
  swift build -c "$CONFIGURATION" "${SWIFT_FLAGS[@]}"
  BINARY="$ROOT/.build/$CONFIGURATION/Viz"
  [[ -x "$BINARY" ]] || die "expected the built binary at $BINARY"
}

assemble_bundle() {
  echo "==> Assembling $APP"
  rm -rf "$APP"
  mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
  cp "$BINARY" "$MACOS_DIR/Viz"
  chmod +x "$MACOS_DIR/Viz"
}

copy_sound() {
  # NSSound(named: "water") only searches the main bundle's resources, so the sound
  # has to be copied next to the executable even though it is excluded from SwiftPM.
  echo "==> Copying water.mp3"
  cp "$ROOT/Viz/water.mp3" "$RESOURCES_DIR/water.mp3"
}

generate_icon() {
  # actool ships with Xcode only, so the asset catalog cannot be compiled here. The
  # iconset PNGs are converted to a plain .icns with iconutil instead.
  echo "==> Generating $RESOURCES_DIR/Viz.icns"
  local src="$ROOT/Viz/Assets.xcassets/AppIcon.appiconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  local name
  for name in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    [[ -f "$src/$name" ]] || die "missing icon source $src/$name"
    cp "$src/$name" "$ICONSET_DIR/$name"
  done

  if ! iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/Viz.icns"; then
    echo "warning: iconutil failed, falling back to sips for a single-resolution icns"
    sips -s format icns "$src/icon_512x512@2x.png" --out "$RESOURCES_DIR/Viz.icns"
  fi
}

# Set one Info.plist key, replacing any existing value.
# Falls back to PlistBuddy if `plutil -insert` is unavailable on this system.
plist_set() {
  local key="$1" type="$2" value="$3" plist="$4"
  plutil -remove "$key" "$plist" >/dev/null 2>&1 || true
  if ! plutil -insert "$key" "-$type" "$value" "$plist" >/dev/null 2>&1; then
    local pb_type="string"
    [[ "$type" == "bool" ]] && pb_type="bool"
    /usr/libexec/PlistBuddy -c "Add :$key $pb_type $value" "$plist" >/dev/null
  fi
}

write_info_plist() {
  # Start from the repository's Info.plist so NSCameraUsageDescription and
  # NSUbiquitousContainers stay single-sourced, then add every key Xcode would inject.
  echo "==> Writing Contents/Info.plist"
  cp "$ROOT/Viz/Info.plist" "$CONTENTS/Info.plist"
  local entry key type value
  for entry in "${INFO_KEYS[@]}"; do
    read -r key type value <<<"$entry"
    plist_set "$key" "$type" "$value" "$CONTENTS/Info.plist"
  done
}

sign_bundle() {
  # Viz/Viz.entitlements is deliberately NOT applied: its iCloud entitlements are
  # restricted, require a provisioning profile, and would make macOS kill the app at
  # launch when paired with an ad-hoc signature. Without them Viz still runs and falls
  # back to local history storage.
  echo "==> Signing with identity '$VIZ_SIGN_IDENTITY'"
  codesign --force --sign "$VIZ_SIGN_IDENTITY" "$APP"
}

self_check() {
  echo "==> Verifying the bundle"
  plutil -lint "$CONTENTS/Info.plist"

  local key value
  for key in "${REQUIRED_KEYS[@]}"; do
    value="$(plutil -extract "$key" raw -o - "$CONTENTS/Info.plist" 2>/dev/null || true)"
    [[ -n "$value" ]] || die "Info.plist key '$key' is missing or empty"
    echo "    $key = $value"
  done

  [[ -f "$RESOURCES_DIR/water.mp3" ]] || die "Contents/Resources/water.mp3 is missing"
  [[ -s "$RESOURCES_DIR/Viz.icns" ]] || die "Contents/Resources/Viz.icns is missing or empty"
  file "$MACOS_DIR/Viz"

  codesign --verify --verbose=2 "$APP" 2>&1
}

install_bundle() {
  echo "==> Installing to $VIZ_INSTALL_DIR"
  mkdir -p "$VIZ_INSTALL_DIR" || die "could not create $VIZ_INSTALL_DIR"
  rm -rf "$VIZ_INSTALL_DIR/Viz.app"
  ditto "$APP" "$VIZ_INSTALL_DIR/Viz.app"
  echo "==> Installed $VIZ_INSTALL_DIR/Viz.app"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)   CONFIGURATION="debug"; shift ;;
    --clean)   DO_CLEAN=1; shift ;;
    --install) DO_INSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown option '$1'" ;;
  esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
preflight
if [[ "$DO_CLEAN" == "1" ]]; then
  clean_all
fi

bash "$ROOT/scripts/prepare-deps.sh"
build_binary
assemble_bundle
copy_sound
generate_icon
write_info_plist
sign_bundle
self_check

echo "==> Bundle: $APP"
du -sh "$APP"

if [[ "$DO_INSTALL" == "1" ]]; then
  install_bundle
fi

echo "==> Done"
