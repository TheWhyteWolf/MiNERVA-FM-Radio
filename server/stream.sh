#!/bin/bash
# Capture the vgm_radio null-sink monitor and push it to Icecast as an MP3 mount.
# RUN THIS ON THE RADIO HOST (where minerva-radio.sh + the vgm_radio sink live).
# MP3 is used for the widest browser support (Safari has no Ogg/Opus).
set -uo pipefail

: "${ICECAST_HOST:?set ICECAST_HOST (your VPS hostname/IP)}"
: "${ICECAST_SOURCE_PASS:?set ICECAST_SOURCE_PASS (matches icecast.xml)}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/stream}"
PULSE_SOURCE="${PULSE_SOURCE:-vgm_radio.monitor}"
BITRATE="${BITRATE:-128k}"

DEST="icecast://source:${ICECAST_SOURCE_PASS}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}"

# Reconnect loop — if the source connection drops, wait and re-establish.
while true; do
  echo "$(date) connecting to ${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT} from ${PULSE_SOURCE}"
  ffmpeg -hide_banner -loglevel warning \
    -f pulse -i "$PULSE_SOURCE" \
    -c:a libmp3lame -b:a "$BITRATE" -ac 2 -ar 44100 \
    -f mp3 -content_type audio/mpeg \
    -ice_name "MiNERVA-FM" -ice_genre "Video Game Music" \
    "$DEST" || true
  echo "$(date) stream ended; restarting in 3s"
  sleep 3
done
