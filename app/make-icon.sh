#!/bin/zsh
# make-icon.sh — build Kept.icns from the design artwork in icon/.
#
# Produces app/.build/Kept.icns (cached; pass --refresh to rebuild).
# build.sh copies it into the bundle at Contents/Resources/.
#
# --asset-catalog also writes the same sizes into the Xcode project's asset
# catalog, Sources/Kept/Assets.xcassets/AppIcon.appiconset, which is committed.
# Run it after changing the artwork, so both builds show the same icon.
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

ASSET_CATALOG=""
for arg in "$@"; do
    case "$arg" in
        --refresh) rm -f "$OUT" ;;
        --asset-catalog) ASSET_CATALOG="$APP_DIR/Sources/Kept/Assets.xcassets" ;;
        *) echo "!!  Unknown option: $arg"; exit 2 ;;
    esac
done
if [[ -z "$ASSET_CATALOG" && -f "$OUT" && "$OUT" -nt "$SOURCE" ]]; then
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

if [[ -n "$ASSET_CATALOG" ]]; then
    SET="$ASSET_CATALOG/AppIcon.appiconset"
    rm -rf "$SET"
    mkdir -p "$SET"
    cp "$ICONSET"/icon_*.png "$SET/"
    cat > "$ASSET_CATALOG/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
    {
        echo '{'
        echo '  "images" : ['
        first=1
        for name in 16x16 32x32 128x128 256x256 512x512; do
            for scale in 1x 2x; do
                suffix=""
                if [[ $scale == 2x ]]; then suffix="@2x"; fi
                file="icon_${name}${suffix}.png"
                [[ $first -eq 1 ]] || echo '    },'
                first=0
                echo '    {'
                echo "      \"filename\" : \"$file\","
                echo '      "idiom" : "mac",'
                echo "      \"scale\" : \"$scale\","
                echo "      \"size\" : \"$name\""
            done
        done
        echo '    }'
        echo '  ],'
        echo '  "info" : {'
        echo '    "author" : "xcode",'
        echo '    "version" : 1'
        echo '  }'
        echo '}'
    } > "$SET/Contents.json"
    echo "==> Asset catalog: $SET"
fi
