#!/bin/zsh
# Usage: ./add-clip.sh <video.mp4> "Title" [existing-slug]
# Builds public/v/<slug>/ (one faststart mp4 + poster) and public/c/<slug>.html, deploys to Vercel, prints the link.
set -e
cd "${0:A:h}"
IN="$1"; TITLE="${2:-Untitled clip}"; SLUG="${3:-$(openssl rand -hex 4)}"
ORIGIN="${CLIPS_ORIGIN:-https://jack-clips.vercel.app}"
OUT="public/v/$SLUG"
mkdir -p "$OUT"
# One mp4 serves both playback (streamed with range requests) and the "Save video" button.
# render.py already writes it at web size, so it is copied, not re-encoded; anything else gets one encode.
if [ ! -f "$OUT/save.mp4" ]; then
  read VC VW <<< "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width -of csv=s=x:p=0 "$IN" | tr x ' ')"
  if [ "$VC" = "h264" ] && [ "$VW" -le 1920 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$IN" -c copy -movflags +faststart "$OUT/save.mp4"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$IN" -vf "scale='min(1920,iw)':-2" -c:v h264_videotoolbox -b:v 5M -maxrate 6M \
      -c:a aac -ac 2 -b:a 160k -movflags +faststart "$OUT/save.mp4"
  fi
fi
[ -f "$OUT/poster.jpg" ] || ffmpeg -hide_banner -loglevel error -y -ss 5 -i "$IN" -frames:v 1 -vf scale=1280:-2 -q:v 4 "$OUT/poster.jpg"
SECS=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$IN" | cut -d. -f1)
DUR="$((SECS/60)):$(printf %02d $((SECS%60)))"
read W H <<< "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$IN" | tr x ' ')"
DATE=$(date -r "$IN" "+%b %-d, %Y")
mkdir -p public/c
sed -e "s|{{TITLE}}|$TITLE|g" -e "s|{{SLUG}}|$SLUG|g" -e "s|{{ORIGIN}}|$ORIGIN|g" -e "s|{{DURATION}}|$DUR|g" \
    -e "s|{{DATE}}|$DATE|g" -e "s|{{SECS}}|$SECS|g" -e "s|{{ASPECT}}|$W / $H|g" \
    -e "s|let speed = 1.25;|let speed = ${CLIP_SPEED:-1.25};|" \
    -e "${CLIP_SPEED:+s|let speed = $CLIP_SPEED;|let speed = $CLIP_SPEED; const FIXED_SPEED = true;|}" \
    -e "${CLIP_SPEED:+s|if (SPEEDS.includes(s)) speed = s;|/* fixed speed (CLIP_SPEED) */|}" template.html > "public/c/$SLUG.html"
python3 register-clip.py "$SLUG" "$TITLE" "$SECS" "$W" "$H" "$(date -r "$IN" -u +%Y-%m-%dT%H:%M:%SZ)"
python3 build-index.py
[ -n "$SKIP_DEPLOY" ] || npx --yes vercel@latest deploy --prod --yes >/dev/null
echo "$ORIGIN/$SLUG"
