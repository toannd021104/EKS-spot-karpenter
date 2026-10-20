#!/usr/bin/env bash
# Render a .pptx to PNG previews with LibreOffice inside Docker.
# Usage: bash presentation/render.sh [PPTX] [OUT_DIR]
#   PPTX    default: presentation/karpenter-spot-finops.pptx
#   OUT_DIR default: presentation/preview   (files slide-NN.png)
set -euo pipefail
IFS=$'\n\t'

DECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="finops-deck-render"
PPTX="${1:-$DECK_DIR/karpenter-spot-finops.pptx}"
OUT_DIR="${2:-$DECK_DIR/preview}"

[[ -f "$PPTX" ]] || { echo "[ERROR] not found: $PPTX" >&2; exit 3; }
command -v docker >/dev/null || { echo "[ERROR] docker is required" >&2; exit 3; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[INFO] building $IMAGE (first run takes a few minutes)" >&2
  docker build -t "$IMAGE" "$DECK_DIR/render" >&2
fi

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 777 "$WORK"
cp "$PPTX" "$WORK/deck.pptx"

docker run --rm --network none -v "$WORK:/work" "$IMAGE" bash -c \
  'set -e; export HOME=/tmp; soffice --headless --convert-to pdf --outdir /work /work/deck.pptx >/dev/null 2>&1; pdftoppm -r 80 -png /work/deck.pdf /work/slide'

rm -f "$OUT_DIR"/slide-*.png
shopt -s nullglob
n=0
for f in "$WORK"/slide-*.png; do
  base="$(basename "$f")"
  num="${base#slide-}"; num="${num%.png}"
  cp "$f" "$OUT_DIR/slide-$(printf '%02d' "$((10#$num))").png"
  n=$((n + 1))
done
echo "[INFO] wrote $n PNG(s) to $OUT_DIR" >&2
[[ $n -gt 0 ]] || exit 6
