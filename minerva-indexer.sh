#!/bin/bash
# =============================================================================
# Minerva Universal Indexer  —  the single canonical indexer for the radio.
#
# Scans WORK_DIR and writes vgm_catalogue.csv, the catalogue consumed by
# minerva-radio.sh. Replaces the old per-type scripts (minerva-index-basic,
# minerva-index-spc, minerva-indexer-sid, minerva-index-normalaudio.sh).
#
# CSV columns (10):
#   TLD_ID, SUB_ID, PLATFORM_ID, FILE_ID, Catalogue_ID,
#   TLD_Name, Platform_Name, Game_Name, File_Name, Meta
#
#   Meta by type:
#     .sid             -> whole-file MD5  (the HVSC Songlengths.md5 key)
#     .spc             -> ID666 song length in seconds
#     .mp3/.flac/.wav  -> "<seconds>s"    (via ffprobe, if installed)
#     .vgm/.vgz/.mod   -> empty           (player needs no metadata)
#
# Usage:   ./minerva-indexer.sh [WORK_DIR] [--xlsx]
#            WORK_DIR   directory to index (default ".")
#            --xlsx     also export a styled vgm_catalogue.xlsx workbook
#                       (needs python 'openpyxl'); equivalently set XLSX=1
#
# Note: the player rebuilds paths as TLD/[PLATFORM]/GAME/FILE, so only files
# lying directly inside a game folder are indexed. Deeper trees (e.g. HVSC
# C64Music/MUSICIANS/<letter>/<composer>/) can't be expressed in that path
# model and are intentionally skipped — see the README note in the summary.
# =============================================================================

# --- argument parsing --------------------------------------------------------
WANT_XLSX=0
case "${XLSX:-}" in 1|true|yes|on|TRUE|True|Yes|On) WANT_XLSX=1 ;; esac
WORK_DIR="."
for arg in "$@"; do
    case "$arg" in
        --xlsx)    WANT_XLSX=1 ;;
        --no-xlsx) WANT_XLSX=0 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        -*)        echo "Unknown option: $arg" >&2; exit 1 ;;
        *)         WORK_DIR="$arg" ;;
    esac
done

OUTPUT_CSV="${OUTPUT_CSV:-$WORK_DIR/vgm_catalogue.csv}"
OUTPUT_XLSX="${OUTPUT_XLSX:-$WORK_DIR/vgm_catalogue.xlsx}"
EXTS=(vgz vgm spc sid mp3 flac wav mod)

# Folders never descended into (matched against the top-level dir path).
excluded="cli-visualizer|clivisualizer|libvgm|build|__MACOSX|Xtract|DeAccent|indexer|DOCUMENTS"

# --- Prevent concurrent runs (would corrupt the CSV) -------------------------
exec 9>"/tmp/vgm_indexer.lock"
if ! flock -n 9; then echo "Error: indexer is already running."; exit 1; fi

# --- Dependency checks -------------------------------------------------------
command -v md5sum >/dev/null 2>&1 || { echo "ERROR: md5sum is required."; exit 1; }
HAS_FFPROBE=1
if ! command -v ffprobe >/dev/null 2>&1; then
    HAS_FFPROBE=0
    echo "NOTE: ffprobe not found — .mp3/.flac/.wav durations will be left blank."
fi

echo "Indexing: $WORK_DIR"
echo "Output:   $OUTPUT_CSV"
echo "------------------------------------------"

# --- find expression for our extensions (case-insensitive) -------------------
_find_expr=()
for _e in "${EXTS[@]}"; do
    [ ${#_find_expr[@]} -gt 0 ] && _find_expr+=( -o )
    _find_expr+=( -iname "*.$_e" )
done

find_audio_files() {              # find_audio_files DIR [MAXDEPTH]
    local dir="$1" maxdepth="${2:-}"
    if [ -n "$maxdepth" ]; then
        find "$dir" -maxdepth "$maxdepth" -type f \( "${_find_expr[@]}" \)
    else
        find "$dir" -type f \( "${_find_expr[@]}" \)
    fi
}

# A "grouping folder" has subdirs but no direct audio — a category/platform
# layer (e.g. Arcade/Capcom/, C64Music/DEMOS/), not a game folder.
is_grouping_folder() {
    local dir="$1" has_audio has_subdir
    has_audio=$(find_audio_files "$dir" 1 | head -1)
    has_subdir=$(find "$dir" -maxdepth 1 -mindepth 1 -type d | head -1)
    [[ -z "$has_audio" && -n "$has_subdir" ]]
}

csv_escape() { local s="$1"; printf '%s' "${s//\"/\"\"}"; }   # double embedded quotes

# --- META helpers ------------------------------------------------------------
spc_length() {                    # ID666 song length in seconds (fallback 120)
    python3 - "$1" <<'EOF'
import sys
try:
    h = open(sys.argv[1], 'rb').read(256)
    if len(h) >= 0xAC:
        if h[0x23] == 0x1A:       # text ID666 tag: 3 ASCII bytes at 0xA9
            d = h[0xA9:0xAC].decode('ascii', 'ignore').replace('\x00', '').strip()
        else:                     # binary ID666 tag: little-endian integer
            d = str(int.from_bytes(h[0xA9:0xAC], 'little'))
        print(d if (d.isdigit() and 0 < int(d) <= 3600) else '120')
    else:
        print('120')
except Exception:
    print('120')
EOF
}

meta_for() {                      # echo the Meta value for one file
    local f="$1" lc="${1,,}" d
    case "$lc" in
        *.sid) md5sum "$f" | cut -d' ' -f1 ;;
        *.spc) spc_length "$f" ;;
        *.mp3|*.flac|*.wav)
            [ "$HAS_FFPROBE" -eq 1 ] || { echo ""; return; }
            d=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
            [[ "$d" =~ ^[0-9.]+$ ]] && printf '%.0fs' "$d" || echo "" ;;
        *) echo "" ;;
    esac
}

# --- counters ----------------------------------------------------------------
tld_id=100
sub_id=1000
total_tracks=0
total_subdirs=0
total_tlds=0

# --- write all indexable files in one game dir as CSV rows -------------------
emit_game() {                     # emit_game TLD_ID PLATFORM_ID TLD_NAME PLATFORM_NAME GAME_DIR
    local tld_id="$1" platform_id="$2" tld_name="$3" platform_name="$4" game_dir="$5"
    local game_name file file_name cat_id meta file_id
    game_name=$(basename "$game_dir")
    mapfile -t files < <(find_audio_files "$game_dir" 1 | sort)
    [[ ${#files[@]} -eq 0 ]] && return
    ((total_subdirs++))
    file_id=1
    for file in "${files[@]}"; do
        file_name=$(basename "$file")
        cat_id="${tld_id}-${sub_id}-${file_id}"
        meta=$(meta_for "$file")
        printf '%s,%s,%s,%s,"%s","%s","%s","%s","%s","%s"\n' \
            "$tld_id" "$sub_id" "$platform_id" "$file_id" \
            "$(csv_escape "$cat_id")"        "$(csv_escape "$tld_name")" \
            "$(csv_escape "$platform_name")" "$(csv_escape "$game_name")" \
            "$(csv_escape "$file_name")"     "$(csv_escape "$meta")" >> "$OUTPUT_CSV"
        ((file_id++)); ((total_tracks++))
    done
    ((sub_id++))
}

# --- header ------------------------------------------------------------------
echo "TLD_ID,SUB_ID,PLATFORM_ID,FILE_ID,Catalogue_ID,TLD_Name,Platform_Name,Game_Name,File_Name,Meta" > "$OUTPUT_CSV"

# --- main walk ---------------------------------------------------------------
mapfile -t tlds < <(find "$WORK_DIR" -maxdepth 1 -mindepth 1 -type d | grep -vE "$excluded" | sort)

for tld in "${tlds[@]}"; do
    tld_name=$(basename "$tld")
    # Skip TLDs that contain none of our file types.
    find_audio_files "$tld" | grep -q . || continue
    echo "TLD: $tld_name ($tld_id)"
    ((total_tlds++))

    platform_id=1
    mapfile -t subdirs < <(find "$tld" -maxdepth 1 -mindepth 1 -type d | sort)

    for subdir in "${subdirs[@]}"; do
        subdir_name=$(basename "$subdir")
        if is_grouping_folder "$subdir"; then
            # TLD / Platform / Game / files   (Platform_Name = subdir)
            echo "  Grouping: $subdir_name"
            mapfile -t games < <(find "$subdir" -maxdepth 1 -mindepth 1 -type d | sort)
            for game in "${games[@]}"; do
                emit_game "$tld_id" "$platform_id" "$tld_name" "$subdir_name" "$game"
            done
            ((platform_id++))
        else
            # TLD / Game / files              (Platform_Name = TLD)
            emit_game "$tld_id" 0 "$tld_name" "$tld_name" "$subdir"
        fi
    done
    ((tld_id++))
done

echo "------------------------------------------"
echo "TLDs: $total_tlds | SubDirs: $total_subdirs | Tracks: $total_tracks"
echo "Written: $OUTPUT_CSV"

# --- optional XLSX export ----------------------------------------------------
if [ "$WANT_XLSX" -eq 1 ]; then
    if ! python3 -c "import openpyxl" >/dev/null 2>&1; then
        echo "WARNING: --xlsx requested but python module 'openpyxl' is missing."
        echo "         The CSV was written; for the workbook run: pip install openpyxl"
    else
        echo "Building XLSX workbook..."
        python3 - "$OUTPUT_CSV" "$OUTPUT_XLSX" <<'PYEOF'
import sys, csv
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side

csv_path, xlsx_path = sys.argv[1], sys.argv[2]

wb = Workbook()
ws = wb.active
ws.title = "Catalogue"

HEADER_FILL = PatternFill("solid", fgColor="1F4E79")
HEADER_FONT = Font(name="Arial", bold=True, color="FFFFFF", size=10)
DATA_FONT   = Font(name="Arial", size=9)
ALT_FILL    = PatternFill("solid", fgColor="EEF2F7")
LEFT        = Alignment(horizontal="left",   vertical="center")
CENTER      = Alignment(horizontal="center", vertical="center")
SIDE        = Side(style="thin", color="CCCCCC")
BORDER      = Border(left=SIDE, right=SIDE, top=SIDE, bottom=SIDE)

with open(csv_path, newline="", encoding="latin-1") as f:
    for row in csv.reader(f):
        ws.append(row)

ws.freeze_panes = "A2"
ws.row_dimensions[1].height = 22
for cell in ws[1]:
    cell.font = HEADER_FONT; cell.fill = HEADER_FILL
    cell.alignment = CENTER;  cell.border = BORDER
for idx, row in enumerate(ws.iter_rows(min_row=2), start=2):
    shade = ALT_FILL if idx % 2 == 0 else None
    for cell in row:
        cell.font = DATA_FONT; cell.border = BORDER; cell.alignment = LEFT
        if shade:
            cell.fill = shade

for col, width in {"A": 8, "B": 8, "C": 11, "D": 8, "E": 18,
                   "F": 20, "G": 22, "H": 34, "I": 40, "J": 36}.items():
    ws.column_dimensions[col].width = width

ws.auto_filter.ref = ws.dimensions
wb.save(xlsx_path)
print(f"Saved: {xlsx_path}")
PYEOF
        echo "Written: $OUTPUT_XLSX"
    fi
fi

echo "Done."
