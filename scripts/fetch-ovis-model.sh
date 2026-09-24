#!/usr/bin/env bash
#
# Download the optional OvisOCR2 recognition model (ATH-MaaS/OvisOCR2, Apache-2.0) and its
# vision projector from the pinned GGUF conversion. The weights are ~763 MB, so they are
# NEVER committed and never bundled: they live in the user's Application Support folder and
# the user downloads them explicitly (through this script or from the app's settings).
#
# Both files are pinned by repository revision and SHA-256; a mismatch deletes the file and
# fails. The script is idempotent: a file that is already present and correct is skipped.
#
# Usage: bash scripts/fetch-ovis-model.sh [--force]
set -euo pipefail

# --- pinned values ---------------------------------------------------------------
# bartowski/ATH-MaaS_OvisOCR2-GGUF at revision ab22420f3d44201d3aa5a62ca49a665a46b507e9,
# converted from ATH-MaaS/OvisOCR2 (repo sha 1fc9221b7823a371d6e97f92d527cc847e24e107).
GGUF_REPO="bartowski/ATH-MaaS_OvisOCR2-GGUF"
GGUF_REVISION="ab22420f3d44201d3aa5a62ca49a665a46b507e9"
BASE_URL="https://huggingface.co/${GGUF_REPO}/resolve/${GGUF_REVISION}"

MODEL_FILE="ATH-MaaS_OvisOCR2-Q4_K_M.gguf"
MODEL_BYTES="557867136"
MODEL_SHA256="3786d230ceb8f217abdfb8ea8adba975827595053ad5087cb5502898d6a8a68e"

PROJECTOR_FILE="mmproj-ATH-MaaS_OvisOCR2-f16.gguf"
PROJECTOR_BYTES="204987040"
PROJECTOR_SHA256="4e0e9cb9d79dd0f423ba152a51816aa82a1f1a9d1a0190b6f67b2cd4cc5dd681"

DEST="${VIZ_MODEL_DIR:-$HOME/Library/Application Support/Viz/Models/OvisOCR2}"

force=0
[[ "${1:-}" == "--force" ]] && force=1

mkdir -p "$DEST"

# fetch <file> <bytes> <sha256>
fetch() {
  local file="$1" bytes="$2" sha="$3"
  local path="$DEST/$file"

  if [[ -f "$path" && $force -eq 0 ]]; then
    local existing
    existing="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$existing" == "$sha" ]]; then
      echo "==> $file already present and verified, skipping"
      return 0
    fi
    echo "==> $file present but does not match the pinned checksum, re-downloading"
  fi

  echo "==> Downloading $file"
  # Written to a temporary file and moved into place, so an interrupted download never
  # leaves a partial file that looks installed.
  curl -sSL --fail -o "$path.part" "$BASE_URL/$file"

  local actual_bytes actual_sha
  actual_bytes="$(stat -f %z "$path.part")"
  if [[ "$actual_bytes" != "$bytes" ]]; then
    echo "error: $file has $actual_bytes bytes, expected $bytes" >&2
    rm -f "$path.part"
    exit 1
  fi

  actual_sha="$(shasum -a 256 "$path.part" | awk '{print $1}')"
  if [[ "$actual_sha" != "$sha" ]]; then
    echo "error: checksum mismatch for $file" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual_sha" >&2
    rm -f "$path.part"
    exit 1
  fi

  mv "$path.part" "$path"
  echo "==> $file verified ($actual_bytes bytes)"
}

fetch "$MODEL_FILE" "$MODEL_BYTES" "$MODEL_SHA256"
fetch "$PROJECTOR_FILE" "$PROJECTOR_BYTES" "$PROJECTOR_SHA256"

echo "==> Model ready in $DEST"
du -sh "$DEST"
