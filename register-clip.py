#!/usr/bin/env python3
"""register-clip.py <slug> <title> <secs> <w> <h> <created-iso> — upsert a clip into api/_clips.json,
the private manifest the /library page reads (bundled into the function, never served as a file)."""
import json, os, sys
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'api/_clips.json')
clips = json.load(open(path)) if os.path.exists(path) else []
slug, title, secs, w, h, created = sys.argv[1:7]
clips = [c for c in clips if c['slug'] != slug]
clips.append({'slug': slug, 'title': title, 'secs': int(secs), 'w': int(w), 'h': int(h), 'created': created})
json.dump(clips, open(path, 'w'), indent=1)
