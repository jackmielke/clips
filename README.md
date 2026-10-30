# clips

A self-hosted Loom replacement for macOS. Record with the native Clips app (or Screen Studio), press Finish, and get a clean shareable link on your own Vercel. You get a player that starts at 1.25x and shows the time saved, your cursor and click rings redrawn, a rounded facecam, titles you can edit, and a private library.

- **render.py** rebuilds a Screen Studio project from its raw tracks (`*.screenstudio/recording/`): screen, a redrawn cursor with click rings (from `mousemoves-0.json` / `mouseclicks-0.json`), a rounded facecam in the bottom right, and mic + system audio. It works even when Screen Studio's own export is blocked.
- **add-clip.sh** publishes one faststart mp4 (copied as-is from render.py, encoded once otherwise), builds a player page, deploys to Vercel and prints `https://<origin>/<slug>`.
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
export CLIPS_ORIGIN=https://your-project.vercel.app   # used for link previews
./post-latest.sh "My first clip"
```
Needs macOS, ffmpeg (with VideoToolbox), Python 3, Node, and the Vercel CLI. The Mac app expects the repo at `~/dev/clips` (`AppModel.repo`). Swap `public/jm-logo.png` for your own favicon.

## Password gate
`middleware.js` locks the home page, which lists every clip, behind one shared password: `fun` unless `SITE_PASSWORD` is set in Vercel. Share links (`/<slug>`, `/v/...`) stay open. Without the password the home page shows only the clips that browser has opened before (`public/seen.js` remembers them). A right answer is remembered for a year, and the owner key (`?key=` or the clipKey cookie) skips it.

## Library
`/library` lists every clip for whoever holds the key (same `?key=` sign-in). The list comes from `api/_clips.json`, which `add-clip.sh` updates and which is bundled into the function, so it is never served as a public file. It is gitignored like the clips themselves.

## Mac app (`mac/`)
A native recorder: a floating dark-glass bar (display, camera, mic and computer-audio toggles, Record), a live camera bubble you can drag, and a 3-2-1 countdown. Finish posts the clip and copies the link; the done bar lets you rename the clip (uses `.adminkey`) and copy the link again, and the menu bar icon's right-click menu has Copy Last Link. Pause leaves the paused stretch out of the clip on every track. ⌥⇧R toggles recording and ⌥⇧P pauses or resumes from anywhere, and `open clips://toggle|start|stop|pause` does the same from scripts. It writes the Screen Studio folder layout to `~/Movies/Clips/`, so `render.py` handles both recorders. Build with `mac/build.sh` (installs to /Applications). It needs Screen Recording permission added with the + button in System Settings.

## Video storage (Cloudflare R2)
Vercel's free plan caps a deploy at 100 MB, and every deploy used to carry every video. With R2 set up, videos go to a bucket once and only small pages and posters are deployed; `/v/...` requests that aren't in the deploy are redirected to the bucket (`api/media.js`).
1. In Cloudflare: R2, create a bucket, turn on its Public Development URL, and create an R2 API token with Object Read & Write on that bucket.
2. Put the values in `.env.r2` (gitignored): `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `R2_PUBLIC_URL`.
3. In the bucket's Settings, CORS Policy, add `[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["Content-Length","Content-Range"],"MaxAgeSeconds":86400}]` (an Object Read & Write token can't set it).
4. Run `./setup-r2.sh` once. It sets CORS, adds `CLIPS_MEDIA_URL` to Vercel, moves existing videos to R2 (local copies go to `media/`), and redeploys. From then on `add-clip.sh` offloads each new clip itself.
