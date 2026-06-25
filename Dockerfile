# MiNERVA-FM web host — Icecast + metadata bridge + nginx serving radio.html.
# Feed it audio from your radio host (server/stream.sh) and metadata (server/publish.sh).
FROM node:20-bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends icecast2 nginx supervisor ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default

COPY radio.html                 /var/www/minerva-fm/radio.html
COPY server/metadata-bridge.mjs /app/metadata-bridge.mjs
COPY docker/icecast.docker.xml  /app/icecast.docker.xml
COPY docker/nginx.docker.conf   /etc/nginx/conf.d/minerva.conf
COPY docker/supervisord.conf    /etc/supervisor/conf.d/minerva.conf
COPY docker/entrypoint.sh       /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8080 8000
ENTRYPOINT ["/app/entrypoint.sh"]
