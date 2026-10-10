#!/bin/zsh
# build.sh — build, bundle, sign, and install Kept.app.
#
# Signs with the first "Developer ID Application" identity in the keychain,
# so a local build carries the same identity as a release: Full Disk Access
# and the keychain item that seals the backup folder carry over between the
# two, and nothing has to be granted again when you switch. A local build is
# never notarized and doesn't need to be: macOS only checks notarization on
# files downloaded from the internet.
#
# Without a Developer ID it falls back to the self-signed "Kept Dev" identity,
# which keeps TCC grants stable across rebuilds (ad-hoc signing would change
# every build and force a re-grant). Create it once with:
#   ./make-cert.sh
#
# KEPT_SIGN_IDENTITY picks an identity by name and never falls back; "-" signs
# ad-hoc on purpose, which is what CI does. release.sh
# sets it, sets KEPT_RELEASE=1 for Apple's secure timestamp and to leave out the
# review tools, sets KEPT_REQUIRE_PROFILE=1, and passes --no-install.
#
# With a Developer ID, put its provisioning profile at app/Kept.provisionprofile
# (or name one in KEPT_PROVISIONING_PROFILE). It's what lets Kept keep the key
# that seals the backup folder setting in the data-protection keychain, where
# nothing but Kept's team can plant or read it (see SettingsSeal.swift).
# Without one, Kept uses the login keychain.
#
# Options:
#   --force       install even while a backup is running
#   --no-install  build and sign .build/Kept.app, leave /Applications alone
#   --debug       a debug build a debugger can attach to (see below)
#
# KEPT_INSTALL_TO installs somewhere other than /Applications/Kept.app, such as
# ~/Applications/Kept.app, so a build of your own doesn't replace the Kept you
# use for your backups. Only one Kept runs at a time, though: opening either
# copy quits the other (SingleInstance), and they share settings and state.
set -euo pipefail

APP_DIR="${0:A:h}"
DEVELOPER_ID="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
IDENTITY="${KEPT_SIGN_IDENTITY:-${DEVELOPER_ID:-Kept Dev}}"
BUNDLE="$APP_DIR/.build/Kept.app"
INSTALL_TO="${KEPT_INSTALL_TO:-/Applications/Kept.app}"
LOCK_FILE="$HOME/Library/Application Support/Kept/.backup.pid"

FORCE=0
INSTALL=1
CONFIG=release
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --no-install) INSTALL=0 ;;
        --debug) CONFIG=debug ;;
        *) echo "!!  Unknown option: $arg"; exit 2 ;;
    esac
done
if [[ $CONFIG == debug && "${KEPT_RELEASE:-0}" == 1 ]]; then
    echo "!!  A release can't be a debug build."
    exit 2
fi

# The install step deletes whatever is at INSTALL_TO before copying, so a
# mistyped KEPT_INSTALL_TO must never name something that isn't a Kept.
if [[ $INSTALL -eq 1 ]]; then
    if [[ "$INSTALL_TO" != /*.app || "$INSTALL_TO" == *"/../"* ]]; then
        echo "!!  KEPT_INSTALL_TO must be an absolute path to a .app: $INSTALL_TO"
        exit 2
    fi
    if [[ -e "$INSTALL_TO" ]]; then
        EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
            "$INSTALL_TO/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$EXISTING_ID" != "com.chipcressman.Kept" ]]; then
            echo "!!  $INSTALL_TO isn't a Kept app; not replacing it."
            exit 2
        fi
    fi
fi

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

# The review tools in Settings → Advanced (forced panel states, sample alerts
# and notifications) are for whoever is working on Kept: in every local
# build, never in a release.
SWIFT_FLAGS=()
if [[ "${KEPT_RELEASE:-0}" != 1 ]]; then
    SWIFT_FLAGS=(-Xswiftc -DKEPT_REVIEW_TOOLS)
fi
echo "==> swift build -c $CONFIG ${SWIFT_FLAGS[*]}"
swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"

# Apple silicon only. macOS 26, the minimum, still runs on Intel Macs, but the
# bundled Python is arm64 — so a build that came out any other way is a broken
# build, and should stop here rather than ship.
ARCHS="$(lipo -archs "$APP_DIR/.build/$CONFIG/Kept")"
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
cp "$APP_DIR/.build/$CONFIG/Kept" "$BUNDLE/Contents/MacOS/Kept"
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
#
# A debug build skips it: it only makes osxphotos start faster.
find "$BUNDLE/Contents/Resources/python" -name '__pycache__' -type d -prune -exec rm -rf {} +
if [[ $CONFIG == release ]]; then
    echo "==> Precompiling bytecode"
    "$BUNDLE/Contents/Resources/python/bin/python3" -I -W ignore::SyntaxWarning -m compileall -q -f -j 0 \
        --invalidation-mode unchecked-hash "$BUNDLE/Contents/Resources/python/lib" >/dev/null \
        || echo "    (some modules didn't compile; Python reads those from source)"
fi

SIGN_ID="-"
if [[ "$IDENTITY" == "-" ]]; then
    # Asked for: CI has no signing identity, and its build is thrown away.
    echo "==> Signing ad-hoc"
elif security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
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

# The keychain entitlement. A Developer ID app may only claim its application
# identifier when a provisioning profile that grants it is embedded; claimed
# without one, macOS refuses to launch the app. So the profile's own values are
# used, after checking they're for this app and this team, and the build
# fails rather than ship an app that won't open.
PROFILE="${KEPT_PROVISIONING_PROFILE:-$APP_DIR/Kept.provisionprofile}"
SIGN_TMP="$(mktemp -d -t kept-sign)"
trap 'rm -rf "$SIGN_TMP"' EXIT
APP_ENTITLEMENTS="$SIGN_TMP/app-entitlements.plist"
cp "$APP_DIR/app-entitlements.plist" "$APP_ENTITLEMENTS"
rm -f "$BUNDLE/Contents/embedded.provisionprofile"
if [[ "$SIGN_ID" == "Developer ID Application:"* && -f "$PROFILE" ]]; then
    PROFILE_PLIST="$SIGN_TMP/profile.plist"
    security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
    APP_ID="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$PROFILE_PLIST")"
    TEAM_ID="$(plutil -extract 'Entitlements.com\.apple\.developer\.team-identifier' raw -o - "$PROFILE_PLIST")"
    EXPIRES="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$BUNDLE/Contents/Info.plist")"
    if [[ "$APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]]; then
        echo "!!  $PROFILE is for $APP_ID, not $TEAM_ID.$BUNDLE_ID."
        exit 1
    fi
    if [[ "$SIGN_ID" != *"($TEAM_ID)" ]]; then
        echo "!!  $PROFILE is for team $TEAM_ID, but the signing identity is '$SIGN_ID'."
        exit 1
    fi
    if [[ "$EXPIRES" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
        echo "!!  $PROFILE expired on $EXPIRES. Download a new one."
        exit 1
    fi
    cp "$PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
    plutil -insert 'com\.apple\.application-identifier' -string "$APP_ID" "$APP_ENTITLEMENTS"
    plutil -insert 'com\.apple\.developer\.team-identifier' -string "$TEAM_ID" "$APP_ENTITLEMENTS"
    echo "==> Keychain: data protection ($APP_ID, profile expires ${EXPIRES%%T*})"
elif [[ "${KEPT_REQUIRE_PROFILE:-0}" == 1 ]]; then
    echo "!!  No provisioning profile at $PROFILE. A release needs one: without it,"
    echo "!!  the key that seals the backup folder stays in the login keychain."
    exit 1
else
    echo "==> Keychain: login (no provisioning profile)"
fi

# The hardened runtime refuses a debugger unless the app allows one. A debug
# build does, so Xcode's Debug → Attach to Process and lldb can reach it; the
# profile is kept, so it reads the same keychain item as the Kept you use and
# doesn't ask for the backup folder again (which would break that copy's seal).
if [[ $CONFIG == debug ]]; then
    plutil -insert 'com\.apple\.security\.get-task-allow' -bool true "$APP_ENTITLEMENTS"
    echo "==> Debug build: a debugger can attach"
fi

# Notarization requires a secure timestamp from Apple on every signature.
# Local builds skip it, Developer ID ones included: it is a network round trip
# per file, the bundled Python has hundreds of them, and a build that isn't
# being notarized gains nothing from it. release.sh asks for it.
TIMESTAMP=(--timestamp=none)
if [[ "${KEPT_RELEASE:-0}" == 1 ]]; then
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
    --entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_ID" "$BUNDLE"

echo "==> Verifying signature and hardened-runtime flag"
codesign --verify --deep --strict "$BUNDLE"
# Captured rather than piped to grep: `grep -q` exits on first match, SIGPIPEs
# codesign, and `set -o pipefail` then reports the whole check as failed.
# An ad-hoc signature reports flags=0x10002(adhoc,runtime), so the match is on
# "runtime" among the flags rather than on one exact value.
SIG_INFO="$(codesign -d --verbose=2 "$BUNDLE" 2>&1)"
if [[ ! "$SIG_INFO" =~ 'flags=0x[0-9a-f]+\([^)]*runtime' ]]; then
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
