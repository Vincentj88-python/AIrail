#!/bin/bash
# Create (or re-create) the self-signed "AIrail Dev" code-signing certificate
# that scripts/release.sh and the Xcode project sign with until there is an
# Apple Developer ID. Ten years, so the Keychain "Always Allow" users grant for
# the Claude Code item keeps sticking across releases.
#
# Run it by hand — it asks for your login password twice (importing the
# identity, trusting it for code signing) and every build signed with a new
# certificate re-prompts once for the Claude Keychain item. Delete the old
# "AIrail Dev" certificate in Keychain Access first, or codesign will find two.
#
#   ./scripts/make-dev-cert.sh
set -euo pipefail

NAME="${AIRAIL_SIGN_IDENTITY:-AIrail Dev}"
DAYS=3650
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✗ a certificate named \"$NAME\" already exists — delete it in Keychain Access first"
  exit 1
fi

cat > "$WORK/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = $NAME
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "▸ Generating a $DAYS-day self-signed certificate \"$NAME\""
openssl req -x509 -newkey rsa:2048 -nodes -days "$DAYS" -config "$WORK/ext.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -passout pass:airail -out "$WORK/identity.p12"

echo "▸ Importing into the login keychain (codesign may use the key without asking)"
security import "$WORK/identity.p12" -k ~/Library/Keychains/login.keychain-db -P airail -T /usr/bin/codesign -T /usr/bin/security

echo "▸ Trusting it for code signing (asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$WORK/cert.pem"

echo "▸ Verifying"
security find-identity -v -p codesigning | grep "$NAME" || { echo "✗ codesign can't see the identity"; exit 1; }
echo "✓ \"$NAME\" is ready for $DAYS days; run ./scripts/release.sh"
