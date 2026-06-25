#!/bin/sh
# Templating + launch (under supervisord) for the MiNERVA-FM web host container.
set -e
: "${ICECAST_SOURCE_PASS:=hackme}"; export ICECAST_SOURCE_PASS
: "${ICECAST_ADMIN_PASS:=hackme}"; export ICECAST_ADMIN_PASS
: "${BRIDGE_TOKEN:=changeme}";      export BRIDGE_TOKEN

sed -e "s|__SOURCE_PASS__|${ICECAST_SOURCE_PASS}|g" \
    -e "s|__ADMIN_PASS__|${ICECAST_ADMIN_PASS}|g" \
    /app/icecast.docker.xml > /etc/icecast2/icecast.xml

mkdir -p /var/log/icecast2
chown -R icecast2 /var/log/icecast2 2>/dev/null || true

echo "[entrypoint] starting supervisord — icecast (:8000) + bridge (:8088) + nginx (:8080), auto-restart"
exec supervisord -c /etc/supervisor/conf.d/minerva.conf -n
