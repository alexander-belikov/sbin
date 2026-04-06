# sbin

Small Bash utilities for backups, file cleanup, env loading, and media/font chores. Scripts live in [`src/`](src/).

## Scripts

| Script | Purpose |
|--------|---------|
| [`rsync-adv.sh`](src/rsync-adv.sh) | Drive **rsync** over many paths from a **JSON** config (`local_root`, `remote_root`, `paths[]`, optional `exclude[]`). Modes: **`backup`** (push + `--delete`), **`restore`** (pull + `-u`), **`dry-run`** (preview backup with `--delete --dry-run`). Options: **`-c` / `--checksum`**, **`--limit`** (value passed to rsync as **`--bwlimit=`**, e.g. `500K`, `10M`; behavior depends on your **rsync**—many builds want **KiB/s** as an integer). Uses **`jq`**; **`ssh`** when **`remote_root`** is `host:path` or `user@host:path` to create parent dirs on **backup** only. Progress: **`-P`**. Default config file: `active_paths.json` if you omit a `*.json` argument. Sample: [`examples/backup.test.json`](examples/backup.test.json). |
| [`delete-present.sh`](src/delete-present.sh) | Delete files under **dir A** when a matching file exists under **dir B** (default: same **basename + size**; `--content-only`: **MD5** match, any name). **dir B** is never deleted. |
| [`load-env.sh`](src/load-env.sh) | **`source`** a file with `set -a` so all variables are **exported** into the current shell. Use `source src/load-env.sh /path/.env`, not `./load-env.sh`. |
| [`rename-dates.sh`](src/rename-dates.sh) | In a given directory, rename `IMG_YYYYMMDD_HHMMSS[_suffix].ext` to `YYYY-MM-DD HH.MM.SS.ext` (handles collisions with `-2`, `-3`, …). |
| [`pdf-to-png.sh`](src/pdf-to-png.sh) | Convert every **`.pdf`** in an input directory to **PNG** pages via **pdftoppm** (install **poppler-utils**). Optional third argument: **DPI** (default **300**). |
| [`get-nerd-fonts.sh`](src/get-nerd-fonts.sh) | Download named **Nerd Fonts** release ZIPs and move **`.ttf`** files into **`~/.local/share/fonts`** (or **`$XDG_DATA_HOME/fonts`**), then **`fc-cache -fv`**. |
| [`columnize-files.sh`](src/columnize-files.sh) | Pretty-print delimiter-separated files with **`column -t`**. Default separator **comma**; **`-s`** to change. Writes **`tabbed_<basename>`** beside each file, or under **`-o DIR`**. |

## Requirements

- **bash** (scripts use `set -euo pipefail` where noted).
- **jq** — `rsync-adv.sh` only.
- **rsync** / **OpenSSH client** — `rsync-adv.sh` when using remote paths.
- **poppler-utils** (`pdftoppm`) — `pdf-to-png.sh`.
- **wget**, **unzip**, **fontconfig** — `get-nerd-fonts.sh`.

`delete-present.sh` uses **GNU** `stat -c%s` and **`md5sum`** (typical on Linux).

## Examples

```bash
# Preview backup using the sample JSON in examples/
./src/rsync-adv.sh dry-run ./examples/backup.test.json

# Or use your own config beside the script
./src/rsync-adv.sh dry-run ./my-paths.json

# Dry-run with checksums and a bandwidth limit (see rsync --bwlimit on your system)
./src/rsync-adv.sh dry-run ./my-paths.json -c --limit 8192

# Export variables from a dotenv file into current shell
source ./src/load-env.sh /path/to/.env

# Remove duplicates from a download folder using a “known good” folder
./src/delete-present.sh ~/Downloads/temp ~/Media/reference --content-only

# Install two Nerd Fonts families
./src/get-nerd-fonts.sh JetBrainsMono FiraCode
```
