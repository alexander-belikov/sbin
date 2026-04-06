#!/bin/bash
# Remove files in DIR_A that have a "duplicate" in DIR_B (by basename+size, or by content hash).

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <dir_a> <dir_b> [--content-only]

  dir_a            Files under this tree may be deleted.
  dir_b            Reference tree; never modified.
  --content-only   Match by MD5 content (any name). Default: same basename + file size only.

Deletes files in dir_a only; does not remove anything from dir_b.
EOF
    exit 1
}

if [[ $# -lt 2 ]] || [[ $# -gt 3 ]]; then
    usage
fi

DIR_A="$1"
DIR_B="$2"
CONTENT_ONLY=false

if [[ $# -eq 3 ]]; then
    if [[ "$3" == "--content-only" ]]; then
        CONTENT_ONLY=true
    else
        echo "Unknown option: $3" >&2
        usage
    fi
fi

if [[ ! -d "$DIR_A" || ! -d "$DIR_B" ]]; then
    echo "Error: both arguments must be existing directories." >&2
    exit 1
fi

echo "Scanning $DIR_A against $DIR_B ..."
echo "Content-only mode: $CONTENT_ONLY"

if $CONTENT_ONLY; then
    echo "Building checksum map for $DIR_B ..."
    declare -A checksums_b
    while IFS= read -r -d '' file; do
        hash=$(md5sum "$file" | awk '{print $1}')
        checksums_b["$hash"]=1
    done < <(find "$DIR_B" -type f -print0)

    echo "Checking files in $DIR_A ..."
    while IFS= read -r -d '' file; do
        hash=$(md5sum "$file" | awk '{print $1}')
        if [[ ${checksums_b[$hash]+isset} ]]; then
            echo "Deleting $file (duplicate content)"
            rm -- "$file"
        fi
    done < <(find "$DIR_A" -type f -print0)
else
    echo "Building file map for $DIR_B (basename + size) ..."
    declare -A files_b
    while IFS= read -r -d '' file; do
        key="$(basename "$file")_$(stat -c%s "$file")"
        files_b["$key"]=1
    done < <(find "$DIR_B" -type f -print0)

    echo "Checking files in $DIR_A ..."
    while IFS= read -r -d '' file; do
        key="$(basename "$file")_$(stat -c%s "$file")"
        if [[ ${files_b[$key]+isset} ]]; then
            echo "Deleting $file (duplicate basename+size)"
            rm -- "$file"
        fi
    done < <(find "$DIR_A" -type f -print0)
fi

echo "Done."
