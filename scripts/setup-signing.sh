#!/bin/bash
# One-time: creates a local self-signed code-signing identity "ProjectN Local Signing" in your login keychain.
# build.sh picks it up automatically. With a stable signature macOS remembers Keychain "Always Allow" and
# privacy permissions (Microphone, Accessibility, Input Monitoring) across rebuilds instead of asking again.
set -euo pipefail
NAME="ProjectN Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Already exists: $NAME"; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:projectn -name "$NAME" 2>/dev/null
security import "$TMP/id.p12" -k "$KEYCHAIN" -P projectn -T /usr/bin/codesign >/dev/null
echo "Created: $NAME"
security find-identity -p codesigning | grep "$NAME"
