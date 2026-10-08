#!/bin/zsh
# make-cert.sh — one-time creation of the "Kept Dev" self-signed
# code-signing identity in the login keychain.
#
# TCC keys its Full Disk Access grant to the app's designated requirement;
# with a stable certificate that requirement doesn't change across rebuilds,
# so FDA only ever has to be granted once.
#
# May prompt for your login password (keychain import / trust settings).
# Needs no sudo: the trust it adds is this user's alone.
set -euo pipefail

NAME="Kept Dev"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "'$NAME' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed cert with the Code Signing EKU and a 10-year lifetime.
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"

# -legacy: OpenSSL 3 defaults to AES/PBMAC1 which `security import` cannot
# read; the legacy 3DES/SHA1 format is what Keychain understands. LibreSSL
# (no -legacy flag) writes that format by default, hence the fallback.
# The .p12 only lives for the length of this script, but its password is
# still random rather than a constant anyone reading this file would know.
P12_PASS="$(openssl rand -hex 24)"
openssl pkcs12 -export -legacy -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$P12_PASS" 2>/dev/null || \
openssl pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$P12_PASS"

# -x: the private key can't be exported from the keychain afterwards. Anyone
# holding it could sign code this Mac trusts as Kept's, and TCC grants Full
# Disk Access by that signature.
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12_PASS" -x -T /usr/bin/codesign

# Trust the cert for code signing, for this user only (this step may prompt).
# Not the System keychain's admin domain: a code-signing root trusted there is
# trusted for every account on the Mac, and only this one builds Kept.
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo "Created and trusted '$NAME'."
security find-identity -v -p codesigning | grep "$NAME"
