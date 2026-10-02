#!/bin/zsh
# Usage: ./add-clip.sh <video.mp4> "Title" [existing-slug]
# Encodes to HLS, builds public/c/<slug>.html, deploys to Vercel, prints the link.
set -e
cd "${0:A:h}"
IN="$1"; TITLE="${2:-Untitled clip}"; SLUG="${3:-$(openssl rand -hex 4)}"
ORIGIN="${CLIPS_ORIGIN:-https://jack-clips.vercel.app}"
OUT="public/v/$SLUG"
if [ ! -f "$OUT/index.m3u8" ]; then
  mkdir -p "$OUT"
  ffmpeg -hide_banner -loglevel error -y -i "$IN" -vf "scale='min(1920,iw)':-2" -c:v h264_videotoolbox -b:v 3M -maxrate 4M -g 60 \
    -c:a aac -ac 2 -ar 48000 -b:a 128k -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename "$OUT/s%03d.ts" "$OUT/index.m3u8"
  ffmpeg -hide_banner -loglevel error -y -ss 5 -i "$IN" -frames:v 1 -vf scale=1280:-2 -q:v 4 "$OUT/poster.jpg"
fi
SECS=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN" | cut -d. -f1)
DUR="$((SECS/60)):$(printf %02d $((SECS%60)))"
read W H <<< "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$IN" | tr x ' ')"
DATE=$(date -r "$IN" "+%b %-d, %Y")
mkdir -p public/c
sed -e "s|{{TITLE}}|$TITLE|g" -e "s|{{SLUG}}|$SLUG|g" -e "s|{{ORIGIN}}|$ORIGIN|g" -e "s|{{DURATION}}|$DUR|g" \
    -e "s|{{DATE}}|$DATE|g" -e "s|{{SECS}}|$SECS|g" -e "s|{{ASPECT}}|$W / $H|g" template.html > "public/c/$SLUG.html"
python3 register-clip.py "$SLUG" "$TITLE" "$SECS" "$W" "$H" "$(date -r "$IN" -u +%Y-%m-%dT%H:%M:%SZ)"
[ -f public/index.html ] || echo '<!doctype html><meta name="robots" content="noindex"><title>Clips</title>' > public/index.html
npx --yes vercel@latest deploy --prod --yes >/dev/null
echo "$ORIGIN/$SLUG"
