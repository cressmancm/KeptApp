#!/bin/zsh
# make-icon.sh — build Kept.icns from the design artwork in icon/.
#
# Produces app/.build/Kept.icns (cached; pass --refresh to rebuild).
# build.sh copies it into the bundle at Contents/Resources/.
#
# The artwork is full-bleed and deliberately carries no corner rounding, inset,
# or shadow: macOS 26 applies the squircle mask, the platform inset, and the
# drop shadow itself, even to a legacy .icns. Verified by rendering the bundle
# through NSWorkspace.icon(forFile:) — rounding it here would round it twice.
#
# Only the Default appearance ships this way. A .icns cannot carry the Dark,
# Clear, and Tinted variants; those need a .icon built in Icon Composer, which
# has no command-line interface. icon/ holds the layered artwork for that step.
set -euo pipefail

APP_DIR="${0:A:h}"
SOURCE="$APP_DIR/icon/kept-default.svg"
OUT="$APP_DIR/.build/Kept.icns"

if [[ "${1:-}" == "--refresh" ]]; then
    rm -f "$OUT"
fi
if [[ -f "$OUT" && "$OUT" -nt "$SOURCE" ]]; then
    echo "==> Cached icon exists ($OUT); skipping. Use --refresh to rebuild."
    exit 0
fi

[[ -f "$SOURCE" ]] || { echo "!!  Missing artwork: $SOURCE"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Rasterizing $(basename "$SOURCE")"
# Quick Look renders SVG including the <mask> that cuts the back frame where
# the front frame overlaps it; sips cannot read SVG at all.
qlmanage -t -s 1024 -o "$TMP" "$SOURCE" >/dev/null 2>&1
MASTER="$TMP/$(basename "$SOURCE").png"
[[ -f "$MASTER" ]] || { echo "!!  Quick Look produced no thumbnail for $SOURCE"; exit 1; }

WIDTH="$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2}')"
[[ "$WIDTH" == "1024" ]] || { echo "!!  Expected a 1024px render, got ${WIDTH}px"; exit 1; }

echo "==> Building iconset"
ICONSET="$TMP/Kept.iconset"
mkdir -p "$ICONSET"
while read -r size name; do
    [[ -z "$size" ]] && continue
    sips -s format png -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${name}.png" >/dev/null
done <<'SIZES'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SIZES

mkdir -p "$APP_DIR/.build"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "==> Done: $OUT ($(stat -f%z "$OUT") bytes)"
