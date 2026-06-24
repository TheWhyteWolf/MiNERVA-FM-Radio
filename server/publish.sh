#!/bin/bash
# Publish the current track to the metadata bridge. Called by minerva-radio.sh per track.
# Usage: publish.sh <id> <system> <game> <track> <scheme> <char>
# Env: BRIDGE_URL (e.g. https://radio.example.com/meta/update), BRIDGE_TOKEN
[ -z "${BRIDGE_URL:-}" ] && exit 0          # not configured → no-op
: "${BRIDGE_TOKEN:?set BRIDGE_TOKEN}"

json=$(python3 -c 'import json,sys; print(json.dumps(dict(
  id=sys.argv[1], platform=sys.argv[2], game=sys.argv[3],
  track=sys.argv[4], scheme=sys.argv[5], char=sys.argv[6])))' \
  "$1" "$2" "$3" "$4" "$5" "$6")

curl -fsS -m 5 -X POST "$BRIDGE_URL" \
  -H "Authorization: Bearer $BRIDGE_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$json" >/dev/null 2>&1 || true
