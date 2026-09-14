#!/bin/zsh
# One-time setup for a stable code-signing identity.
#
# TCC permissions (Accessibility, Input Monitoring) are bound to the app's
# code-signing identity. Ad-hoc signatures change on every build, so those
# grants reset after every update. A fixed self-signed certificate gives the
# app a stable identity and permissions survive updates.
#
# This script:
#   1. creates a self-signed code-signing certificate "JMacTool Local" in the
#      login keychain (skipped if it already exists),
#   2. exports dist/JMacTool-signing.p12 (+ base64) for GitHub Actions secrets,
#   3. prints the follow-up steps.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="JMacTool Local"
P12_PASSWORD="jmactool"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DIST_DIR="$ROOT_DIR/dist"

mkdir -p "$DIST_DIR"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "Signing identity '$IDENTITY' already exists."
else
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  openssl req -x509 -newkey rsa:3072 \
    -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY"

  openssl pkcs12 -export \
    -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/identity.p12" -passout "pass:$P12_PASSWORD" -name "$IDENTITY"

  security import "$TMP_DIR/identity.p12" \
    -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign

  # Trust the self-signed certificate so codesign accepts it. macOS may ask
  # for the login password once to confirm the trust change.
  security add-trusted-cert -r trustRoot -k "$LOGIN_KEYCHAIN" "$TMP_DIR/cert.pem"

  echo "Created signing identity '$IDENTITY'."
fi

# Export the identity for GitHub Actions (base64 -> secret MACOS_SIGNING_P12).
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  openssl req -x509 -newkey rsa:3072 \
    -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" >/dev/null 2>&1
  openssl pkcs12 -export \
    -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
    -out "$DIST_DIR/JMacTool-signing.p12" -passout "pass:$P12_PASSWORD" -name "$IDENTITY"
  base64 -i "$DIST_DIR/JMacTool-signing.p12" -o "$DIST_DIR/JMacTool-signing.p12.base64"
  echo
  echo "Exported $DIST_DIR/JMacTool-signing.p12 (+ .base64)."
  echo "For CI-signed releases (permissions survive updates), add these GitHub"
  echo "repository secrets (Settings → Secrets and variables → Actions):"
  echo "  MACOS_SIGNING_P12      = contents of $DIST_DIR/JMacTool-signing.p12.base64"
  echo "  MACOS_SIGNING_PASSWORD = $P12_PASSWORD"
fi

echo
echo "Note: the FIRST install of a cert-signed build still needs its permissions"
echo "granted once; every later update keeps them."
