#!/bin/bash
# Download Nerd Fonts release ZIPs from GitHub and install .ttf files to ~/.local/share/fonts.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <font_name> [font_name ...]" >&2
    echo "  Example: $0 JetBrainsMono FiraCode" >&2
    echo "  Names must match release assets: https://github.com/ryanoasis/nerd-fonts/releases" >&2
    exit 1
fi

fonts_dir="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
mkdir -p "$fonts_dir"

for font in "$@"; do
    zip_file="${font}.zip"
    url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${zip_file}"
    tmp_zip=$(mktemp "/tmp/nerdfont_${font}.XXXXXX.zip")
    tmp_dir=$(mktemp -d "/tmp/nerdfont_${font}.XXXXXX")

    finish() {
        rm -f "$tmp_zip"
        rm -rf "$tmp_dir"
    }

    echo "Downloading $url"
    if ! wget -q --show-progress -O "$tmp_zip" "$url"; then
        finish
        echo "Error: download failed for $font" >&2
        exit 1
    fi
    unzip -q "$tmp_zip" -d "$tmp_dir"

    shopt -s nullglob
    ttf=( "$tmp_dir"/*.ttf )
    shopt -u nullglob
    if [[ ${#ttf[@]} -eq 0 ]]; then
        finish
        echo "Warning: no .ttf files in $zip_file (check font name / archive layout)." >&2
        continue
    fi
    mv -- "${ttf[@]}" "$fonts_dir/"
    finish
    echo "Installed ${#ttf[@]} font(s) from $font"
done

fc-cache -fv
