# clips

A self-hosted Loom replacement. Record with Screen Studio, get a nice shareable link.

- **render.py** rebuilds a Screen Studio project from its raw tracks (`*.screenstudio/recording/`): screen, a redrawn cursor with click rings (from `mousemoves-0.json` / `mouseclicks-0.json`), a rounded facecam in the bottom right, and mic + system audio. It works even when Screen Studio's own export is blocked.
- **add-clip.sh** encodes any mp4 to HLS, builds a player page, deploys to Vercel and prints `https://<origin>/<slug>`.
- **post-latest.sh "Title"** does both for the newest Screen Studio recording.

The player starts at 1.25x, shows how much time each speed saves, has keyboard shortcuts, and link previews with a poster frame. Pages are `noindex`, and slugs are random.

## Owner editing
`/<slug>` is served by `api/page.js`, which swaps in a title stored in a private Vercel Blob store. Open any clip once with `?key=<ADMIN_KEY>` and that browser can click the title to rename it.

## Setup
```bash
npm i
vercel link
vercel blob create-store clips-meta --access private --yes
vercel env add ADMIN_KEY production   # any long random string; keep a copy in .adminkey
CLIPS_ORIGIN=https://your-domain ./post-latest.sh "My first clip"
```
Needs ffmpeg (with VideoToolbox, so macOS) and Python 3.
