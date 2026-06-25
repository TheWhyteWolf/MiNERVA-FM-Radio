# MiNERVA-FM — deploy with Docker Compose

Run the whole station from the prebuilt image — no repo, no build. Hand someone this `deploy/`
folder and they're three steps from on-air.

```bash
cp .env.example .env          # 1. set strong passwords
#   ...put music in ./music   # 2. layout: <System>/<Game>/<files>
docker compose up -d          # 3. -> http://localhost:8080/  (click TUNE IN)
```

- **Music** lives in `./music` (mounted read-only). Example: `music/SNES/Chrono Trigger/01 Title.spc`.
- The **catalogue** is built on first run into the `catalogue` volume and persists across restarts.
- All formats decode in-container (ffmpeg+libgme for VGM/VGZ/SPC/NSF, sidplayfp for SID).

## Image access
The image is pulled from `ghcr.io/thewhytewolf/minerva-fm-station`. If it's **private**, the
recipient needs one of:
- `docker login ghcr.io` with a PAT that has `read:packages`, **or**
- a tarball you hand them: `docker save ghcr.io/thewhytewolf/minerva-fm-station | gzip > station.tar.gz`
  → `docker load < station.tar.gz`.

## Update
```bash
docker compose pull && docker compose up -d
```

## Security
Set strong `ICECAST_SOURCE_PASS` / `ICECAST_ADMIN_PASS` / `BRIDGE_TOKEN` in `.env` before exposing
this to a network. Only port `8080` is published; Icecast's source port stays inside the container.
