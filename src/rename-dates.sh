#!/bin/bash
# Rename camera-style files IMG_YYYYMMDD_HHMMSS[_suffix].ext to "YYYY-MM-DD HH.MM.SS.ext".
# Optional numeric suffix after the time (e.g. IMG_20240102_153045_001.jpg) is dropped.
# Collisions get -2, -3, ... before the extension.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/directory" >&2
    exit 1
fi

TARGET_DIR="$1"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: not a directory: $TARGET_DIR" >&2
    exit 1
fi

cd "$TARGET_DIR"

shopt -s nullglob
for file in IMG_*.*; do
    [[ ! "$file" =~ ^IMG_[0-9]{8}_[0-9]{6} ]] && continue

    filename=$(basename "$file")
    extension="${filename##*.}"
    base_name="${filename%.*}"

    datetime_part="${base_name#IMG_}"
    # Strip trailing _NNN burst/counter if present
    clean_datetime=$(echo "$datetime_part" | sed 's/_[0-9]*$//')

    date_part=$(echo "$clean_datetime" | cut -d'_' -f1)
    time_part=$(echo "$clean_datetime" | cut -d'_' -f2)

    if [[ -z "$date_part" || -z "$time_part" || ${#date_part} -ne 8 || ${#time_part} -ne 6 ]]; then
        echo "Skipping invalid name: $filename"
        continue
    fi

    formatted_date="${date_part:0:4}-${date_part:4:2}-${date_part:6:2}"
    formatted_time="${time_part:0:2}.${time_part:2:2}.${time_part:4:2}"
    base_filename="${formatted_date} ${formatted_time}"

    counter=1
    new_filename="${base_filename}.${extension}"
    while [[ -e "$new_filename" ]]; do
        counter=$((counter + 1))
        new_filename="${base_filename}-${counter}.${extension}"
    done

    echo "Renaming: $filename -> $new_filename"
    mv -n -- "$file" "$new_filename"
done
shopt -u nullglob

echo "Renaming complete."
