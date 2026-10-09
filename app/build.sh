#!/bin/zsh
# build.sh — build, bundle, sign, and install Kept.app.
#
# Signing uses the self-signed "Kept Dev" identity so the TCC grants
# survive rebuilds (an ad-hoc signature would change every build and
# force a re-grant). Create it once with:
#   ./make-cert.sh
#
# Release builds sign with a Developer ID instead: release.sh sets
# KEPT_SIGN_IDENTITY and passes --no-install.
#
# Options:
#   --force       install even while a backup is running
#   --no-install  build and sign .build/Kept.app, leave /Applications alone
set -euo pipefail

APP_DIR="${0:A:h}"
IDENTITY="${KEPT_SIGN_IDENTITY:-Kept Dev}"
BUNDLE="$APP_DIR/.build/Kept.app"
INSTALL_TO="/Applications/Kept.app"
LOCK_FILE="$HOME/Library/Application Support/Kept/.backup.pid"

FORCE=0
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --no-install) INSTALL=0 ;;
        *) echo "!!  Unknown option: $arg"; exit 2 ;;
    esac
done

cd "$APP_DIR"

# Installing quits the running copy, which orphans the osxphotos child; it then
# dies on its next write to the closed pipe. The run is lost partway through and
# leaves no record in runs.json, because a record is only appended when a run
# finishes. Checked before the build so this fails in a second, not after two
# minutes of signing.
if [[ $INSTALL -eq 1 && $FORCE -eq 0 && -f "$LOCK_FILE" ]]; then
    LOCK_PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    # The pid must still be Kept: a lock left by a crash names a pid that an
    # unrelated process may since have been given.
    LOCK_COMM="$(ps -p "$LOCK_PID" -o comm= 2>/dev/null || true)"
    if [[ -n "$LOCK_PID" && "${LOCK_COMM:t}" == "Kept" ]]; then
        echo "!!  A backup is running right now (pid $LOCK_PID)."
        echo "!!  Installing would quit Kept and kill it mid-export."
        echo "!!  Wait for it to finish, or re-run with --force to install anyway."
        exit 1
    fi
fi

echo "==> swift build -c release"
swift build -c release

# Apple silicon only. macOS 26, the minimum, still runs on Intel Macs, but the
# bundled Python is arm64 — so a build that came out any other way is a broken
# build, and should stop here rather than ship.
ARCHS="$(lipo -archs "$APP_DIR/.build/release/Kept")"
if [[ "$ARCHS" != "arm64" ]]; then
    echo "!!  Expected an arm64-only binary, got: $ARCHS"
    exit 1
fi

echo "==> Ensuring bundled python env"
"$APP_DIR/bundle-python.sh"

# Regenerated from the env that ships, with the env's own interpreter, so the
# notices in the app always match the packages in it.
echo "==> Regenerating third-party licenses"
"$APP_DIR/.build/python-env/bin/python3" "$APP_DIR/gen-licenses.py"

echo "==> Ensuring app icon"
"$APP_DIR/make-icon.sh"

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$APP_DIR/.build/release/Kept" "$BUNDLE/Contents/MacOS/Kept"
cp "$APP_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$APP_DIR/.build/Kept.icns" "$BUNDLE/Contents/Resources/Kept.icns"
ditto "$APP_DIR/.build/python-env" "$BUNDLE/Contents/Resources/python"
# Python, osxphotos and their dependencies ask for their notices to travel
# with any copy that is distributed.
cp "$APP_DIR/LICENSES.txt" "$BUNDLE/Contents/Resources/LICENSES.txt"

# Bytecode is compiled here, before signing, so it is sealed into the bundle
# with everything else. The app runs Python with -B and never writes any.
# Left to run time, Python wrote ~150 __pycache__ folders into the installed
# app, which then failed `codesign --verify` ("a sealed resource is missing or
# invalid"). unchecked-hash: the .pyc is trusted without comparing source
# mtimes, which a zip or a copy can change; the bundle seal is what keeps the
# sources and the bytecode honest.
echo "==> Precompiling bytecode"
find "$BUNDLE/Contents/Resources/python" -name '__pycache__' -type d -prune -exec rm -rf {} +
"$BUNDLE/Contents/Resources/python/bin/python3" -I -W ignore::SyntaxWarning -m compileall -q -f -j 0 \
    --invalidation-mode unchecked-hash "$BUNDLE/Contents/Resources/python/lib" >/dev/null \
    || echo "    (some modules didn't compile; Python reads those from source)"

SIGN_ID="-"
if security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
    SIGN_ID="$IDENTITY"
    echo "==> Signing with '$IDENTITY'"
elif [[ -n "${KEPT_SIGN_IDENTITY:-}" ]]; then
    # Asked for by name — a release must never quietly fall back to ad-hoc.
    echo "!!  Signing identity '$IDENTITY' not found in the keychain."
    exit 1
else
    echo "!!  '$IDENTITY' identity not found — signing ad-hoc."
    echo "!!  TCC grants will need re-consent after every rebuild until you run make-cert.sh."
fi

# Notarization requires a secure timestamp from Apple on every signature.
# Local builds skip it: it is a network round trip per file, and the bundled
# Python has hundreds of them.
TIMESTAMP=(--timestamp=none)
if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then
    TIMESTAMP=(--timestamp)
fi

# Everything is signed with the hardened runtime, innermost first. It blocks
# DYLD_* injection into the app, stops other processes attaching a debugger to
# it, and is a prerequisite for notarization.
#
# Entitlements are a process attribute, not a property of loaded libraries, so
# the library-validation relaxation goes ONLY on the interpreter that dlopens
# the bundled modules (see python-entitlements.plist). The Swift app links
# nothing outside /System and /usr/lib, so its own entitlements stay minimal
# (see app-entitlements.plist) and it keeps library validation fully enforced.
find "$BUNDLE/Contents/Resources/python" -type f \
    \( -name '*.so' -o -name '*.dylib' \) -print0 \
    | xargs -0 codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_ID"
# The interpreter's disable-library-validation exemption exists only because a
# self-signed certificate has no Team ID for library validation to match. A
# Developer ID signature gives every bundled library the interpreter's Team ID,
# so a release drops the exemption and keeps library validation on throughout.
PY_ENTITLEMENTS=(--entitlements "$APP_DIR/python-entitlements.plist")
if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then
    PY_ENTITLEMENTS=()
fi
find "$BUNDLE/Contents/Resources/python/bin" -type f -perm +111 -print0 \
    | xargs -0 codesign --force --options runtime "${TIMESTAMP[@]}" \
        "${PY_ENTITLEMENTS[@]}" --sign "$SIGN_ID"
codesign --force --options runtime "${TIMESTAMP[@]}" \
    --entitlements "$APP_DIR/app-entitlements.plist" --sign "$SIGN_ID" "$BUNDLE"

echo "==> Verifying signature and hardened-runtime flag"
codesign --verify --deep --strict "$BUNDLE"
# Captured rather than piped to grep: `grep -q` exits on first match, SIGPIPEs
# codesign, and `set -o pipefail` then reports the whole check as failed.
SIG_INFO="$(codesign -d --verbose=2 "$BUNDLE" 2>&1)"
if [[ "$SIG_INFO" != *"flags=0x10000(runtime)"* ]]; then
    echo "!!  Hardened runtime flag missing on $BUNDLE"
    exit 1
fi

# Runs the interpreter exactly as the app does, hardened and isolated. Placed
# before the install so a library-validation failure stops the build instead of
# surfacing during the unattended run at 2 AM.
echo "==> Smoke test: bundled osxphotos under the hardened runtime"
"$BUNDLE/Contents/Resources/python/bin/python3" -I -B -m osxphotos --version | head -1
# The smoke test runs the signed interpreter, so it is also the check that
# running it leaves the seal intact.
codesign --verify --deep --strict "$BUNDLE"

if [[ $INSTALL -eq 0 ]]; then
    echo "==> Built and signed $BUNDLE (not installed)"
    exit 0
fi

echo "==> Installing to $INSTALL_TO"
# Quit every running copy so the binary can be replaced cleanly. Every copy:
# the AppleScript quit can fail silently (it needs Automation permission for
# whatever runs this script), and on 2026-10-07 it did — the old copy kept
# running the previous code from memory beside the new one, and would have run
# that night's backup itself. So wait for them to go, and insist if they don't.
KEPT_EXE="$INSTALL_TO/Contents/MacOS/Kept"
osascript -e 'tell application "Kept" to quit' 2>/dev/null || true
for _ in {1..10}; do
    pgrep -f "$KEPT_EXE" >/dev/null 2>&1 || break
    sleep 1
done
if pgrep -f "$KEPT_EXE" >/dev/null 2>&1; then
    echo "==> Kept didn't quit when asked; terminating pid(s) $(pgrep -f "$KEPT_EXE" | tr '\n' ' ')"
    pkill -TERM -f "$KEPT_EXE" || true
    for _ in {1..10}; do
        pgrep -f "$KEPT_EXE" >/dev/null 2>&1 || break
        sleep 1
    done
fi
if pgrep -f "$KEPT_EXE" >/dev/null 2>&1; then
    echo "!!  Kept is still running (pid $(pgrep -f "$KEPT_EXE" | tr '\n' ' ')). Quit it, then re-run."
    exit 1
fi
rm -rf "$INSTALL_TO"
ditto "$BUNDLE" "$INSTALL_TO"

# Relaunch. This script quit a running copy to replace the binary, so leaving it
# down is this script's bug, not the user's to remember. Left down after an
# install on 2026-07-28, Kept missed that night's backup entirely and nothing
# said so — the panel can't report a failure when the app isn't running.
echo "==> Relaunching"
open "$INSTALL_TO"

# Verify it actually came up, rather than trusting `open`.
for _ in {1..10}; do
    sleep 1
    if pgrep -f "$INSTALL_TO/Contents/MacOS/Kept" >/dev/null 2>&1; then
        echo "==> Running (pid $(pgrep -f "$INSTALL_TO/Contents/MacOS/Kept" | head -1))"
        break
    fi
done
if ! pgrep -f "$INSTALL_TO/Contents/MacOS/Kept" >/dev/null 2>&1; then
    echo "!!  Kept did not start — launch it manually: open $INSTALL_TO"
    exit 1
fi
if [[ "$(pgrep -f "$INSTALL_TO/Contents/MacOS/Kept" | wc -l | tr -d ' ')" != "1" ]]; then
    echo "!!  More than one Kept is running: $(pgrep -f "$INSTALL_TO/Contents/MacOS/Kept" | tr '\n' ' ')"
    exit 1
fi

echo "==> Done. Use Settings → Advanced → Test Library Access to flush app-data re-consent."
echo "    A missed scheduled time will start a catch-up backup within seconds."
