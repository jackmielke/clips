#!/bin/zsh
# Usage: ./post-latest.sh ["Title"]  — renders the newest Screen Studio recording (cursor + facecam) and posts it.
set -e
cd "${0:A:h}"
PROJ=$(ls -dt ~/Screen\ Studio\ Projects/*.screenstudio | head -1)
OUT=~/Desktop/"$(basename "$PROJ" .screenstudio)-facecam.mp4"
python3 render.py "$PROJ" "$OUT"
./add-clip.sh "$OUT" "${1:-Untitled clip}"
