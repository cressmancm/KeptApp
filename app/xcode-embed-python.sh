#!/bin/zsh
# xcode-embed-python.sh — the Xcode project's "Embed Python" build phase.
#
# Does for an Xcode build what build.sh does for its own: copies the bundled
# Python into Contents/Resources/python and signs every binary in it, before
# Xcode signs the app around it. Shipping builds don't come through here;
# build.sh and release.sh make those.
#
# Skips the copy and the signing when neither the Python nor the signing
# identity has changed since the last build, so an incremental build stays fast.
set -euo pipefail

APP_DIR="$SRCROOT"
ENV_DIR="$APP_DIR/.build/python-env"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/python"
# "-" when the target signs to run locally.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[[ -n "$IDENTITY" ]] || IDENTITY="-"

"$APP_DIR/bundle-python.sh"

# Kept's launcher for osxphotos, every build: it's Kept's own code, not the
# Python the stamp below covers.
mkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
cp "$APP_DIR/Python/kept_export.py" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/kept_export.py"

STAMP="$DEST/.kept-embedded"
# What the env was built from (bundle-python.sh's stamp: its own script and
# the package lock), not only the interpreter's date. The interpreter comes
# out of its archive with the same date every time, so a lock that moved a
# package forward rebuilt the env and left the old packages embedded here
# (production review W4).
INPUTS="$(cat "$APP_DIR/.build/python-env.inputs" 2>/dev/null || echo none)"
KEY="$(stat -f %m "$ENV_DIR/bin/python3") $INPUTS $IDENTITY $CONFIGURATION"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$KEY" ]]; then
    echo "Bundled Python is already embedded and signed."
    exit 0
fi

echo "Embedding the bundled Python"
rm -rf "$DEST"
ditto "$ENV_DIR" "$DEST"
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} +

# Precompiled only in Release, as build.sh does: it only makes osxphotos start
# faster, and the app runs Python with -B, so it never writes bytecode itself.
if [[ "$CONFIGURATION" == Release ]]; then
    "$DEST/bin/python3" -I -W ignore::SyntaxWarning -m compileall -q -f -j 0 \
        --invalidation-mode unchecked-hash "$DEST/lib" >/dev/null \
        || echo "Some modules didn't compile; Python reads those from source."
fi

# The notices travel with any copy, as in build.sh.
"$ENV_DIR/bin/python3" "$APP_DIR/gen-licenses.py" >/dev/null
cp "$APP_DIR/LICENSES.txt" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources/LICENSES.txt"

# Hardened runtime on everything. Without a team, nothing has a Team ID for
# library validation to match, so the interpreter gets the same exemption a
# "Kept Dev" build from build.sh gets (see python-entitlements.plist).
find "$DEST" -type f \( -name '*.so' -o -name '*.dylib' \) -print0 \
    | xargs -0 codesign --force --options runtime --timestamp=none --sign "$IDENTITY"
PY_ENTITLEMENTS=()
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    PY_ENTITLEMENTS=(--entitlements "$APP_DIR/python-entitlements.plist")
fi
find "$DEST/bin" -type f -perm +111 -print0 \
    | xargs -0 codesign --force --options runtime --timestamp=none \
        "${PY_ENTITLEMENTS[@]}" --sign "$IDENTITY"

echo "$KEY" > "$STAMP"
