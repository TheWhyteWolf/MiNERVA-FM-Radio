#!/bin/sh
# Templating + launch for the MiNERVA-FM all-in-one station container.
set -e
: "${ICECAST_SOURCE_PASS:=hackme}"; export ICECAST_SOURCE_PASS
: "${ICECAST_ADMIN_PASS:=hackme}";  export ICECAST_ADMIN_PASS
: "${BRIDGE_TOKEN:=changeme}";      export BRIDGE_TOKEN

sed -e "s|__SOURCE_PASS__|${ICECAST_SOURCE_PASS}|g" \
    -e "s|__ADMIN_PASS__|${ICECAST_ADMIN_PASS}|g" \
    /app/icecast.docker.xml > /etc/icecast2/icecast.xml

mkdir -p /var/log/icecast2
chown -R icecast2 /var/log/icecast2 2>/dev/null || true

rm -f /tmp/radio.pcm
mkfifo /tmp/radio.pcm

echo "[entrypoint] MiNERVA-FM station — indexing /music, broadcasting on http://localhost:8080/"
exec supervisord -c /etc/supervisor/conf.d/minerva.conf -n
