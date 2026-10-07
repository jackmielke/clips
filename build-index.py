#!/usr/bin/env python3
"""build-index.py: render public/index.html, the public home page listing every clip in api/_clips.json
(newest first). Run by add-clip.sh before each deploy."""
import json, os, html
root = os.path.dirname(os.path.abspath(__file__))
clips = json.load(open(os.path.join(root, 'api/_clips.json')))
clips.sort(key=lambda c: c.get('created', ''), reverse=True)
def dur(s): return f"{s // 60}:{s % 60:02d}"
cards = []
for c in clips:
    t = html.escape(c['title']); d = c.get('created', '')[:10]
    portrait = c.get('h', 9) > c.get('w', 16)
    cards.append(f'''<a class="card{' tall' if portrait else ''}" href="/{c['slug']}">
  <div class="thumb"><img src="/v/{c['slug']}/poster.jpg" alt="" loading="lazy"><span class="dur">{dur(c['secs'])}</span></div>
  <div class="t">{t}</div><div class="d" data-d="{d}">{d}</div></a>''')
page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow"><title>Jack's clips</title>
<link rel="icon" type="image/png" href="/jm-logo.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root {{ --bg:#f6f5f2; --fg:#16161a; --muted:#6b6b73; --card:#ffffff; --line:#e4e2dc; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg:#0f0f11; --fg:#f2f2f3; --muted:#9a9aa3; --card:#18181b; --line:#2a2a2f; }} }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg); font-family:Inter, system-ui, sans-serif; -webkit-font-smoothing:antialiased; }}
  main {{ max-width:1180px; margin:0 auto; padding:40px 16px 64px; }}
  header {{ display:flex; align-items:center; gap:12px; margin-bottom:28px; }}
  header img {{ width:36px; height:36px; border-radius:9px; }}
  h1 {{ font-size:24px; font-weight:600; margin:0; letter-spacing:-.01em; }}
  .count {{ color:var(--muted); font-size:14px; margin-left:auto; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill, minmax(280px, 1fr)); gap:24px 20px; }}
  .card {{ color:inherit; text-decoration:none; display:block; min-width:0; }}
  .thumb {{ position:relative; aspect-ratio:16/9; border-radius:14px; overflow:hidden; background:#000; box-shadow:0 12px 34px -18px rgba(0,0,0,.4); }}
  .tall .thumb img {{ object-fit:contain; }}
  .thumb img {{ width:100%; height:100%; object-fit:cover; display:block; transition:transform .4s; }}
  .card:hover .thumb img {{ transform:scale(1.03); }}
  .dur {{ position:absolute; right:10px; bottom:10px; background:rgba(0,0,0,.72); color:#fff; font-size:12px; font-weight:600; padding:3px 8px; border-radius:999px; font-variant-numeric:tabular-nums; }}
  .t {{ font-weight:600; font-size:16px; margin-top:12px; line-height:1.3; }}
  .d {{ color:var(--muted); font-size:13px; margin-top:4px; }}
</style></head>
<body><main>
<header><img src="/jm-logo.png" alt=""><h1>Clips</h1><span class="count">{len(clips)} videos</span></header>
<div class="grid">
{chr(10).join(cards)}
</div></main>
<script>document.querySelectorAll('[data-d]').forEach(e => {{ try {{ e.textContent = new Date(e.dataset.d + 'T12:00:00').toLocaleDateString(undefined, {{ month: 'short', day: 'numeric', year: 'numeric' }}); }} catch (x) {{}} }});</script>
</body></html>'''
open(os.path.join(root, 'public/index.html'), 'w').write(page)
print(len(clips), 'clips on the home page')
