#!/bin/bash
# Builds the prime-time badge animation from design/prime-time-source.webm: every frame
# in one WebP sprite sheet, shared by the macOS and Windows apps. The frame size, grid
# and frame rate must match PrimeTimeSprite (ExpandedView.swift) and `.burning-gauge`
# (windows/app/src/styles.css). Needs ffmpeg and cwebp (brew install ffmpeg webp).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/macos/design/prime-time-source.webm"
# 26 pt on screen at up to 3x; 196 frames at 24 fps fill a 14 × 14 grid.
FRAME=78 COLUMNS=14 ROWS=14 FPS=24

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# libvpx-vp9 keeps the alpha channel; ffmpeg's native VP9 decoder drops it.
ffmpeg -v error -c:v libvpx-vp9 -i "$SOURCE" \
    -vf "fps=$FPS,scale=$FRAME:$FRAME:flags=lanczos,tile=${COLUMNS}x$ROWS" \
    -frames:v 1 -pix_fmt rgba "$WORK/sheet.png"
cwebp -quiet -q 90 -alpha_q 100 -m 6 "$WORK/sheet.png" -o "$WORK/prime-time.webp"

cp "$WORK/prime-time.webp" "$ROOT/macos/Limita/Resources/prime-time.webp"
cp "$WORK/prime-time.webp" "$ROOT/windows/app/public/prime-time.webp"
echo "Wrote prime-time.webp ($(wc -c < "$WORK/prime-time.webp" | tr -d ' ') bytes) for macOS and Windows"
