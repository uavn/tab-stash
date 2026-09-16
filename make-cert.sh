#!/bin/zsh
# Creates a self-signed code-signing identity "TabStash Dev" in the login keychain.
# It does not need to be trusted: codesign accepts it, and macOS keeps the
# Accessibility grant because the signature's designated requirement stays the same.
set -euo pipefail
NAME="TabStash Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=$NAME
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
subjectKeyIdentifier=hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" 2>/dev/null
# -legacy: OpenSSL 3 defaults produce a PKCS#12 that `security import` cannot read.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/dev.p12" -passout pass:x -name "$NAME" 2>/dev/null
security import "$TMP/dev.p12" -k ~/Library/Keychains/login.keychain-db -P x \
  -T /usr/bin/codesign -T /usr/bin/security
echo "Created identity \"$NAME\"."
