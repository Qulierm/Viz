#!/usr/bin/env bash
#
# Fetch the pinned llama.cpp runtime that the optional OvisOCR2 recognition engine shells
# out to. The runtime is MIT licensed and is fetched into build/ (gitignored), never
# committed; scripts/build-app.sh copies the binary and its licence into the app bundle.
#
# Everything is pinned: the release tag and the SHA-256 of the asset. The download is
# verified before it is unpacked, and a mismatch fails loudly instead of leaving a runtime
# that might not be the one we tested.
#
# Usage: bash scripts/fetch-runtime.sh [--force]
set -euo pipefail

# --- pinned values ---------------------------------------------------------------
# llama.cpp build 11160 (release tag b11160). Verified on this machine: `llama-mtmd-cli
# --version` reports "version: 0.5.0-dev (build 11160, commit 70c4e1582)" and it loads the
# OvisOCR2 Q4_K_M weights with the f16 vision projector.
LLAMA_TAG="b11160"
LLAMA_ASSET="llama-${LLAMA_TAG}-bin-macos-arm64.tar.gz"
LLAMA_SHA256="5679b3e952772a9f9a39f9d42d7f0eb3d4c424103fe56f5516507583a0c6e3fa"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${LLAMA_ASSET}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT/build/runtime"
DEST="$RUNTIME_DIR/${LLAMA_TAG}"
BIN="$DEST/llama-mtmd-cli"

force=0
[[ "${1:-}" == "--force" ]] && force=1

mkdir -p "$RUNTIME_DIR"

# The runtime is MIT licensed, so its licence text travels with it into the bundle.
LICENCE="$RUNTIME_DIR/LICENSE-llama.cpp"
if [[ ! -s "$LICENCE" ]]; then
  echo "==> Fetching the llama.cpp licence"
  curl -sSL --fail -o "$LICENCE" "https://raw.githubusercontent.com/ggml-org/llama.cpp/${LLAMA_TAG}/LICENSE" \
    || echo "warning: could not fetch the llama.cpp licence text" >&2
fi

if [[ -x "$BIN" && $force -eq 0 ]]; then
  echo "==> llama.cpp runtime already present: $BIN"
  "$BIN" --version | head -1
  exit 0
fi

if [[ ! -f "$RUNTIME_DIR/$LLAMA_ASSET" || $force -eq 1 ]]; then
  echo "==> Downloading $LLAMA_ASSET"
  curl -sSL --fail -o "$RUNTIME_DIR/$LLAMA_ASSET" "$LLAMA_URL"
fi

echo "==> Verifying the asset checksum"
actual="$(shasum -a 256 "$RUNTIME_DIR/$LLAMA_ASSET" | awk '{print $1}')"
if [[ "$actual" != "$LLAMA_SHA256" ]]; then
  echo "error: checksum mismatch for $LLAMA_ASSET" >&2
  echo "  expected $LLAMA_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

echo "==> Unpacking into $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$RUNTIME_DIR/$LLAMA_ASSET" -C "$DEST" --strip-components=1

if [[ ! -x "$BIN" ]]; then
  echo "error: expected $BIN after unpacking" >&2
  exit 1
fi

echo "==> Runtime ready"
"$BIN" --version | head -1
