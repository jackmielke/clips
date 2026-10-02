#!/bin/zsh
# Usage: ./post.sh <project-dir> ["Title"]  — render a recording project and post it. Last line printed is the link.
set -e
cd "${0:A:h}"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
PROJ="$1"
OUT="$PROJ/clip.mp4"
python3 render.py "$PROJ" "$OUT"
echo "STAGE upload"
./add-clip.sh "$OUT" "${2:-Untitled clip}"
