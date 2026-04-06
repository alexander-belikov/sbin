#!/bin/bash
# Turn delimiter-separated text files into column-aligned tables (uses column(1)).
# Writes tabbed_<basename> next to each input file unless -o is set.

set -euo pipefail

SEP=','
OUT_DIR=""

usage() {
    cat <<EOF
Usage: $0 [-s SEP] [-o OUT_DIR] FILE [FILE ...]

  -s SEP     Input field separator (default: comma). Passed to column -s.
  -o DIR     Write outputs under DIR as tabbed_<basename> (default: same dir as each FILE).

Example:
  $0 -o /tmp/reports /data/*.report_*
EOF
    exit 1
}

while getopts "s:o:h" opt; do
    case "$opt" in
        s) SEP="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        h|\?) usage ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -lt 1 ]]; then
    usage
fi

if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
fi

for f in "$@"; do
    if [[ ! -f "$f" ]]; then
        echo "Skip (not a regular file): $f" >&2
        continue
    fi
    base=$(basename -- "$f")
    if [[ -n "$OUT_DIR" ]]; then
        dest="$OUT_DIR/tabbed_$base"
    else
        dest="$(dirname -- "$f")/tabbed_$base"
    fi
    column -s "$SEP" -t "$f" > "$dest"
    echo "Wrote $dest"
done
