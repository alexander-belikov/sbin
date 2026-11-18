#!/bin/bash
# Mirror a set of paths to an rsync target, and read the mirror back.
# Docs: rsync-adv.md next to this script.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [config.json] [target] [options]

Write (take a lock, log to \$STATE_DIR):
  backup               mirror config paths to remote (--delete --delete-excluded),
                       then upload the encrypted secrets bundle if configured
  dry-run              show what backup would change (nothing is written)
  restore              pull config paths back over the local root (-u, never deletes)

Read (never touch live files):
  snapshots            list remote ZFS snapshots
  ls [path]            list a remote directory
  fetch <path>         copy a remote file/dir into a staging dir
  restore-secrets      download and decrypt the secrets bundle into a staging dir
  index                save a compressed listing of every remote file
  find <regex>         grep the newest index offline
  mount [dir]          read-only sshfs mount of the remote account (default ~/mnt/backup)
  umount [dir]

Options:
  -c, --checksum       compare by checksum (slower)
  --limit <speed>      bandwidth limit (default 1M; e.g. 500K, 20M)
  --burst              no bandwidth limit
  --snapshot <date>    read from snapshot daily_<date> (or a full snapshot name)
  --to <dir>           staging dir for fetch / restore-secrets (default ~/restore/<live|snapshot>)
  --identity <file>    age identity for restore-secrets (default: identity.age from the bundle)
  -h, --help

Config: {"local_root": "~", "remote_root": "user@host:dir",
         "paths": ["a", {"path": "b", "exclude": ["pattern relative to b", ...]}],
         "exclude": ["global pattern", ...],
         "secrets": {"paths": [...], "recipients": "~/.config/age/backup.pub",
                     "identity": "~/.config/age/identity.age"}}
EOF
    exit "${1:-1}"
}

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }
expand_home() { local p="$1"; echo "${p/#\~/$HOME}"; }
norm_path() { local p="$1"; p="${p#\~}"; p="${p#"${p%%[!/]*}"}"; echo "$p"; }  # drop ~ and leading /
need() { command -v "$1" >/dev/null || die "'$1' is not installed${2:+ ($2)}"; }

[[ $# -lt 1 ]] && usage
case "$1" in -h|--help) usage 0 ;; esac

MODE=$1; shift
CONF=""
TARGET=""
BW_LIMIT="1M"   # safe default; --limit / --burst override
CHECKSUM=0
SNAPSHOT=""
TO=""
IDENTITY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--checksum) CHECKSUM=1; shift ;;
        --limit)       BW_LIMIT="${2:?--limit needs a value}"; shift 2 ;;
        --burst)       BW_LIMIT=""; shift ;;
        --snapshot)    SNAPSHOT="${2:?--snapshot needs a value}"; shift 2 ;;
        --to)          TO="${2:?--to needs a value}"; shift 2 ;;
        --identity)    IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
        -h|--help)     usage 0 ;;
        -*)            echo "Unknown option: $1" >&2; usage ;;
        *)
            if [[ -z "$CONF" && "$1" == *.json ]]; then CONF="$1"
            elif [[ -z "$TARGET" ]]; then TARGET="$1"
            else echo "Unexpected argument: $1" >&2; usage
            fi
            shift ;;
    esac
done

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/rsync-adv"
mkdir -p "$STATE_DIR"

# --- Commands that need no config ---
if [[ "$MODE" == "umount" ]]; then
    dir="$(expand_home "${TARGET:-$HOME/mnt/backup}")"
    fusermount3 -u "$dir" 2>/dev/null || fusermount -u "$dir"
    exit 0
fi

CONF="${CONF:-active_paths.json}"
[[ -f "$CONF" ]] || die "config $CONF not found"
CONF_NAME="$(basename "$CONF" .json)"

# --- Load config ---
L_ROOT="$(expand_home "$(jq -r '.local_root' "$CONF")")"
R_ROOT="$(jq -r '.remote_root' "$CONF")"
L_ROOT="${L_ROOT%/}"; R_ROOT="${R_ROOT%/}"

R_HOST=""; R_PATH="$R_ROOT"
if [[ "$R_ROOT" =~ ^[^/]+: ]]; then
    R_HOST="${R_ROOT%%:*}"
    R_PATH="${R_ROOT#*:}"
fi

# Remote base to read from: the live mirror, or the same directory inside a ZFS snapshot.
read_base() {
    if [[ -z "$SNAPSHOT" ]]; then echo "$R_ROOT"; return; fi
    [[ -n "$R_HOST" ]] || die "--snapshot needs a remote (host:path) root"
    [[ "$R_PATH" != /* ]] || die "--snapshot needs a home-relative remote path"
    local name="$SNAPSHOT"
    [[ "$name" == *_* ]] || name="daily_$name"
    echo "$R_HOST:.zfs/snapshot/$name/$R_PATH"
}
stage_dir() { expand_home "${TO:-$HOME/restore/${SNAPSHOT:-live}}"; }

COMMON=("-ah")
[[ -n "$R_HOST" ]] && COMMON+=("-z" "--compress-choice=zstd")
(( CHECKSUM )) && COMMON+=("-c")
if [[ -n "$BW_LIMIT" ]]; then COMMON+=("--bwlimit=$BW_LIMIT"); fi
if [[ -t 1 ]]; then COMMON+=("--info=progress2"); else COMMON+=("--info=stats2"); fi

# rsync exit 24 = files vanished during transfer: routine on live trees, not a failure.
run_rsync() {
    local rc=0
    ionice -c 3 nice -n 19 rsync "$@" || rc=$?
    case $rc in
        0)  return 0 ;;
        24) warn "some files vanished during transfer (rsync exit 24)"; return 0 ;;
        *)  echo "Error: rsync exited with $rc${LOG:+; log: $LOG}" >&2; return "$rc" ;;
    esac
}

take_lock() {
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || die "another rsync-adv run holds $STATE_DIR/lock"
}

new_log() {
    LOG="$STATE_DIR/$MODE-$CONF_NAME-$(date +%Y%m%d-%H%M%S).log"
    # keep the 30 newest logs
    find "$STATE_DIR" -maxdepth 1 -name '*.log' -printf '%T@ %p\n' | sort -rn | tail -n +31 \
        | cut -d' ' -f2- | xargs -r rm --
}

# Writes global excludes, then each object path's excludes anchored under that path.
build_filters() {
    local out="$1"
    jq -r '.exclude[]?' "$CONF" > "$out"
    local p pat
    while IFS=$'\t' read -r p pat; do
        p="$(norm_path "$p")"; pat="${pat#/}"
        echo "/${p%/}/$pat" >> "$out"
    done < <(jq -r '.paths[] | select(type == "object") | .path as $p | (.exclude // [])[] | [$p, .] | @tsv' "$CONF")
}

load_paths() { mapfile -t PATHS < <(jq -r '.paths[] | if type == "string" then . else .path end' "$CONF"); }

# --- Secrets bundle: tar | zstd | age, uploaded as <remote>/secrets/ ---
secrets_configured() { jq -e '.secrets.paths | length > 0' "$CONF" >/dev/null 2>&1; }

secrets_check() {
    need age "needed for the secrets bundle"
    need zstd
    local recip; recip="$(expand_home "$(jq -r '.secrets.recipients // empty' "$CONF")")"
    [[ -n "$recip" && -f "$recip" ]] || die "secrets.recipients file '$recip' not found (see rsync-adv.md)"
}

secrets_backup() {
    local dry="$1" recip ident tmp p
    recip="$(expand_home "$(jq -r '.secrets.recipients' "$CONF")")"
    ident="$(expand_home "$(jq -r '.secrets.identity // empty' "$CONF")")"
    local members=()
    while IFS= read -r p; do
        p="$(norm_path "$p")"
        if [[ -e "$L_ROOT/$p" ]]; then members+=("$p"); else warn "secret path $p missing, skipped"; fi
    done < <(jq -r '.secrets.paths[]' "$CONF")
    (( ${#members[@]} )) || { warn "no secret paths exist; bundle skipped"; return 0; }
    if [[ "$dry" == 1 ]]; then
        echo ">> Would upload encrypted bundle of: ${members[*]}"
        return 0
    fi
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/secrets"
    tar -C "$L_ROOT" -cf - "${members[@]}" | zstd -q | age -R "$recip" > "$tmp/secrets/secrets.tar.zst.age"
    if [[ -n "$ident" ]]; then
        if [[ -f "$ident" ]]; then cp "$ident" "$tmp/secrets/identity.age"
        else warn "secrets.identity '$ident' not found; bundle uploaded without it"; fi
    fi
    echo ">> Uploading secrets bundle (${members[*]})"
    run_rsync "${COMMON[@]}" -R --log-file="$LOG" "$tmp/./secrets/" "$R_ROOT/" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

# --- Commands ---
case "$MODE" in
backup|dry-run|restore)
    take_lock
    new_log
    load_paths
    FILTERS="$(mktemp)"; trap 'rm -f "$FILTERS"' EXIT
    build_filters "$FILTERS"
    OPTS=("${COMMON[@]}" "-R" "--partial-dir=.rsync-partial" "--exclude-from=$FILTERS" "--log-file=$LOG")
    SRCS=()
    if [[ "$MODE" == restore ]]; then
        [[ -z "$SNAPSHOT" ]] || die "restore reads the live mirror; use fetch --snapshot for snapshots"
        OPTS+=("-u")
        for p in "${PATHS[@]}"; do SRCS+=("$R_ROOT/./$(norm_path "$p")"); done
        DST="$L_ROOT/"
    else
        DRY=0; [[ "$MODE" == dry-run ]] && DRY=1
        secrets_configured && { if (( DRY )); then command -v age >/dev/null || warn "age not installed"; else secrets_check; fi; }
        OPTS+=("--delete" "--delete-excluded")
        (( DRY )) && OPTS+=("--dry-run" "-i")
        for p in "${PATHS[@]}"; do
            p="$(norm_path "$p")"
            # A missing source would make rsync skip deletions anyway; skipping keeps its remote copy.
            if [[ -e "$L_ROOT/$p" ]]; then SRCS+=("$L_ROOT/./$p"); else warn "$p missing locally, skipped"; fi
        done
        DST="$R_ROOT/"
    fi
    [[ -n "$BW_LIMIT" ]] && echo ">> Bandwidth limit $BW_LIMIT"
    echo "--- $MODE: ${#SRCS[@]} paths, log $LOG ---"
    run_rsync "${OPTS[@]}" "${SRCS[@]}" "$DST"
    if [[ "$MODE" != restore ]] && secrets_configured; then
        secrets_backup "$DRY"
    fi
    [[ "$MODE" == backup ]] && date -Is > "$STATE_DIR/last-success-$CONF_NAME"
    echo "Done. Log: $LOG"
    ;;

snapshots)
    [[ -n "$R_HOST" ]] || die "snapshots needs a remote root"
    ssh "$R_HOST" ls .zfs/snapshot
    ;;

ls)
    base="$(read_base)"
    p="$(norm_path "$TARGET")"
    rsync --list-only "$base/${p:+$p/}" 2>/dev/null || rsync --list-only "$base/$p"
    ;;

fetch)
    [[ -n "$TARGET" ]] || die "fetch needs a path"
    base="$(read_base)"; dst="$(stage_dir)"
    mkdir -p "$dst"
    LOG=""
    run_rsync "${COMMON[@]}" -R "$base/./$(norm_path "$TARGET")" "$dst/"
    echo "Fetched into $dst/$(norm_path "$TARGET")"
    ;;

restore-secrets)
    need age; need zstd
    base="$(read_base)"; dst="$(stage_dir)/secrets"
    mkdir -p "$dst/files"; chmod 700 "$dst"
    LOG=""
    run_rsync "${COMMON[@]}" "$base/secrets/" "$dst/"
    ident="${IDENTITY:+$(expand_home "$IDENTITY")}"
    if [[ -z "$ident" ]]; then
        [[ -f "$dst/identity.age" ]] || die "no identity.age in the bundle; pass --identity <key file>"
        echo ">> Decrypting identity.age (passphrase prompt)"
        age -d -i <(age -d "$dst/identity.age") "$dst/secrets.tar.zst.age" | zstd -dq | tar -C "$dst/files" -xf -
    else
        age -d -i "$ident" "$dst/secrets.tar.zst.age" | zstd -dq | tar -C "$dst/files" -xf -
    fi
    echo "Secrets extracted into $dst/files (copy what you need; nothing was overwritten)"
    ;;

index)
    need zstd
    base="$(read_base)"
    out="$STATE_DIR/index-$CONF_NAME${SNAPSHOT:+-$SNAPSHOT}-$(date +%Y%m%d).zst"
    rsync -r --list-only "$base/" | zstd -q -f -o "$out"
    echo "Index: $out ($(zstd -dc "$out" | wc -l) entries)"
    ;;

find)
    [[ -n "$TARGET" ]] || die "find needs a regex"
    need zstd
    idx="$(find "$STATE_DIR" -maxdepth 1 -name "index-$CONF_NAME-*.zst" -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
    [[ -n "$idx" ]] || die "no index for $CONF_NAME yet; run: $(basename "$0") index $CONF"
    echo ">> $(basename "$idx")" >&2
    zstd -dc "$idx" | grep -E -- "$TARGET" || true
    ;;

mount)
    need sshfs "needed for mount"
    [[ -n "$R_HOST" ]] || die "mount needs a remote root"
    dir="$(expand_home "${TARGET:-$HOME/mnt/backup}")"
    mkdir -p "$dir"
    sshfs -o ro,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 "$R_HOST:" "$dir"
    echo "Mounted read-only at $dir: live mirror in $dir/$R_PATH, snapshots in $dir/.zfs/snapshot/*/$R_PATH"
    ;;

*) usage ;;
esac
