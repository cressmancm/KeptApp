#!/bin/zsh
# release.sh — build a notarized, stapled Kept zip for distribution.
# The whole release checklist is in RELEASING.md at the top of the repository.
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   - its provisioning profile, saved as app/Kept.provisionprofile
#     (developer.apple.com → Profiles → + → Developer ID, for the App ID
#     com.chipcressman.Kept), so the release keeps its settings key in the
#     data-protection keychain
#   - notarization credentials saved under a keychain profile:
#       xcrun notarytool store-credentials "kept-notary" \
#           --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#
# Leaves dist/Kept-<version>.zip, ready to attach to a GitHub release. The copy
# installed in /Applications is not touched.
set -euo pipefail

APP_DIR="${0:A:h}"
PROFILE="${KEPT_NOTARY_PROFILE:-kept-notary}"
BUNDLE="$APP_DIR/.build/Kept.app"
DIST="$APP_DIR/dist"

# Found rather than typed: the identity's name embeds the team ID, and a typo
# would only surface after the whole build had run.
IDENTITY="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
if [[ -z "$IDENTITY" ]]; then
    echo "!!  No valid \"Developer ID Application\" identity in the keychain."
    echo "!!  Create one in Xcode → Settings → Accounts → Manage Certificates."
    exit 1
fi

# Checked before building, so a missing profile fails in seconds.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "!!  No working notarization profile \"$PROFILE\". Save one with:"
    echo "!!    xcrun notarytool store-credentials \"$PROFILE\" --apple-id … --team-id …"
    exit 1
fi

echo "==> Building with '$IDENTITY'"
KEPT_RELEASE=1 KEPT_REQUIRE_PROFILE=1 KEPT_SIGN_IDENTITY="$IDENTITY" \
    "$APP_DIR/build.sh" --no-install

# The packages that ship, checked against the lock. -B so the check can't
# write bytecode into the bundle it has just signed.
echo "==> Checking the bundled Python against the lock"
"$BUNDLE/Contents/Resources/python/bin/python3" -I -B \
    "$APP_DIR/check-python-lock.py" "$APP_DIR/python-requirements.lock"

PLIST="$BUNDLE/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
mkdir -p "$DIST"
UPLOAD="$DIST/Kept-$VERSION-upload.zip"
RESULT="$DIST/notarization-$VERSION.json"
ZIP="$DIST/Kept-$VERSION.zip"

# Apple's service takes a zip. The ticket it issues is stapled to the app
# itself, so Gatekeeper can check it offline, and the stapled app is zipped
# again for distribution.
echo "==> Submitting for notarization (usually a few minutes)"
ditto -c -k --keepParent "$BUNDLE" "$UPLOAD"
xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait \
    --output-format json > "$RESULT" || true
rm -f "$UPLOAD"
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)"
SUBMISSION="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "!!  Notarization status: $STATUS"
    # The log names every file Apple rejected, and why.
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE"
    exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$BUNDLE"
xcrun stapler validate "$BUNDLE"

echo "==> Gatekeeper check"
spctl --assess --type execute -vv "$BUNDLE"

# Without extended attributes. Plain `ditto -c -k` stores each file's
# attributes (macOS puts com.apple.provenance on every file) as a hidden ._
# entry in the zip, and an unzipper that can't turn one back into an
# attribute leaves it as a real file inside the signed app. Safari did that
# with the 8 symlinks in the bundled Python, and Kept 1.3 opened as
# "damaged". The app needs none of them: the signature and the stapled
# ticket are ordinary files in the bundle.
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$BUNDLE" "$ZIP"

# Prove it the way a download would meet it: unzipped by a tool that knows
# nothing about Mac attributes, then checked as Gatekeeper would.
echo "==> Checking the zip as a download"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
(cd "$CHECK" && unzip -q "$ZIP")
STRAY="$(find "$CHECK" -name '._*' | head -5)"
if [[ -n "$STRAY" ]]; then
    echo "!!  The zip holds ._ files, which break the signature once unzipped:"
    echo "$STRAY"
    exit 1
fi
codesign --verify --deep --strict "$CHECK/Kept.app"
spctl --assess --type execute -vv "$CHECK/Kept.app"

echo "==> Done: $ZIP (version $VERSION, build $BUILD)"
shasum -a 256 "$ZIP"
