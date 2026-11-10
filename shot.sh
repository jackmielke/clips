#!/bin/zsh
# Usage: ./shot.sh <image.png> [slug]  — upload one screenshot to R2 and print its link (last line).
# Passing the slug of an earlier shot replaces it in place (the Mac app does this after a markup), so the link stays the same.
# No Vercel deploy: /s/<slug> is a rewrite to api/shot.js, which redirects to the image in the bucket.
set -e
cd "${0:A:h}"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -f .env.r2 ] || { echo "error: screenshot links need R2 (.env.r2, see setup-r2.sh)" >&2; exit 1; }
IN="$1"; SLUG="${2:-$(openssl rand -hex 4)}"
[[ "$SLUG" =~ ^[0-9a-f]{8}$ ]] || { echo "error: slug must be 8 hex characters" >&2; exit 1; }
python3 r2.py put "$IN" "s/$SLUG.png"
echo "${CLIPS_ORIGIN:-https://jack-clips.vercel.app}/s/$SLUG"
