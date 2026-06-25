#!/bin/bash
# --- CONFIGURATION ---
export SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CSV_FILE="$SCRIPT_DIR/vgm_catalogue.csv"
export VGM_DIR="$SCRIPT_DIR"
export VIS_PATH="/usr/bin/vis"
export VIS_CONFIG="$HOME/.config/vis/config"
export QUEUE_FILE="/tmp/vgm_queue"
export QUEUE_LOCK="/tmp/vgm_queue.lock"
export DEBUG_LOG="/tmp/vgm_debug.log"
export VIS_PANE_FILE="/tmp/vgm_vis_pane"
export SONGLENGTHS="$SCRIPT_DIR/C64Music/DOCUMENTS/Songlengths.md5"
export MAX_TRACK="${MAX_TRACK:-900}"
# Minimum playback length (seconds) for .spc tracks. Many SPC rips carry a tiny
# or unset ID666 length tag (~1/3 of the collection is under 30s); the SPC's
# emulated audio loops, so flooring just plays more of the looping tune.
# Set to 0 to disable and trust the tag verbatim.
export SPC_MIN_DURATION="${SPC_MIN_DURATION:-60}"
# SID subtune handling: "all" plays every subtune in turn; "random" plays one
# randomly chosen subtune per SID. Toggle at launch: SID_SUBTUNE_MODE=random
export SID_SUBTUNE_MODE="${SID_SUBTUNE_MODE:-all}"
# Master volume for the vgm_radio sink (anything pactl accepts, e.g. 10% or 65536).
export RADIO_VOLUME="${RADIO_VOLUME:-10%}"
# --- BROADCAST (MiNERVA-FM web host) — all opt-in ---
# Set ICECAST_HOST (+ ICECAST_SOURCE_PASS) to stream the radio's audio to an
# Icecast mount; set BRIDGE_URL (+ BRIDGE_TOKEN) to push per-track now-playing
# to the metadata bridge. Leave either unset to disable that half. Needs ffmpeg
# (audio) and curl + python3 (metadata) on this host.
export ICECAST_HOST="${ICECAST_HOST:-}"
export ICECAST_PORT="${ICECAST_PORT:-8000}"
export ICECAST_MOUNT="${ICECAST_MOUNT:-/stream}"
export ICECAST_SOURCE_PASS="${ICECAST_SOURCE_PASS:-}"
export STREAM_BITRATE="${STREAM_BITRATE:-128k}"
export BRIDGE_URL="${BRIDGE_URL:-}"
export BRIDGE_TOKEN="${BRIDGE_TOKEN:-}"
export BROADCAST_ENV_FILE="/tmp/vgm_broadcast.env"
GOVERNOR_BACKUP=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
SCHEMES=(gameboy gameboy_pocket bbc_micro pico8 cga nes minerva c64 zx_spectrum)
CHARS=("#" "|" ":" "+" "*" "=" "!" ">" "%" "@" "^" "~" "-" "o" "x")

# --- CSV FIELD PARSER ---
parse_entry() {
    local entry="$1"
    local tmpfile=$(mktemp)
    echo "$entry" > "$tmpfile"
    mapfile -t fields < <(python3 - "$tmpfile" <<'EOF'
import sys, csv
with open(sys.argv[1], encoding='latin-1') as fh:
    r = next(csv.reader([fh.read().strip()]), [])
for i in (4, 5, 6, 7, 8, 9):
    print(r[i] if i < len(r) else '')
EOF
    )
    rm -f "$tmpfile"
    CAT_ID="${fields[0]}"
    TLD="${fields[1]}"
    PLATFORM="${fields[2]}"
    GAME="${fields[3]}"
    FILE="${fields[4]}"
    META="${fields[5]}"
}

# --- SID DURATION LOOKUP ---
# HVSC Songlengths.md5 is keyed by the MD5 of the WHOLE .sid file (verified
# against the database). The catalogue's stored md5 used the wrong algorithm,
# so we recompute it here from the file itself.
get_sid_duration() {
    local file_path="$1"
    local subtune="${2:-1}"
    python3 - "$SONGLENGTHS" "$file_path" "$subtune" <<'EOF'
import sys, hashlib, re

songlengths = sys.argv[1]
path = sys.argv[2]
subtune = int(sys.argv[3]) if len(sys.argv) > 3 else 1
DEFAULT = 120

try:
    with open(path, 'rb') as fh:
        target = hashlib.md5(fh.read()).hexdigest().lower()
except Exception:
    print(DEFAULT)
    sys.exit(0)

def to_secs(tok):
    m = re.match(r'(\d+):(\d+(?:\.\d+)?)', tok.strip())
    if not m:
        return None
    return int(round(int(m.group(1)) * 60 + float(m.group(2))))

dur = DEFAULT
try:
    with open(songlengths, encoding='latin-1') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(';') or line.startswith('[') or '=' not in line:
                continue
            h, times = line.split('=', 1)
            if h.strip().lower() == target:
                toks = times.split()
                idx = subtune - 1
                if idx < 0 or idx >= len(toks):
                    idx = 0
                val = to_secs(toks[idx]) if toks else None
                if val and val > 0:
                    dur = val
                break
except Exception:
    pass

print(dur)
EOF
}

# --- SID SUBTUNE COUNT (from PSID/RSID header, big-endian u16 at offset 0x0E) ---
get_sid_songs() {
    python3 - "$1" <<'EOF'
import sys, struct
try:
    with open(sys.argv[1], 'rb') as f:
        h = f.read(16)
    print(struct.unpack('>H', h[14:16])[0] if h[:4] in (b'PSID', b'RSID') and len(h) >= 16 else 1)
except Exception:
    print(1)
EOF
}

# --- UNLOAD ANY EXISTING vgm_radio NULL SINKS (handles multiple stale ones) ---
unload_vgm_sink() {
    pactl list modules short 2>/dev/null \
        | awk '/module-null-sink/ && /vgm_radio/ {print $1}' \
        | while read -r mod; do
              [ -n "$mod" ] && pactl unload-module "$mod" 2>/dev/null
          done
}

# --- SETUP ---
setup() {
    # A reachable sound server is mandatory — without it there is no sink and
    # every player would fail silently. Fail loudly and clean up instead.
    if ! pactl info >/dev/null 2>&1; then
        echo "Error: no PulseAudio/PipeWire server reachable (is the sound server running?)." >&2
        cleanup
    fi

    random_scheme="${SCHEMES[$RANDOM % ${#SCHEMES[@]}]}"
    random_char="${CHARS[$RANDOM % ${#CHARS[@]}]}"
    mkdir -p "$(dirname "$VIS_CONFIG")"
    cat > "$VIS_CONFIG" <<EOF
audio.sources=pulse
audio.pulse.source=vgm_radio.monitor
visualizer.fps=45
audio.stereo.enabled=true
visualizer.scaling.multiplier=3.5
visualizer.spectrum.character=$random_char
visualizers=spectrum
colors.override.terminal=false
colors.scheme=$random_scheme
EOF

    # Drop leftovers from a previous run, then create our null sink.
    unload_vgm_sink
    if ! pactl load-module module-null-sink sink_name=vgm_radio \
            sink_properties=device.description=VGM_Radio >/dev/null 2>&1; then
        echo "Error: could not load module-null-sink for vgm_radio." >&2
        cleanup
    fi
    # Confirm it actually appeared before relying on it.
    if ! pactl list short sinks 2>/dev/null | grep -qw vgm_radio; then
        echo "Error: vgm_radio sink did not appear after load-module." >&2
        cleanup
    fi
    pactl suspend-sink vgm_radio 0
    pactl set-sink-volume vgm_radio "$RADIO_VOLUME"

    > "$QUEUE_FILE"
    > "$DEBUG_LOG"
    > "$VIS_PANE_FILE"

    # Hand the broadcast metadata config to the engine subprocess (env doesn't
    # reliably survive tmux); publish_nowplaying() sources this.
    cat > "$BROADCAST_ENV_FILE" <<BCAST
BRIDGE_URL='${BRIDGE_URL}'
BRIDGE_TOKEN='${BRIDGE_TOKEN}'
BCAST
}

# --- CLEANUP ---
cleanup() {
    printf "\n"
    [ -n "$GOVERNOR_BACKUP" ] && echo "$GOVERNOR_BACKUP" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
    unload_vgm_sink
    rm -f "$QUEUE_FILE"
    rm -f "$QUEUE_LOCK"
    rm -f "$DEBUG_LOG"
    rm -f "$VIS_PANE_FILE"
    rm -f "$BROADCAST_ENV_FILE"
    tmux kill-session -t vgm_radio 2>/dev/null
    exit
}

# --- LOOKUP BY CATALOGUE ID ---
lookup_by_id() {
    local cat_id="$1"
    python3 - "$CSV_FILE" "$cat_id" <<'EOF'
import sys, csv, io
csv_file = sys.argv[1]
cat_id = sys.argv[2]
with open(csv_file, newline='', encoding='latin-1') as f:
    for row in csv.reader(f):
        if len(row) >= 9 and row[4] == cat_id:
            out = io.StringIO()
            csv.writer(out).writerow(row)
            print(out.getvalue().strip())
            break
EOF
}

# --- BROADCAST: per-track now-playing → metadata bridge (opt-in via BRIDGE_URL) ---
# Backgrounded so it never blocks playback; reads BRIDGE_URL/TOKEN from the file
# the launcher writes (tmux doesn't reliably pass env to the engine subprocess).
publish_nowplaying() {
    [ -f "$BROADCAST_ENV_FILE" ] && . "$BROADCAST_ENV_FILE"
    [ -z "$BRIDGE_URL" ] && return 0
    local id="$1" platform="$2" game="$3" track="${4%.*}" scheme="$5" char="$6"
    (
        json=$(python3 -c 'import json,sys; print(json.dumps(dict(
            id=sys.argv[1], platform=sys.argv[2], game=sys.argv[3],
            track=sys.argv[4], scheme=sys.argv[5], char=sys.argv[6])))' \
            "$id" "$platform" "$game" "$track" "$scheme" "$char")
        curl -fsS -m 5 -X POST "$BRIDGE_URL" \
            -H "Authorization: Bearer ${BRIDGE_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "$json"
    ) >/dev/null 2>&1 &
}

# --- THE PLAYER ENGINE ---
if [ "$1" == "--run-engine" ]; then
    SCHEMES=(gameboy gameboy_pocket bbc_micro pico8 cga nes minerva c64 zx_spectrum)
    CHARS=("#" "|" ":" "+" "*" "=" "!" ">" "%" "@" "^" "~" "-" "o" "x")
    SPC_PID=""
    MPV_PID=""
    SPC_FIFO=""
    SINK_INPUT=""

    trap 'kill "$SPC_PID" "$MPV_PID" 2>/dev/null; pkill -P $$ 2>/dev/null; rm -f "$SPC_FIFO"; exit 0' SIGINT SIGTERM

    while true; do
        echo "$(date): Queue check - $(wc -l < $QUEUE_FILE 2>/dev/null || echo 0) entries" >> "$DEBUG_LOG"
        echo "$(date): Queue contents: $(cat $QUEUE_FILE 2>/dev/null || echo empty)" >> "$DEBUG_LOG"

        if [ -s "$QUEUE_FILE" ]; then
            # Atomic pop: hold the lock across read + delete so a concurrent
            # append from Request.sh can't be clobbered by sed's rewrite.
            exec 200>"$QUEUE_LOCK"
            flock 200
            cat_id=$(head -1 "$QUEUE_FILE")
            sed -i '1d' "$QUEUE_FILE"
            exec 200>&-
            echo "$(date): Playing from queue - $cat_id" >> "$DEBUG_LOG"
            random_entry=$(lookup_by_id "$cat_id")
            if [ -z "$random_entry" ]; then
                echo "$(date): ERROR - ID $cat_id not found in CSV" >> "$DEBUG_LOG"
                echo -e "\e[1;31m[ QUEUE ERROR ]\e[0m Catalogue ID $cat_id not found, skipping."
                sleep 2
                continue
            fi
            source="REQUEST"
        else
            echo "$(date): Queue empty, playing random" >> "$DEBUG_LOG"
            random_entry=$(tail -n +2 "$CSV_FILE" | grep -v '^[[:space:]]*$' | shuf -n 1)
            source="RANDOM"
        fi

        parse_entry "$random_entry"
	echo "$(date) : META raw value: '${META}'" >> "$DEBUG_LOG"
        if [ -n "$PLATFORM" ] && [ "$PLATFORM" != "$TLD" ]; then
            file_path="$VGM_DIR/$TLD/$PLATFORM/$GAME/$FILE"
        else
            file_path="$VGM_DIR/$TLD/$GAME/$FILE"
        fi

        if [ ! -f "$file_path" ]; then
            echo "$(date): MISSING file, skipping - '$file_path'" >> "$DEBUG_LOG"
            echo -e "\e[1;31m[ MISSING ]\e[0m $file_path"
            sleep 1
            continue
        fi

        echo "$(date): Now playing - $CAT_ID / $file_path" >> "$DEBUG_LOG"

        random_scheme="${SCHEMES[$RANDOM % ${#SCHEMES[@]}]}"
        random_char="${CHARS[$RANDOM % ${#CHARS[@]}]}"
        sed -i "s/^colors.scheme=.*/colors.scheme=$random_scheme/" "$VIS_CONFIG"
        sed -i "s/^visualizer.spectrum.character=.*/visualizer.spectrum.character=$random_char/" "$VIS_CONFIG"
        vis_pane=$(cat "$VIS_PANE_FILE" 2>/dev/null)
        [ -n "$vis_pane" ] && tmux send-keys -t "$vis_pane" "r" 2>/dev/null

        clear
        echo -e "\e[1;34m[ NOW PLAYING ]\e[0m \e[1;33m[$source]\e[0m"
        echo -e "\e[1;32mID: \e[0m $CAT_ID"
        if [ -n "$PLATFORM" ]; then
            echo -e "\e[1;32mSystem: \e[0m $PLATFORM"
        fi
        echo -e "\e[1;32mGame: \e[0m $(echo "$GAME" | tr '_' ' ')"
        echo -e "\e[1;32mTrack: \e[0m $FILE"
        echo -e "\e[1;32mColour: \e[0m $random_scheme"

        if [ -s "$QUEUE_FILE" ]; then
            queue_depth=$(wc -l < "$QUEUE_FILE")
            echo -e "\e[1;35mQueue: \e[0m $queue_depth track(s) waiting"
        fi

        echo "------------------------------------------"

        # Broadcast: tell the MiNERVA-FM web host what's now playing (opt-in)
        publish_nowplaying "$CAT_ID" "$PLATFORM" "$(echo "$GAME" | tr '_' ' ')" "$FILE" "$random_scheme" "$random_char"

        SINK_INPUT=""
        SPC_FIFO=""

        case "${FILE,,}" in
        *.vgm|*.vgz)
            # MAX_TRACK guards against tracks with an infinite loop flag
            # wedging the stream.
            PULSE_SINK=vgm_radio timeout "$MAX_TRACK" vgmplayer "$file_path" || sleep 1
            ;;
        *.mod|*.mp3|*.flac|*.wav)
            mpv --no-video --really-quiet \
                --audio-device=pulse/vgm_radio \
                --af=loudnorm=I=-14:linear=true \
                "$file_path" || sleep 1
            ;;
        *.spc)
            if [[ "$META" =~ ^[0-9]+$ ]]; then
                SPC_DURATION="$META"
            else
                SPC_DURATION=120
            fi
            SPC_DURATION=${SPC_DURATION:-120}
            if [ "$SPC_DURATION" -lt "$SPC_MIN_DURATION" ]; then
                echo "$(date): SPC tag ${SPC_DURATION}s below floor, using ${SPC_MIN_DURATION}s" >> "$DEBUG_LOG"
                SPC_DURATION="$SPC_MIN_DURATION"
            fi
            FADE_DURATION=5
            PLAY_DURATION=$(( SPC_DURATION - FADE_DURATION ))
            if [ "$PLAY_DURATION" -lt 1 ]; then
                PLAY_DURATION=$SPC_DURATION
                FADE_DURATION=0
            fi
            echo "$(date): SPC duration: ${SPC_DURATION}s, fade at ${PLAY_DURATION}s" >> "$DEBUG_LOG"

            SPC_FIFO=$(mktemp -u /tmp/spc_XXXXXX.wav)
            mkfifo "$SPC_FIFO"

            SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
            vspcplay --novideo --echo --waveout "$SPC_FIFO" "$file_path" 2>/dev/null &
            SPC_PID=$!
            sleep 0.5
            timeout "$((SPC_DURATION + 5))" \
            mpv --no-video --really-quiet \
            --audio-device=pulse/vgm_radio \
            --af=loudnorm=I=-14:linear=true \
            --demuxer=rawaudio \
            --demuxer-rawaudio-rate=32000 \
            --demuxer-rawaudio-channels=2 \
            --demuxer-rawaudio-format=s16le \
            --length="$SPC_DURATION" \
            "$SPC_FIFO" &
            MPV_PID=$!

            MPV_SINK=""
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                sleep 0.3
                # application.process.id sits ~20+ lines below the "Sink Input #"
                # header, so a state machine is needed, not grep -B5.
                MPV_SINK=$(pactl list sink-inputs | awk -v pid="$MPV_PID" '
                    /^Sink Input #/ { n=$NF; gsub(/#/,"",n) }
                    index($0, "application.process.id = \"" pid "\"") { print n; exit }')
                [ -n "$MPV_SINK" ] && break
            done
            echo "$(date): SPC mpv sink input: $MPV_SINK" >> "$DEBUG_LOG"

            sleep "$PLAY_DURATION"

            if [ -n "$MPV_SINK" ] && [ "$FADE_DURATION" -gt 0 ]; then
                steps=20
                interval=$(awk "BEGIN{printf \"%.3f\", $FADE_DURATION/$steps}")
                for i in $(seq $steps -1 0); do
                    vol=$(( i * 65536 / steps ))
                    pactl set-sink-input-volume "$MPV_SINK" "$vol" 2>/dev/null
                    sleep "$interval"
                done
            fi

            kill $MPV_PID 2>/dev/null
            wait $MPV_PID 2>/dev/null
            kill $SPC_PID 2>/dev/null
            wait $SPC_PID 2>/dev/null
            rm -f "$SPC_FIFO"
            SPC_FIFO=""
            SPC_PID=""
            MPV_PID=""
            MPV_SINK=""
            ;;
        *.sid)
            SID_SONGS=$(get_sid_songs "$file_path")
            [[ "$SID_SONGS" =~ ^[0-9]+$ ]] && [ "$SID_SONGS" -ge 1 ] || SID_SONGS=1
            if [ "$SID_SUBTUNE_MODE" = "random" ]; then
                sub_list=$(( (RANDOM % SID_SONGS) + 1 ))
            else
                sub_list=$(seq 1 "$SID_SONGS")
            fi
            for sub in $sub_list; do
                SID_DURATION=$(get_sid_duration "$file_path" "$sub")
                SID_DURATION=${SID_DURATION:-120}
                SID_DURATION_FMT=$(printf "%d:%02d" $((SID_DURATION / 60)) $((SID_DURATION % 60)))
                echo "$(date): SID subtune ${sub}/${SID_SONGS} duration: ${SID_DURATION}s (${SID_DURATION_FMT})" >> "$DEBUG_LOG"

                sidplayfp -o"$sub" -t"$SID_DURATION_FMT" -w- "$file_path" 2>/dev/null \
                | mpv --no-video --really-quiet \
                    --audio-device=pulse/vgm_radio \
                    --af=loudnorm=I=-14:linear=true \
                    --demuxer=rawaudio \
                    --demuxer-rawaudio-rate=44100 \
                    --demuxer-rawaudio-channels=2 \
                    --demuxer-rawaudio-format=s16le \
                    - || sleep 0.1
            done
            ;;
        *)
            # Unknown/empty extension (e.g. a malformed row): log and pause so
            # we never spin in a tight no-playback loop.
            echo "$(date): Unhandled file, skipping - '$file_path'" >> "$DEBUG_LOG"
            sleep 1
            ;;
        esac
    done
    exit
fi

# --- THE LAUNCHER LOGIC ---
if [ ! -f "$CSV_FILE" ]; then echo "Error: Indexer required."; exit 1; fi

trap cleanup SIGINT SIGTERM

echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null

setup

tmux kill-session -t vgm_radio 2>/dev/null

# Capture pane IDs so targeting is independent of the user's pane-base-index.
# Top-to-bottom order: engine (top), visualizer (middle), ticker (bottom).
ENGINE_PANE=$(tmux new-session -d -P -F '#{pane_id}' -s vgm_radio -c "$VGM_DIR" "$0 --run-engine")

sleep 3

VIS_PANE=$(tmux split-window -v -P -F '#{pane_id}' -t "$ENGINE_PANE" "$VIS_PATH")
TICKER_PANE=$(tmux split-window -v -l 1 -P -F '#{pane_id}' -t "$VIS_PANE" "bash $SCRIPT_DIR/ticker.sh")
tmux resize-pane -t "$ENGINE_PANE" -y 12

# Publish the visualizer pane id so the engine can send it reload keys.
echo "$VIS_PANE" > "$VIS_PANE_FILE"

sleep 2
tmux send-keys -t "$VIS_PANE" "r"

pactl list sink-inputs short | grep vis | awk '{print $1}' | \
    xargs -I{} pactl set-sink-input-volume {} 10%

# Optional broadcast: stream the radio's audio to Icecast in a hidden tmux
# window (killed with the session on cleanup). Needs ffmpeg + ICECAST_HOST.
if [ -n "$ICECAST_HOST" ]; then
    if command -v ffmpeg >/dev/null 2>&1; then
        tmux new-window -d -t vgm_radio -n broadcast \
            "while true; do ffmpeg -hide_banner -loglevel error -f pulse -i vgm_radio.monitor -c:a libmp3lame -b:a ${STREAM_BITRATE} -ac 2 -ar 44100 -f mp3 -content_type audio/mpeg -ice_name 'MiNERVA-FM' -ice_genre 'Video Game Music' 'icecast://source:${ICECAST_SOURCE_PASS}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}'; echo 'stream dropped; retrying in 3s'; sleep 3; done"
        echo "Broadcast: audio -> ${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}"
    else
        echo "Broadcast: ffmpeg not found; audio disabled (metadata still works)." >&2
    fi
fi

tmux attach-session -t vgm_radio

cleanup
