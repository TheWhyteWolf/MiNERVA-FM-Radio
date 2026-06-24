# MiNERVA-FM — Radio (broadcast edition)

One shared live stream to many listeners, with the CRT visualiser front-end. Same look as the
[Local Player](https://github.com/TheWhyteWolf/MiNERVA-FM-Local), but the audio is a single
Icecast broadcast and the now-playing arrives over SSE — so everyone sees and hears the same thing.

## Topology

```
RADIO HOST (your machine, runs minerva-radio.sh)          VPS (public, https)
  vgm_radio null sink ──stream.sh (ffmpeg)──┐
                                            └──MP3 source──▶ Icecast :8000
  minerva-radio.sh ──publish.sh (per track)──POST /meta/update──▶ metadata-bridge :8088
                                                                  nginx :443  ──serves radio.html
                                                                    ├─ /stream ─▶ Icecast
                                                                    └─ /events ─▶ bridge (SSE)
                                                          Listeners ▶ <audio> + EventSource
```

`radio.html` is **self-contained** (no engines — it just plays the stream). Edit the `CONFIG`
block at the top only if you are NOT using the same-origin nginx setup below.

## VPS setup

```bash
sudo apt install icecast2 nginx ffmpeg          # ffmpeg optional on the VPS
# Node 18+ for the bridge (nodesource or distro package)

# 1. Icecast
sudo cp server/icecast.xml /etc/icecast2/icecast.xml   # edit: passwords + hostname
sudo systemctl enable --now icecast2

# 2. The listener page
sudo mkdir -p /var/www/minerva-fm
sudo cp radio.html /var/www/minerva-fm/radio.html

# 3. nginx + TLS
sudo cp server/nginx.conf /etc/nginx/sites-available/minerva-fm
sudo ln -s /etc/nginx/sites-available/minerva-fm /etc/nginx/sites-enabled/
# edit server_name, then:
sudo certbot --nginx -d radio.example.com
sudo nginx -t && sudo systemctl reload nginx

# 4. Metadata bridge (systemd)
BRIDGE_TOKEN=$(openssl rand -hex 16); echo "token: $BRIDGE_TOKEN"
sudo BRIDGE_TOKEN=$BRIDGE_TOKEN node /opt/minerva-fm/server/metadata-bridge.mjs   # or a unit file
```

Example systemd unit (`/etc/systemd/system/minerva-bridge.service`):

```ini
[Service]
Environment=BRIDGE_TOKEN=YOUR_TOKEN
Environment=ICECAST_STATUS=http://127.0.0.1:8000/status-json.xsl
ExecStart=/usr/bin/node /opt/minerva-fm/server/metadata-bridge.mjs
Restart=always
[Install]
WantedBy=multi-user.target
```

Firewall: only the radio host needs to reach Icecast's source port —
`sudo ufw allow from <RADIO_HOST_IP> to any port 8000` (or tunnel it over SSH/Tailscale).

## Radio host setup

```bash
# Push audio to the VPS Icecast (keep this running, e.g. under tmux/systemd):
ICECAST_HOST=radio.example.com ICECAST_SOURCE_PASS=CHANGE_ME_SOURCE ./server/stream.sh

# Publish now-playing per track: set these so minerva-radio.sh's hook fires:
export BRIDGE_URL=https://radio.example.com/meta/update
export BRIDGE_TOKEN=YOUR_TOKEN
```

Add this to `minerva-radio.sh`, right after the `[ NOW PLAYING ]` block in the engine loop
(where `$CAT_ID`, `$PLATFORM`, `$GAME`, `$FILE`, `$random_scheme`, `$random_char` are set):

```bash
# --- Publish now-playing to the MiNERVA-FM bridge (no-op if BRIDGE_URL unset) ---
"$SCRIPT_DIR/server/publish.sh" "$CAT_ID" "$PLATFORM" \
    "$(echo "$GAME" | tr '_' ' ')" "$FILE" "$random_scheme" "$random_char" &
```

Running it backgrounded (`&`) keeps metadata from ever blocking playback.

## Config checklist
- `icecast.xml`: `source/relay/admin` passwords, `hostname`
- `nginx.conf`: `server_name` (×3), cert paths (certbot)
- bridge: `BRIDGE_TOKEN`
- radio host: `ICECAST_HOST`, `ICECAST_SOURCE_PASS` (= icecast source pw), `BRIDGE_URL`, `BRIDGE_TOKEN`

## Notes
- **Codec:** MP3 (`libmp3lame`) for universal browser support. Add an Opus mount later if you want
  efficiency for non-Safari listeners.
- **Sync:** listeners are within their buffer (~a few seconds) of each other — standard internet radio.
- **Local Player unaffected:** this is a separate product; the BYO-files edition stays as-is.
