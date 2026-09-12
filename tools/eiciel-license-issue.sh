#!/bin/bash
# Issue a signed license file.
#
# Usage:
#   eiciel-license-issue.sh <priv-key.pem> <issued-to> <days> [machine-uuid] [outdir]
#
# Example:
#   ./eiciel-license-issue.sh keys/license-priv.pem "Acme Corp" 365 > acme.lic
#   ./eiciel-license-issue.sh keys/license-priv.pem "Acme Corp" 365 4c4c4544-... ./acme/
#
# Without machine-uuid: license works on any machine.
# With    machine-uuid: license only works on the box whose
#                       /sys/class/dmi/id/product_uuid matches.
#
# On stdout: a POSIX shell snippet containing the license JSON and a base64
# signature. The customer decodes the sig (base64 -d) and saves both files.
set -euo pipefail

PRIV="${1:-}"; ISSUED_TO="${2:-}"; DAYS="${3:-}"; MACHINE="${4:-}"; OUTDIR="${5:-}"

if [ -z "$PRIV" ] || [ -z "$ISSUED_TO" ] || [ -z "$DAYS" ]; then
  echo "usage: $0 <priv-key.pem> <issued-to> <days> [machine-uuid] [outdir]" >&2
  exit 2
fi

[ -f "$PRIV" ] || { echo "no such key: $PRIV" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl missing" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq missing" >&2;      exit 1; }

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
after=$(date -u -d "+${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)
lid="EIC-$(date -u +%Y%m%d)-$(openssl rand -hex 4)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

jq -nc \
  --arg lid "$lid" --arg to "$ISSUED_TO" \
  --arg nb "$now" --arg na "$after" \
  --arg mid "$MACHINE" \
  '{
    version: 1,
    license_id: $lid,
    issued_to: $to,
    not_before: $nb,
    not_after: $na,
    machine_id: (if $mid == "" then null else $mid end),
    features: ["containment", "dashboard"]
  }' > "$TMP/license.json"

openssl pkeyutl -sign -inkey "$PRIV" -rawin \
  -in "$TMP/license.json" -out "$TMP/license.sig"

if [ -n "$OUTDIR" ]; then
  install -d -m 755 "$OUTDIR"
  install -m 644 "$TMP/license.json" "$OUTDIR/license.json"
  install -m 644 "$TMP/license.sig"  "$OUTDIR/license.sig"
  echo "✅ Wrote:" >&2
  echo "   $OUTDIR/license.json" >&2
  echo "   $OUTDIR/license.sig"  >&2
  echo "" >&2
  echo "Deliver both files. Customer runs:" >&2
  echo "   sudo eiciel-license-install $OUTDIR/license.json $OUTDIR/license.sig" >&2
else
  echo "# License: $lid for $ISSUED_TO"
  echo "# Valid:   $now → $after"
  [ -n "$MACHINE" ] && echo "# Bound:   $MACHINE" || echo "# Bound:   (any machine)"
  echo ""
  echo "# license.json"
  cat "$TMP/license.json"
  echo ""
  echo "# license.sig (base64)"
  base64 -w0 "$TMP/license.sig"; echo
fi
