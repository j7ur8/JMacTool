#!/bin/zsh
# One-time setup for a stable code-signing identity.
#
# TCC permissions (Accessibility, Input Monitoring) are bound to the app's
# code-signing identity. Ad-hoc signatures change on every build, so those
# grants reset after every update. A fixed self-signed certificate gives the
# app a stable identity and permissions survive updates.
#
# This script (idempotent, safe to re-run):
#   1. generates the "JMacTool Local" certificate once and stores the
#      material in ~/.jmactool-signing/,
#   2. imports it into the login keychain and marks it trusted,
#   3. refreshes dist/JMacTool-signing.p12 (+ .base64) for GitHub Actions
#      secrets, then prints the follow-up steps.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="JMacTool Local"
P12_PASSWORD="jmactool"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
STORE_DIR="$HOME/.jmactool-signing"
DIST_DIR="$ROOT_DIR/dist"

mkdir -p "$STORE_DIR" "$DIST_DIR"

# 1. Generate the certificate material once, then always reuse it so the
#    keychain identity and the CI p12 never drift apart.
if [ ! -f "$STORE_DIR/identity.p12" ]; then
  echo "Generating self-signed certificate '$IDENTITY'..."
  # macOS code-signing policy requires the certificate to carry the
  # codeSigning extended key usage; without it the identity shows up as
  # invalid ('0 valid identities found').
  cat > "$STORE_DIR/extensions.cnf" <<EXT
[req]
distinguished_name = dn
x509_extensions = v3_ext
[dn]
CN = $IDENTITY
[v3_ext]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage = codeSigning
EXT
  openssl req -x509 -newkey rsa:3072 \
    -keyout "$STORE_DIR/key.pem" -out "$STORE_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -config "$STORE_DIR/extensions.cnf"
  # macOS `security import` cannot read OpenSSL 3 defaults (AES/PBKDF2-SHA256);
  # export with legacy PBE algorithms it understands.
  if ! openssl pkcs12 -export -legacy \
      -inkey "$STORE_DIR/key.pem" -in "$STORE_DIR/cert.pem" \
      -out "$STORE_DIR/identity.p12" -passout "pass:$P12_PASSWORD" -name "$IDENTITY" 2>/dev/null; then
    openssl pkcs12 -export \
      -inkey "$STORE_DIR/key.pem" -in "$STORE_DIR/cert.pem" \
      -out "$STORE_DIR/identity.p12" -passout "pass:$P12_PASSWORD" -name "$IDENTITY" \
      -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
  fi
else
  echo "Reusing existing certificate material in $STORE_DIR."
fi

# 2. Import into the login keychain and trust it for code signing.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "Signing identity '$IDENTITY' is already in the keychain."
else
  security import "$STORE_DIR/identity.p12" \
    -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign
  # Trust the self-signed certificate so codesign accepts it. macOS may ask
  # for the login password once to confirm the trust change.
  security add-trusted-cert -r trustRoot -k "$LOGIN_KEYCHAIN" "$STORE_DIR/cert.pem"
  echo "Imported and trusted signing identity '$IDENTITY'."
fi

# 3. Refresh the CI export.
cp "$STORE_DIR/identity.p12" "$DIST_DIR/JMacTool-signing.p12"
base64 -i "$DIST_DIR/JMacTool-signing.p12" -o "$DIST_DIR/JMacTool-signing.p12.base64"

echo
echo "Exported $DIST_DIR/JMacTool-signing.p12 (+ .base64)."
echo
echo "For CI-signed releases (permissions survive updates on any machine), add"
echo "these GitHub repository secrets (Settings → Secrets and variables → Actions):"
echo "  MACOS_SIGNING_P12      = contents of $DIST_DIR/JMacTool-signing.p12.base64"
echo "  MACOS_SIGNING_PASSWORD = $P12_PASSWORD"
echo
echo "Note: the FIRST cert-signed install still needs its permissions granted"
echo "once; every later update keeps them."
