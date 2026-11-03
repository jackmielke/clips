#!/usr/bin/env python3
"""ai-clip.py: a transcript, title, summary and chapters for a clip, like Loom's AI features.

  ai-clip.py <slug> [<slug> ...]   one or more clips
  ai-clip.py --all                 every clip in api/_clips.json that has no transcript yet
  options: --force (redo clips that already have one)  --deploy (redeploy if a title changed,
           so the home page shows it)  --dry (print the result, save nothing)

The audio is transcribed on this Mac with whisper.cpp (brew install whisper-cpp; the model downloads
once to ~/.cache/clips). Claude then writes the title, summary and chapters, through the Anthropic SDK
when an API key is set up, otherwise through the `claude` CLI. The result is saved with POST /api/ai
using .adminkey, and the clip page shows it. A clip only gets the AI title if it was never renamed and
still has its default name ("Recording · ...", "Untitled clip"), so a title you picked always wins.
"""
import json, os, re, shutil, subprocess, sys, tempfile, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ORIGIN = os.environ.get('CLIPS_ORIGIN', 'https://jack-clips.vercel.app').rstrip('/')
MANIFEST = os.path.join(HERE, 'api/_clips.json')
MODEL_NAME = os.environ.get('CLIPS_WHISPER_MODEL', 'ggml-large-v3-turbo-q5_0.bin')
MODEL_URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/' + MODEL_NAME
CLAUDE_MODEL = os.environ.get('CLIPS_CLAUDE_MODEL', 'claude-opus-5-5')
os.environ['PATH'] = ':'.join(['/opt/homebrew/bin', '/usr/local/bin', os.path.expanduser('~/.local/bin'),
                               os.path.expanduser('~/.claude/local'), os.environ.get('PATH', '')])


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def admin_key():
    with open(os.path.join(HERE, '.adminkey')) as f:
        return f.read().strip()


def api(method, path, body=None):
    req = urllib.request.Request(ORIGIN + path, method=method, headers={
        'Authorization': 'Bearer ' + admin_key(), 'Content-Type': 'application/json', 'User-Agent': 'clips-ai'})
    if body is not None:
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return e.code, None


def is_default_title(t):
    t = (t or '').strip()
    return not t or t == 'Untitled clip' or t.startswith('Recording ·') or t.startswith('Recording -')


# ---------- audio ----------

def source(slug):
    """The clip's video: a local copy if there is one, else the public URL (ffmpeg reads https)."""
    for d in (f'media/v/{slug}', f'public/v/{slug}'):
        for name in ('save.mp4', 'index.m3u8'):
            p = os.path.join(HERE, d, name)
            if os.path.exists(p):
                return p
    return f'{ORIGIN}/v/{slug}/save.mp4'


def whisper_bin():
    for name in ('whisper-cli', 'whisper-cpp'):
        if shutil.which(name):
            return shutil.which(name)
    if shutil.which('brew'):
        log('installing whisper.cpp with Homebrew (one time)')
        subprocess.run(['brew', 'install', 'whisper-cpp'], check=True)
        return shutil.which('whisper-cli')
    sys.exit('needs whisper.cpp: brew install whisper-cpp')


def whisper_model():
    d = os.path.expanduser('~/.cache/clips')
    path = os.path.join(d, MODEL_NAME)
    if not os.path.exists(path):
        os.makedirs(d, exist_ok=True)
        log('downloading the speech model (one time)', MODEL_URL)
        subprocess.run(['curl', '-fL', '--progress-bar', '-o', path + '.part', MODEL_URL], check=True)
        os.rename(path + '.part', path)
    return path


NOISE = re.compile(r'^\s*[\[\(][^\]\)]*[\]\)]\s*$')   # [BLANK_AUDIO], (music), [Silence]


def transcribe(src):
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, 'a.wav')
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-vn', '-ac', '1', '-ar', '16000',
                        '-c:a', 'pcm_s16le', wav], check=True)
        subprocess.run([whisper_bin(), '-m', whisper_model(), '-f', wav, '-l', 'auto', '-oj', '-of', os.path.join(tmp, 'out'), '-np'],
                       check=True, stdout=subprocess.DEVNULL)
        raw = json.load(open(os.path.join(tmp, 'out.json'), encoding='utf-8', errors='replace'))
    parts = []
    for s in raw.get('transcription', []):
        text = s.get('text', '').strip()
        if text and not NOISE.match(text):
            parts.append({'t': s['offsets']['from'] / 1000, 'end': s['offsets']['to'] / 1000, 'text': text})
    # whisper's segments can be fragments; join them into lines that end on a sentence, up to ~30 words.
    lines = []
    for p in parts:
        last = lines[-1] if lines else None
        if last and not re.search(r'[.!?]["\')]?$', last['text']) and len(last['text'].split()) < 30 and p['t'] - last['end'] < 2:
            last['text'] += ' ' + p['text']; last['end'] = p['end']
        else:
            lines.append(dict(p))
    for l in lines:
        l['t'], l['end'] = round(l['t'], 1), round(l['end'], 1)
    return lines


# ---------- Claude ----------

PROMPT = """This is the transcript of a screen recording that Jack Mielke made and shared as a link (screen, camera and voice), with each line's start time in seconds. Write what a viewer sees above and beside the video.

Return only a JSON object with these keys:
- "title": a short, specific title in sentence case, 3 to 8 words, naming what the video is about. No quotes, no trailing period.
- "summary": 2 to 4 plain sentences on what the video covers and any ask or decision in it. Write it about the video ("Jack walks through..."), not as Jack.
- "points": 2 to 6 short key takeaways, as strings. Use [] for a very short clip.
- "chapters": for a video longer than about 2 minutes, 3 to 8 chapters as {{"t": start seconds taken from the transcript, "title": a few words}}, the first at 0. Use [] for a shorter one.

Never use em dashes. If the transcript is too thin to say much, keep it short and honest.

Video length: {secs} seconds.
Transcript:
{lines}"""

SCHEMA = {
    'type': 'object', 'additionalProperties': False, 'required': ['title', 'summary', 'points', 'chapters'],
    'properties': {
        'title': {'type': 'string'}, 'summary': {'type': 'string'},
        'points': {'type': 'array', 'items': {'type': 'string'}},
        'chapters': {'type': 'array', 'items': {'type': 'object', 'additionalProperties': False, 'required': ['t', 'title'],
                                                'properties': {'t': {'type': 'number'}, 'title': {'type': 'string'}}}},
    },
}


def parse_json(text):
    m = re.search(r'\{.*\}', text, re.S)
    if not m:
        raise ValueError('no JSON in the reply: ' + text[:200])
    return json.loads(m.group(0))


def ask_sdk(prompt):
    import anthropic  # pip3 install anthropic; reads ANTHROPIC_API_KEY or an `ant auth login` profile
    client = anthropic.Anthropic()
    req = dict(model=CLAUDE_MODEL, max_tokens=16000, messages=[{'role': 'user', 'content': prompt}],
               output_config={'effort': 'low', 'format': {'type': 'json_schema', 'schema': SCHEMA}})
    try:  # with a server-side fallback model in case of a refusal
        msg = client.beta.messages.create(**req, betas=['server-side-fallback-2026-07-01'], fallbacks='default')
    except TypeError:  # an older SDK without the fallbacks parameter
        msg = client.messages.create(**req)
    if msg.stop_reason == 'refusal':
        raise RuntimeError('declined')
    return parse_json(''.join(b.text for b in msg.content if b.type == 'text'))


def ask_cli(prompt):
    claude = shutil.which('claude')
    if not claude:
        raise RuntimeError('no claude CLI')
    out = subprocess.run([claude, '-p', '--model', CLAUDE_MODEL], input=prompt, capture_output=True, text=True, timeout=600)
    if out.returncode:
        raise RuntimeError(out.stderr.strip()[:300])
    return parse_json(out.stdout)


def no_dashes(x):
    if isinstance(x, str):
        return x.replace(' — ', ', ').replace('—', ', ').replace(' – ', ', ')
    if isinstance(x, list):
        return [no_dashes(i) for i in x]
    if isinstance(x, dict):
        return {k: no_dashes(v) for k, v in x.items()}
    return x


def write_up(lines, secs):
    prompt = PROMPT.format(secs=secs, lines='\n'.join(f"[{l['t']:.0f}] {l['text']}" for l in lines))
    errors = []
    for ask in (ask_sdk, ask_cli):
        try:
            return no_dashes(ask(prompt))
        except Exception as e:
            errors.append(f'{ask.__name__}: {e}')
    raise RuntimeError('; '.join(errors))


# ---------- main ----------

def load_manifest():
    return json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else []


def run(slug, clip, force, dry):
    if not force and not dry and api('GET', f'/api/ai?slug={slug}')[0] == 200:
        log(slug, 'already has a transcript')
        return None
    log(slug, 'transcribing', source(slug))
    lines = transcribe(source(slug))
    secs = (clip or {}).get('secs') or (lines[-1]['end'] if lines else 0)
    if sum(len(l['text'].split()) for l in lines) < 8:
        data = {'title': '', 'summary': '', 'points': [], 'chapters': [], 'segments': lines}
        log(slug, 'almost no speech, saving the transcript only')
    else:
        log(slug, f'{len(lines)} lines, asking Claude for a title and summary')
        data = {**write_up(lines, secs), 'segments': lines}
    if dry:
        print(json.dumps({k: v for k, v in data.items() if k != 'segments'}, indent=1, ensure_ascii=False))
        return None
    set_title = is_default_title((clip or {}).get('title'))
    status, res = api('POST', '/api/ai', {'slug': slug, 'data': data, 'setTitle': set_title})
    if status != 200:
        raise RuntimeError(f'saving failed: HTTP {status}')
    log(slug, 'saved', ('· title: ' + res['title']) if res.get('titleSet') else '')
    return res.get('title') if res.get('titleSet') else None


def main():
    args = sys.argv[1:]
    force, deploy, dry = '--force' in args, '--deploy' in args, '--dry' in args
    clips = {c['slug']: c for c in load_manifest()}
    slugs = [a for a in args if not a.startswith('--')]
    if '--all' in args:
        slugs = [c['slug'] for c in sorted(clips.values(), key=lambda c: c.get('created', ''), reverse=True)]
    if not slugs:
        sys.exit(__doc__)
    renamed, failed = {}, []
    for slug in slugs:
        try:
            t = run(slug, clips.get(slug), force, dry)
            if t:
                renamed[slug] = t
        except Exception as e:
            failed.append(slug)
            log(slug, 'FAILED', e)
    if renamed:
        # The home page is built from the manifest, so it gets the new titles too.
        manifest = load_manifest()
        for c in manifest:
            if c['slug'] in renamed:
                c['title'] = renamed[c['slug']]
        json.dump(manifest, open(MANIFEST, 'w'), indent=1)
        subprocess.run([sys.executable, os.path.join(HERE, 'build-index.py')], check=False)
        if deploy:
            subprocess.run(['npx', '--yes', 'vercel@latest', 'deploy', '--prod', '--yes'], cwd=HERE, check=False,
                           stdout=subprocess.DEVNULL)
    log(f'done: {len(slugs) - len(failed)} ok, {len(renamed)} retitled, {len(failed)} failed', ' '.join(failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
