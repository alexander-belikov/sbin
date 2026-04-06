#!/bin/bash
# Rasterize each PDF in INPUT_DIR to PNG pages via pdftoppm (poppler-utils).

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <input_dir> <output_dir> [dpi]" >&2
    echo "  dpi defaults to 300. Requires: pdftoppm (package: poppler-utils on Debian/Ubuntu)." >&2
    exit 1
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"
DPI="${3:-300}"

if ! command -v pdftoppm >/dev/null 2>&1; then
    echo "Error: pdftoppm not found. Install poppler-utils." >&2
    exit 1
fi

if [[ ! "$DPI" =~ ^[0-9]+$ ]] || [[ "$DPI" -lt 1 ]]; then
    echo "Error: DPI must be a positive integer." >&2
    exit 1
fi

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "Error: input directory does not exist: $INPUT_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

shopt -s nullglob
for pdf_file in "$INPUT_DIR"/*.pdf; do
    filename=$(basename -- "$pdf_file")
    name="${filename%.*}"
    echo "Processing: $filename"
    pdftoppm -png -r "$DPI" "$pdf_file" "$OUTPUT_DIR/${name}_page"
done
shopt -u nullglob

echo "All done."
