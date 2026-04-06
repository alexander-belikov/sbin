#!/bin/bash
set -euo pipefail

# --- Help & Defaults ---
usage() {
    cat <<EOF
Usage: $0 <backup|restore|dry-run> [config.json] [options]

Options:
  -c, --checksum       Use checksums (slower, more reliable)
  --limit <speed>      Limit bandwidth (e.g., 500K, 2M, 10M)
  --burst              Disable bandwidth limits (Full speed)
  
Config JSON: { "local_root": "...", "remote_root": "...", "paths": [], "exclude": [] }
EOF
    exit 1
}

[[ $# -lt 1 ]] && usage

# --- Initialization ---
MODE=$1; shift
CONF="active_paths.json"
BW_LIMIT="1M" # Default to a safe 1MB/s to prevent network collapse
CHECKSUM=""

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--checksum) CHECKSUM="-c"; shift ;;
        --limit)       BW_LIMIT="$2"; shift 2 ;;
        --burst)       BW_LIMIT=""; shift ;;
        *.json)        CONF="$1"; shift ;;
        *) echo "Unknown arg: $1"; usage ;;
    esac
done

[[ ! -f "$CONF" ]] && { echo "Error: Config $CONF not found"; exit 1; }

# --- Load Config ---
eval "$(jq -r '@sh "L_ROOT=\(.local_root) R_ROOT=\(.remote_root)"' "$CONF")"
L_ROOT="${L_ROOT/#\~/$HOME}"

# --- Setup Rsync Flags ---
# -a: archive, -z: compress, -h: human-readable
# --info=progress2: Total job progress
# --partial: keep partially transferred files
OPTS=("-azh" "--info=progress2" "--partial")
[[ -n "$CHECKSUM" ]] && OPTS+=("$CHECKSUM")

# Bandwidth Limiting
if [[ -n "$BW_LIMIT" ]]; then
    echo ">> Limiting speed to $BW_LIMIT to prevent network timeouts."
    OPTS+=("--bwlimit=$BW_LIMIT")
fi

case "$MODE" in
    backup)  SRC="$L_ROOT"; DST="$R_ROOT"; OPTS+=("--delete") ;;
    restore) SRC="$R_ROOT"; DST="$L_ROOT"; OPTS+=("-u") ;;
    dry-run) SRC="$L_ROOT"; DST="$R_ROOT"; OPTS+=("--delete" "--dry-run") ;;
    *) usage ;;
esac

# --- Execution ---
TMP_EXC=$(mktemp)
trap 'rm -f "$TMP_EXC"' EXIT
jq -r '.exclude[]?' "$CONF" > "$TMP_EXC"

mapfile -t paths < <(jq -r '.paths[]' "$CONF")

echo "--- Starting $MODE ---"
for p in "${paths[@]}"; do
    rel_path=$(echo "$p" | sed 's|^/*||; s|^~/*||')
    
    slash=""
    [[ -d "$L_ROOT/$rel_path" ]] && slash="/"

    # Create remote parent directory
    if [[ "$MODE" == "backup" && "$R_ROOT" == *":"* ]]; then
        host="${R_ROOT%%:*}"
        rem_dir="${R_ROOT#*:}/$(dirname "$rel_path")"
        ssh "$host" "mkdir -p '$rem_dir'"
    elif [[ "$MODE" == "backup" ]]; then
        mkdir -p "$(dirname "$R_ROOT/$rel_path")"
    fi

    echo ">> Syncing: $rel_path"
    
    # ionice -c 3: Only uses disk when system is idle
    # nice -n 19: Lowest CPU priority
    ionice -c 3 nice -n 19 rsync "${OPTS[@]}" \
          --exclude-from="$TMP_EXC" \
          "$SRC/$rel_path$slash" \
          "$DST/$rel_path$slash"
done

echo "Operation complete."