#!/bin/zsh
# bundle-python.sh — build the relocatable Python + osxphotos environment that
# gets shipped inside Kept.app, so users don't install anything.
#
# Produces app/.build/python-env/ (cached; pass --refresh to rebuild).
# Installs from python-requirements.lock; --unlocked resolves afresh instead.
# build.sh copies it into the bundle at Contents/Resources/python/.
set -euo pipefail
setopt null_glob

APP_DIR="${0:A:h}"
ENV_DIR="$APP_DIR/.build/python-env"

# Pinned versions: Python matches the interpreter osxphotos was validated
# against on this machine; osxphotos matches the version the nightly backup
# has been running.
PBS_TAG="20260718"
PBS_ASSET="cpython-3.13.14+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_ASSET}"
# From the release's SHA256SUMS. Checked before the archive is unpacked: the
# interpreter ends up running with Kept's Full Disk Access.
PBS_SHA256="dca7c3bac21f023cf294705b27f4f3e9c70399c40790ebb81e8d0eff15b00770"
OSXPHOTOS_VERSION="0.76.1"
# Every package, osxphotos' dependencies included, pinned with hashes. Without
# it `pip install osxphotos==…` resolved ~75 dependencies to whatever was newest
# on the day, so any one of them publishing a bad release would have shipped,
# signed, inside Kept. Regenerate with gen-python-lock.py.
LOCK_FILE="$APP_DIR/python-requirements.lock"

UNLOCKED=0
for arg in "$@"; do
    case "$arg" in
        --refresh) rm -rf "$ENV_DIR" ;;
        # Resolve fresh, to move dependencies forward; then re-lock.
        --unlocked) UNLOCKED=1 ;;
        *) echo "!!  Unknown option: $arg"; exit 2 ;;
    esac
done
if [[ -x "$ENV_DIR/bin/python3" ]]; then
    echo "==> Cached python env exists ($ENV_DIR); skipping. Use --refresh to rebuild."
    exit 0
fi

mkdir -p "$APP_DIR/.build"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading $PBS_ASSET"
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/python.tar.gz" "$PBS_URL"
ACTUAL_SHA256="$(shasum -a 256 "$TMP/python.tar.gz" | cut -d' ' -f1)"
if [[ "$ACTUAL_SHA256" != "$PBS_SHA256" ]]; then
    echo "!!  Checksum mismatch for $PBS_ASSET"
    echo "!!    expected $PBS_SHA256"
    echo "!!    got      $ACTUAL_SHA256"
    exit 1
fi
tar -xzf "$TMP/python.tar.gz" -C "$TMP"   # extracts to $TMP/python

if [[ $UNLOCKED -eq 1 ]]; then
    echo "==> Installing osxphotos==$OSXPHOTOS_VERSION (UNLOCKED — re-run gen-python-lock.py after testing)"
    "$TMP/python/bin/python3" -m pip install --quiet --no-warn-script-location \
        "osxphotos==$OSXPHOTOS_VERSION"
else
    echo "==> Installing locked packages (osxphotos==$OSXPHOTOS_VERSION)"
    "$TMP/python/bin/python3" -m pip install --quiet --no-warn-script-location \
        --require-hashes --no-deps -r "$LOCK_FILE"
fi

echo "==> Pruning"
PYLIB="$TMP/python/lib/python3.13"
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/tkinter" "$PYLIB/turtledemo"
rm -rf "$PYLIB/site-packages/pip" "$PYLIB/site-packages/setuptools" \
       "$PYLIB/site-packages/wheel" "$PYLIB/site-packages"/pip-* \
       "$PYLIB/site-packages"/setuptools-* "$PYLIB/site-packages"/wheel-*
find "$TMP/python" -name '__pycache__' -type d -prune -exec rm -rf {} +
# pip console scripts have hardcoded shebangs; the app uses `python3 -m osxphotos`
rm -f "$TMP/python/bin/osxphotos"

echo "==> Smoke test: python3 -m osxphotos --version"
VERSION_OUT="$("$TMP/python/bin/python3" -m osxphotos --version 2>&1)"
echo "    $VERSION_OUT"
if [[ "$VERSION_OUT" != *"$OSXPHOTOS_VERSION"* ]]; then
    echo "!!  Smoke test failed: expected $OSXPHOTOS_VERSION"
    exit 1
fi

mv "$TMP/python" "$ENV_DIR"
echo "==> Done: $ENV_DIR ($(du -sh "$ENV_DIR" | cut -f1))"
