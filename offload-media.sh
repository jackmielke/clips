#!/bin/zsh
# Usage: ./offload-media.sh [slug ...]  — upload clip videos to R2 and take them out of the Vercel deploy.
# With no slugs it moves every clip (the one-time migration). Posters stay in public/v/ for link previews.
# Does nothing until .env.r2 exists (see setup-r2.sh), so posting works the same without R2.
set -e
cd "${0:A:h}"
[ -f .env.r2 ] || exit 0
slugs=("$@")
[ ${#slugs} -gt 0 ] || slugs=(${(f)"$(ls public/v 2>/dev/null)"})
for slug in $slugs; do
  dir="public/v/$slug"
  [ -d "$dir" ] || continue
  mkdir -p "media/v/$slug"
  for f in "$dir"/*(N.); do
    name="${f:t}"
    [ "$name" = "poster.jpg" ] && continue
    python3 r2.py put "$f" "v/$slug/$name"
    mv "$f" "media/v/$slug/$name"   # keep a local copy, outside the deploy
  done
done
