#!/bin/zsh
# One-time switch to R2: checks .env.r2, opens the bucket to the clip pages (CORS), tells Vercel where
# videos live, moves every existing clip's video to R2, and redeploys. Safe to run again.
set -e
cd "${0:A:h}"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -f .env.r2 ] || { echo "Fill in .env.r2 first (see r2.py for the fields)"; exit 1; }
URL=$(sed -n 's/^R2_PUBLIC_URL=//p' .env.r2 | tr -d '"'"'"' ' | sed 's:/*$::')
[ -n "$URL" ] || { echo ".env.r2 is missing R2_PUBLIC_URL"; exit 1; }
python3 r2.py check
python3 r2.py cors
npx --yes vercel@latest env rm CLIPS_MEDIA_URL production --yes >/dev/null 2>&1 || true
printf %s "$URL" | npx --yes vercel@latest env add CLIPS_MEDIA_URL production >/dev/null
./offload-media.sh
npx --yes vercel@latest deploy --prod --yes >/dev/null
echo "R2 is on: videos are served from $URL"
