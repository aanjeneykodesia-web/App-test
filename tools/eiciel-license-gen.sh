#!/bin/bash
# Generate the Eiciel license signing keypair. Run ONCE, offline.
set -euo pipefail

KEYDIR="${1:-$PWD/keys}"
mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"

if [ -f "$KEYDIR/license-priv.pem" ]; then
  echo "❌ $KEYDIR/license-priv.pem already exists. Refusing to overwrite."
  echo "   Delete it manually if you really want to regenerate."
  exit 1
fi

command -v openssl >/dev/null || { echo "❌ openssl not found"; exit 1; }

openssl genpkey -algorithm ed25519 -out "$KEYDIR/license-priv.pem"
openssl pkey -in "$KEYDIR/license-priv.pem" -pubout -out "$KEYDIR/license-pub.pem"

chmod 600 "$KEYDIR/license-priv.pem"
chmod 644 "$KEYDIR/license-pub.pem"

echo "✅ Generated:"
echo "   $KEYDIR/license-priv.pem   ← KEEP SECRET, never commit, never ship"
echo "   $KEYDIR/license-pub.pem    ← ship this with the ISO (LICENSE_PUBKEY_FILE)"
echo ""
echo "Fingerprint (public key):"
openssl pkey -in "$KEYDIR/license-pub.pem" -pubin -outform DER 2>/dev/null \
  | sha256sum | awk '{print "  sha256:"$1}'
