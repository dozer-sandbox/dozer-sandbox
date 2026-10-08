#!/bin/bash
# notary-ticket.sh BINARY [WAIT_SECONDS] — prove a notarised command-line tool's ticket is published.
#
# A bare command-line tool cannot be stapled, so `spctl` / `syspolicy_check` (which look for a STAPLED ticket, or
# answer from Gatekeeper's local cache) say "Unnotarized Developer ID" even when Apple notarised it — 0.31.0's
# release stopped on exactly that, and the same build passed Gatekeeper on a second Mac that had never assessed it.
# What Gatekeeper does on a user's first run is look the ticket up online, by the binary's code-directory hash, in
# Apple's ticket service. This script does that lookup: the binary's CDHash (codesign) → the public CloudKit
# database Gatekeeper and `stapler` read (com.apple.gk.ticket-delivery, record "2/2/<cdhash>") → a `signedTicket`.
# It polls (every 15 s, up to WAIT_SECONDS, default 600): the ticket appears shortly after notarytool's "Accepted".
# Exit 0 = a ticket for exactly this binary is published; 1 = none within the wait; 2 = usage / no CDHash.
set -euo pipefail
bin="${1:-}"; wait="${2:-600}"
[[ -n "$bin" && -f "$bin" ]] || { echo "usage: notary-ticket.sh BINARY [WAIT_SECONDS]" >&2; exit 2; }
cdhash="$(codesign -dvvv "$bin" 2>&1 | sed -n 's/^CDHash=\([0-9a-f]\{40\}\)$/\1/p' | head -1)"
[[ -n "$cdhash" ]] || { echo "notary-ticket: no CDHash for $bin (not signed?)" >&2; exit 2; }
url="https://api.apple-cloudkit.com/database/1/com.apple.gk.ticket-delivery/production/public/records/lookup"
deadline=$(( $(date +%s) + wait ))
while :; do
    answer="$(curl -sS -m 20 -X POST "$url" -H 'Content-Type: application/json' \
        -d "{\"records\":[{\"recordName\":\"2/2/$cdhash\"}]}" 2>/dev/null || true)"
    if python3 -c 'import json,sys; r=json.loads(sys.stdin.read() or "{}").get("records",[]); sys.exit(0 if r and "signedTicket" in (r[0].get("fields") or {}) else 1)' <<<"$answer" 2>/dev/null; then
        echo "notary-ticket: published for CDHash $cdhash"
        exit 0
    fi
    (( $(date +%s) >= deadline )) && { echo "notary-ticket: no ticket for CDHash $cdhash after ${wait}s" >&2; exit 1; }
    sleep 15
done
