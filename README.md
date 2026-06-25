# 🔒⚠️ CHANGE THE DEFAULT PASSWORDS BEFORE EXPOSING THIS ⚠️🔒

> [!CAUTION]
> This project ships with **insecure placeholder credentials** so it runs out of the box:
> `ICECAST_SOURCE_PASS=hackme` · `ICECAST_ADMIN_PASS=hackme` · `BRIDGE_TOKEN=changeme`.
>
> Anyone who can reach them can **hijack your stream, log into the Icecast _admin_ panel, or
> spoof the now-playing feed.** Before **any** internet-facing deployment:
>
>  **Set strong, unique values for all three** (via env vars / `docker-compose.yml`).
>  **Never expose Icecast's port `8000` to the public.** Firewall it to your audio-source host
>   (or tunnel it over SSH/Tailscale). Listeners only ever need the web port (`8080`, or `443` with TLS).
>   The Icecast admin login is `admin` / `ICECAST_ADMIN_PASS` — **treat it like a root password.**
>   For a public site, terminate **HTTPS** (the `server/nginx.conf` + certbot path), don't serve admin over plain HTTP.

---

## 🚀 Quickstart (run the whole station)

You need **Docker** and **your own music** (none ships — copyright).

```bash
git clone https://github.com/TheWhyteWolf/MiNERVA-FM-Radio
cd MiNERVA-FM-Radio
docker compose -f docker-compose.station.yml up --build
```

Put your music in `./music`, organised as **`<System>/<Game>/<files>`**
(e.g. `music/SNES/Chrono Trigger/01 Title.spc`) — **flat files won't index.** Then open
**http://localhost:8080/** and click **TUNE IN**. (First run builds the image, ~a few minutes.)

_Prefer not to build? Use the prebuilt-image [`deploy/`](deploy/) bundle — details below._

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

## 🎛️ All-in-one station (radio + web host in one container)

The simplest way to run the whole thing: mount a folder of your own music and it **indexes, plays,
and broadcasts** — radio engine, Icecast, metadata bridge, and the CRT page, all in one image.
Decoders are bundled (**ffmpeg+libgme** for VGM/VGZ/SPC/NSF, **sidplayfp** for SID), so there's no
PulseAudio / players / desktop to set up.

```bash
# drop your SID/SPC/VGM/VGZ/MP3 collection in ./music, then:
docker compose -f docker-compose.station.yml up --build
```

Open **http://localhost:8080/** and click TUNE IN.

- Mount your music at `/music` (read-only is fine). Layout: `/<System>/<Game>/<files…>`.
- The catalogue is generated on first run into the `/data` volume (persisted across restarts).
- Env tunables: `ICECAST_SOURCE_PASS`, `ICECAST_ADMIN_PASS`, `BRIDGE_TOKEN`, `STREAM_BITRATE`,
  `SID_DURATION`, `MAX_TRACK`. **Change the passwords before exposing it.**

Plain `docker run`:
```bash
docker build -f Dockerfile.station -t minerva-fm-station .
docker run -p 8080:8080 -v /path/to/music:/music:ro \
  -e ICECAST_SOURCE_PASS=ChangeMe -e BRIDGE_TOKEN=ChangeMe minerva-fm-station
```

Hand it to someone as a single file (no repo, no build):
```bash
docker save minerva-fm-station | gzip > minerva-fm-station.tar.gz
# they: docker load < minerva-fm-station.tar.gz
#       docker run -p 8080:8080 -v /their/music:/music:ro minerva-fm-station
```

**To hand someone a ready-to-run bundle** (prebuilt GHCR image, no repo, no build), use the
[`deploy/`](deploy/) folder — see [`deploy/README.md`](deploy/README.md): `cp .env.example .env`,
drop music in `deploy/music/`, `docker compose up -d`.

The section below is the **split** setup instead — web host only, fed by a separate radio source
(e.g. your real `minerva-radio.sh` on another machine).

## Run the web host with Docker (easiest to share)

One image runs the whole listener side — **Icecast + metadata bridge + nginx serving `radio.html`**:

```bash
# Prebuilt image from GitHub Container Registry (once the workflow has published it
# and the package is set to public):
docker run -p 8080:8080 -p 8000:8000 ghcr.io/thewhytewolf/minerva-fm-radio

# …or build it locally:
docker compose up --build
# or:  docker build -t minerva-fm-radio . && \
#      docker run -p 8080:8080 -p 8000:8000 minerva-fm-radio
```

- **Listeners:** http://localhost:8080/  (replace localhost with the host's address to share)
- **Ports:** `8080` = web + metadata POST · `8000` = Icecast source-push
- **Secrets:** set `ICECAST_SOURCE_PASS`, `ICECAST_ADMIN_PASS`, `BRIDGE_TOKEN` (see `docker-compose.yml`)

Feed it audio from your radio host (where `minerva-radio.sh` + the `vgm_radio` sink live):

```bash
ICECAST_HOST=<docker-host> ICECAST_PORT=8000 ICECAST_SOURCE_PASS=hackme ./server/stream.sh
export BRIDGE_URL=http://<docker-host>:8080/meta/update BRIDGE_TOKEN=changeme   # for publish.sh
```

No music handy? Verify the pipeline with a **test tone**:

```bash
ffmpeg -re -f lavfi -i "sine=frequency=440:sample_rate=44100" -ac 2 \
  -c:a libmp3lame -b:a 128k -f mp3 -content_type audio/mpeg \
  icecast://source:hackme@<docker-host>:8000/stream
```

This container is plain HTTP (great for a quick share / LAN / behind another proxy). For a public
TLS deployment, use the `server/nginx.conf` + certbot path below instead.

Inside the container, **supervisord** runs Icecast + the metadata bridge + nginx and **auto-restarts
any that crash**.

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
