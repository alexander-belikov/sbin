#!/bin/bash
# Export every variable defined in an env file into the current shell (set -a).
# Use: `source load-env.sh /path/to/.env` — do not execute with ./ (child process would not persist exports).
if [[ $# -ne 1 ]]; then
    echo "Usage: source ${BASH_SOURCE[0]} <env_file>" >&2
    exit 1
fi
if [[ ! -f "$1" ]]; then
    echo "Error: not a file: $1" >&2
    exit 1
fi
set -a
# shellcheck source=SC1090
source "$1"
set +a
