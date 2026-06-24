#!/bin/sh
# Templating + launch for the MiNERVA-FM web host container.
set -e
: "${ICECAST_SOURCE_PASS:=hackme}"
: "${ICECAST_ADMIN_PASS:=hackme}"
: "${BRIDGE_TOKEN:=changeme}"

sed -e "s|__SOURCE_PASS__|${ICECAST_SOURCE_PASS}|g" \
    -e "s|__ADMIN_PASS__|${ICECAST_ADMIN_PASS}|g" \
    /app/icecast.docker.xml > /etc/icecast2/icecast.xml

mkdir -p /var/log/icecast2
chown -R icecast2 /var/log/icecast2 2>/dev/null || true

echo "[entrypoint] icecast2 on :8000 (source pass set via env)"
runuser -u icecast2 -- icecast2 -c /etc/icecast2/icecast.xml &

echo "[entrypoint] metadata bridge on :8088"
BRIDGE_TOKEN="${BRIDGE_TOKEN}" BRIDGE_PORT=8088 \
  ICECAST_STATUS="http://127.0.0.1:8000/status-json.xsl" ICECAST_MOUNT="/stream" \
  node /app/metadata-bridge.mjs &

echo "[entrypoint] nginx on :8080 (serves radio.html, proxies /stream + /events)"
exec nginx -g 'daemon off;'
