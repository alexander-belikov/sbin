#!/bin/bash
# Multi-path rsync driver: reads local/remote roots, path list, and excludes from JSON.
# Depends: jq, rsync; remote targets use ssh when DST contains ':' (host:path).

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <mode> [config.json] [--checksum]

MODES:
  backup   Push local -> remote (deletes on remote extra files under synced paths)
  restore  Pull remote -> local (-u: skip files newer on local)
  dry-run  Default if mode is anything else: show what backup would do

OPTIONS:
  --checksum, -c   Rsync -c: compare by checksum (slower, stricter than mtime/size)

Config JSON keys:
  local_root, remote_root, paths[] (relative to roots), exclude[] (optional)

Example active_paths.json:
  { "local_root": "~/data", "remote_root": "host:backups/data",
    "paths": ["photos", "docs"], "exclude": [".DS_Store", "*.tmp"] }
EOF
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required." >&2; exit 1; }
command -v rsync >/dev/null 2>&1 || { echo "Error: rsync is required." >&2; exit 1; }

MODE=$1
CONF="active_paths.json"
USE_CHECKSUM=false

shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --checksum|-c) USE_CHECKSUM=true; shift ;;
        *.json) CONF="$1"; shift ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ ! -f "$CONF" ]]; then
    echo "Error: config not found: $CONF" >&2
    exit 1
fi

# Tilde only expanded on local side; remote_root is passed to rsync as-is
L_ROOT=$(jq -r '.local_root' "$CONF" | sed "s|^~|$HOME|")
R_ROOT=$(jq -r '.remote_root' "$CONF")

BASE_OPTS=(-azh --info=progress2)
if [[ "$USE_CHECKSUM" == true ]]; then
    echo ">> Checksum comparison enabled (slower) <<"
    BASE_OPTS+=(-c)
fi

RUN=false
case "$MODE" in
    backup)
        echo "!! BACKUP: $L_ROOT -> $R_ROOT !!"
        SRC="$L_ROOT"
        DST="$R_ROOT"
        OPTS=("${BASE_OPTS[@]}" --delete)
        RUN=true
        ;;
    restore)
        echo "!! RESTORE: $R_ROOT -> $L_ROOT !!"
        SRC="$R_ROOT"
        DST="$L_ROOT"
        OPTS=("${BASE_OPTS[@]}" -u)
        RUN=true
        ;;
    *)
        echo ">> DRY-RUN (use backup or restore to apply) <<"
        SRC="$L_ROOT"
        DST="$R_ROOT"
        OPTS=("${BASE_OPTS[@]}" --delete --dry-run)
        ;;
esac

TMP_EXC=$(mktemp)
trap 'rm -f "$TMP_EXC"' EXIT
jq -r '.exclude[]?' "$CONF" >"$TMP_EXC"

mapfile -t paths < <(jq -r '.paths[]' "$CONF")

for p in "${paths[@]}"; do
    rel_path=$(echo "$p" | sed 's|^/||;s|^\~\/||;s|/$||')

    src_suffix=""
    dst_suffix=""
    if [[ -d "$L_ROOT/$rel_path" ]]; then
        src_suffix="/"
        dst_suffix="/"
    fi

    dest_dir="$DST/$(dirname "$rel_path")"
    if [[ "$dest_dir" == *":"* ]]; then
        host="${dest_dir%%:*}"
        rem_p="${dest_dir#*:}"
        if $RUN; then
            ssh "$host" "mkdir -p -- '$rem_p'"
        fi
    else
        if $RUN; then
            mkdir -p "$dest_dir"
        fi
    fi

    echo "--- Syncing: $rel_path ---"
    rsync "${OPTS[@]}" --exclude-from="$TMP_EXC" \
        "$SRC/$rel_path$src_suffix" \
        "$DST/$rel_path$dst_suffix"
done

echo ""
echo "Operation complete."
