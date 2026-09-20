#!/usr/bin/env bash
#
# prepare-deps.sh - resolve the SwiftPM dependencies for the Xcode-free Viz build and
# apply the minimal patch that the Command Line Tools toolchain requires.
#
# Steps:
#   1. resolve AlinFoundation (pinned revision) and KeyboardShortcuts 2.4.0
#   2. strip the `#Preview { ... }` blocks from the KeyboardShortcuts checkout, because
#      they need Apple's PreviewsMacros compiler plugin, which only ships with Xcode
#
# The script is idempotent: re-running it after a successful patch is a no-op.
#
set -euo pipefail

# Resolve the repository root from this script's own location, so the script can be run
# from any working directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# SwiftPM needs a writable cache/config/security location. The defaults under
# ~/Library (org.swift.swiftpm, Caches/org.swift.swiftpm) are not writable in this
# environment, so all SwiftPM state is kept inside the repository build directory.
FLAGS=(
  --cache-path "$ROOT/build/swiftpm/cache"
  --config-path "$ROOT/build/swiftpm/config"
  --security-path "$ROOT/build/swiftpm/security"
  --scratch-path "$ROOT/.build"
)

# SwiftPM's manifest sandbox cannot be applied in this environment
# ("sandbox-exec: sandbox_apply: Operation not permitted"), so it is disabled by
# default. Set VIZ_SWIFTPM_SANDBOX=on in a normal terminal to keep the sandbox enabled.
if [[ "${VIZ_SWIFTPM_SANDBOX:-off}" != "on" ]]; then
  FLAGS+=(--disable-sandbox)
fi

echo "==> Resolving SwiftPM dependencies"
swift package resolve "${FLAGS[@]}"

RECORDER="$ROOT/.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift"
if [[ ! -f "$RECORDER" ]]; then
  echo "error: expected the KeyboardShortcuts checkout at $RECORDER" >&2
  echo "error: the dependency may have failed to resolve; check the output above" >&2
  exit 1
fi

if grep -q '^#Preview {' "$RECORDER"; then
  echo "==> Patching KeyboardShortcuts: removing the '#Preview { ... }' blocks"
  echo "    reason: those previews need Apple's PreviewsMacros plugin, which ships with"
  echo "    Xcode only; the block sits inside '#if os(macOS)', so it affects release too."

  # SwiftPM checkouts are read-only (mode 444), so make the file writable first.
  chmod u+w "$RECORDER"
  python3 - "$RECORDER" <<'PY'
import sys

# Delete everything from the first line starting with "#Preview {" up to, but not
# including, the following line whose trimmed content is "#endif".
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
else
  echo "==> KeyboardShortcuts already patched, skipping"
fi

# Fail loudly if the patch did not have the intended effect.
if grep -q '^#Preview {' "$RECORDER"; then
  echo "error: '#Preview {' is still present in $RECORDER" >&2
  exit 1
fi

echo "==> Dependencies ready"
