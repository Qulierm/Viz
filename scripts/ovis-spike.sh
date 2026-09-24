#!/usr/bin/env bash
#
# Feasibility spike for the optional OvisOCR2 recognition engine: generate a reproducible
# test page, run the pinned llama.cpp runtime with the pinned model and vision projector,
# and report the produced Markdown with its wall-clock time and peak memory.
#
# This is the only script that needs the ~763 MB model download. It is never part of the
# normal build or of the render-check suite.
#
# Usage: bash scripts/ovis-spike.sh [--tokens N]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT/build/runtime/b11160/llama-mtmd-cli"
MODEL_DIR="${VIZ_MODEL_DIR:-$HOME/Library/Application Support/Viz/Models/OvisOCR2}"
MODEL="$MODEL_DIR/ATH-MaaS_OvisOCR2-Q4_K_M.gguf"
PROJECTOR="$MODEL_DIR/mmproj-ATH-MaaS_OvisOCR2-f16.gguf"
SPIKE="$ROOT/build/ovis-spike"

tokens=4096
[[ "${1:-}" == "--tokens" ]] && tokens="${2:?--tokens needs a value}"

for required in "$RUNTIME" "$MODEL" "$PROJECTOR"; do
  if [[ ! -e "$required" ]]; then
    echo "error: missing $required" >&2
    echo "  run scripts/fetch-runtime.sh and scripts/fetch-ovis-model.sh first" >&2
    exit 1
  fi
done

mkdir -p "$SPIKE"

# The prompt is the model card's own prompt, verbatim.
cat > "$SPIKE/prompt.txt" <<'PROMPT'
Extract all readable content from the image in natural human reading order and output the result as a single Markdown document. For charts or images, represent them using an HTML image tag: <img src="images/bbox_{left}_{top}_{right}_{bottom}.jpg" />, where left, top, right, bottom are bounding box coordinates scaled to [0, 1000). Format formulas as LaTeX. Format tables as HTML: <table>...</table>. Transcribe all other text as standard Markdown. Preserve the original text without translation or paraphrasing.
PROMPT

python3 - "$SPIKE/test-page.png" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1200, 900
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)

def font(size):
    for path in ["/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"]:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()

d.text((60, 50), "Quarterly Report", fill="black", font=font(44))
d.text((60, 130), "Revenue grew by 12% compared with the previous quarter, driven mainly", fill="black", font=font(24))
d.text((60, 165), "by strong demand in the northern region.", fill="black", font=font(24))

rows = [("Region", "Revenue", "Growth"),
        ("North", "1,240", "18%"),
        ("South", "980", "7%"),
        ("West", "1,510", "11%")]
for r, row in enumerate(rows):
    for c, cell in enumerate(row):
        x, y = 60 + c * 300, 240 + r * 55
        d.rectangle([x, y, x + 300, y + 55], outline="black", width=2)
        d.text((x + 15, y + 15), cell, fill="black", font=font(24))

d.text((60, 520), "Compound growth is computed as A = P(1 + r/n)^(nt).", fill="black", font=font(24))
d.text((60, 600), "Total revenue: 3,730", fill="black", font=font(24))
img.save(sys.argv[1])
print(f"==> test page written to {sys.argv[1]} ({W}x{H})")
PY

echo "==> Running the model (this takes seconds and about 4 GB of memory)"
echo "    $RUNTIME -m $MODEL --mmproj $PROJECTOR --image $SPIKE/test-page.png -f $SPIKE/prompt.txt -n $tokens --jinja -t 8"

/usr/bin/time -l "$RUNTIME" \
  -m "$MODEL" \
  --mmproj "$PROJECTOR" \
  --image "$SPIKE/test-page.png" \
  -f "$SPIKE/prompt.txt" \
  -n "$tokens" --jinja -t 8 > "$SPIKE/run.log" 2>&1 || true

python3 - "$SPIKE/run.log" "$SPIKE/out.md" <<'PY'
import sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
lines = raw.splitlines()
start = 0
for i, line in enumerate(lines):
    # The model's answer follows its thinking block; the CLI prints its own log lines before.
    if line.strip() in ("</think>", "<｜end▁of▁thinking｜>"):
        start = i + 1
end = len(lines)
for i in range(start, len(lines)):
    if "real" in lines[i] and "user" in lines[i]:
        end = i
        break
body = "\n".join(lines[start:end]).strip()
open(sys.argv[2], "w", encoding="utf-8").write(body + "\n")
print(f"==> Markdown written to {sys.argv[2]} ({len(body)} chars)")
print(body)
PY

echo "==> Timing and memory"
grep -E '^\s+[0-9.]+ real|maximum resident set size|peak memory footprint' "$SPIKE/run.log" | head -3
