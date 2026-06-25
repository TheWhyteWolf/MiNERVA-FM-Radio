# MiNERVA-FM — Radio

A self-hosted chiptune radio. It indexes your retro game-music collection, broadcasts one shared
stream, and serves a CRT-styled web player with a live spectrum. SID, SPC, VGM/VGZ, NSF, MOD and
MP3/FLAC/WAV all decode in-container (ffmpeg + libgme, sidplayfp) — no PulseAudio, players, or
desktop required.

> [!CAUTION]
> Ships with placeholder credentials (`ICECAST_SOURCE_PASS=hackme`, `ICECAST_ADMIN_PASS=hackme`,
> `BRIDGE_TOKEN=changeme`) so it runs out of the box. Before exposing it to any network:
> set strong, unique values for all three; never expose Icecast's port 8000 publicly (firewall or
> tunnel it — listeners only need 8080, or 443 with TLS); the Icecast admin login
> (`admin` / `ICECAST_ADMIN_PASS`) is root-equivalent; use HTTPS for public sites.

## Quickstart

Needs Docker and your own music (none ships — copyright).

```bash
git clone https://github.com/TheWhyteWolf/MiNERVA-FM-Radio
cd MiNERVA-FM-Radio
docker compose -f docker-compose.station.yml up --build
```

Put your music in `./music` as `<System>/<Game>/<files>`
(e.g. `music/SNES/Chrono Trigger/01 Title.spc`) — flat files won't index. Then open
http://localhost:8080/ and click TUNE IN. The first run builds the image (a few minutes).

## Ways to run

| | how | needs |
|---|---|---|
| Build it yourself | `docker compose -f docker-compose.station.yml up --build` | this repo |
| Prebuilt image | copy `deploy/`, `cp .env.example .env`, add music, `docker compose up -d` | GHCR access* |
| By hand | `docker build -f Dockerfile.station -t minerva-fm-station .` then `docker run -p 8080:8080 -v /your/music:/music:ro -e ICECAST_SOURCE_PASS=… -e BRIDGE_TOKEN=… minerva-fm-station` | this repo |

\* The image is `ghcr.io/thewhytewolf/minerva-fm-station`. If it is private the recipient needs
`docker login ghcr.io` (a PAT with `read:packages`), or a tarball you hand them
(`docker save … | gzip > station.tar.gz` then `docker load < station.tar.gz`).

## Configuration

Set via environment variables (or `deploy/.env`):

| variable | default | purpose |
|---|---|---|
| `ICECAST_SOURCE_PASS` | `hackme` | Icecast source password — change it |
| `ICECAST_ADMIN_PASS` | `hackme` | Icecast admin password — change it |
| `BRIDGE_TOKEN` | `changeme` | auth for metadata updates — change it |
| `STREAM_BITRATE` | `128k` | MP3 stream bitrate |
| `SID_DURATION` | `180` | seconds per SID (no HVSC song-lengths in-container) |
| `MAX_TRACK` | `300` | hard cap per track, in seconds |

## How it works

One container (Debian + supervisord) runs five processes: `station` indexes `/music`, picks tracks
and decodes them to PCM; a FIFO feeds the `encoder` (ffmpeg, MP3); `icecast` serves one mount to
many listeners; `bridge` pushes now-playing over SSE; `nginx` serves the player (`radio.html`) and
proxies `/stream` and `/events`. Decoders are ffmpeg + libgme (VGM/VGZ/SPC/NSF/…), sidplayfp (SID),
and native (MP3/FLAC/WAV). The catalogue is built by `minerva-indexer.sh` into a `/data` volume, so
`/music` can stay read-only. MP3 is used for the widest browser support; listeners are within a few
seconds of each other (standard internet radio).

## Split deployment (public web host + a separate radio source)

Run the listener side on a VPS and feed it from a machine that already has the music.

VPS — web host only (`Dockerfile` / `docker-compose.yml`): Icecast + bridge + nginx, expecting an
external source. For a public site, use `server/icecast.xml`, `server/nginx.conf` (+ certbot) and
`server/metadata-bridge.mjs` (run under systemd). Firewall Icecast's 8000 to the source host only.

Radio host — feed it:

```bash
ICECAST_HOST=<vps> ICECAST_SOURCE_PASS=… ./server/stream.sh        # audio  -> Icecast
export BRIDGE_URL=https://<vps>/meta/update BRIDGE_TOKEN=…          # now-playing -> bridge
```

`minerva-radio.sh` also has built-in, opt-in hooks: set `ICECAST_HOST` and `BRIDGE_URL` before
launching and it streams audio and publishes each track automatically. Full configs and inline
notes live in `server/`.

## Credits

Decoding by ffmpeg, libgme (Blargg's game-music-emu, LGPL) and sidplayfp. CRT look inspired by
cool-retro-term. Bundled components keep their upstream licenses — review them before redistributing.
You are responsible for the rights to any music you broadcast.
