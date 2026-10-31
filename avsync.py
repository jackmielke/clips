#!/usr/bin/env python3
"""Measure lip sync in a Clips recording by matching how open the mouth is in the webcam track
against the loudness of the mic track. Prints how early (+) or late (-) the voice is versus the face.
On a Mac it reads the mouth with Apple's face landmarks (mouth.swift); elsewhere it falls back to
plain motion in the middle of the frame, which is much noisier.
Usage: avsync.py <project>/recording   (render.py also imports measure() to fix sync on its own)"""
import array, math, os, shutil, subprocess, sys

HZ = 100          # common grid, 10 ms
MAXLAG = 1.0      # seconds searched each way


def start(f):
    return max(0.0, float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'stream=start_time',
                                                   '-of', 'csv=p=0', f]).split()[0]))


def face_motion(cam, max_secs):
    # Middle of the frame, where the face sits in the square bubble; frame-to-frame change.
    vf = ("crop=ih*0.55:ih*0.55:(iw-ih*0.55)/2:ih*0.3,scale=64:64,format=gray,"
          "tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-")
    out = subprocess.check_output(['ffmpeg', '-v', 'error', '-t', str(max_secs or 1e6), '-i', cam, '-vf', vf, '-an', '-f', 'null', '-']).decode()
    pts, vals, t = [], [], None
    for line in out.splitlines():
        if line.startswith('frame:'):
            t = float(line.split('pts_time:')[1])
        elif 'YAVG=' in line and t is not None:
            pts.append(t); vals.append(float(line.split('=')[1]))
    off = start(cam)
    return [p + off for p in pts], vals


def mouth_open(cam, max_secs):
    out = subprocess.check_output(['swift', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mouth.swift'), cam,
                                   str(max_secs or 1e6)],
                                  stderr=subprocess.DEVNULL).decode()
    rows = [tuple(map(float, l.split(','))) for l in out.split() if ',' in l]
    seen = [r for r in rows if r[1] >= 0]
    pts, vals = [r[0] for r in seen], [r[1] for r in seen]
    # AVAssetReader may already place frames on the recording's timeline; only add the offset if not.
    off = start(cam)
    if pts and abs(pts[0] - off) > 0.1:
        pts = [p + off for p in pts]
    return pts, vals


def voice_level(mic):
    SR = 16000
    raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', mic, '-af', 'highpass=f=100,lowpass=f=4000',
                                   '-ac', '1', '-ar', str(SR), '-f', 's16le', '-'])
    a = array.array('h'); a.frombytes(raw)
    B = SR // HZ
    env = [math.log(1 + sum(x * x for x in a[i:i + B]) / B) for i in range(0, len(a) - B + 1, B)]
    return start(mic), env


def to_grid(ts, vs, n):
    g, j = [0.0] * n, 0
    for i in range(n):
        t = i / HZ
        while j + 1 < len(ts) and ts[j + 1] <= t: j += 1
        if j + 1 < len(ts) and ts[j] <= t:
            f = (t - ts[j]) / (ts[j + 1] - ts[j]); g[i] = vs[j] + f * (vs[j + 1] - vs[j])
        elif ts and t >= ts[-1]: g[i] = vs[-1]
        elif ts: g[i] = vs[0]
    return g


def detrend(x, w=HZ // 2):
    # Remove slow changes so only quick ups and downs (syllables, mouth moves) are compared.
    c = [0.0]
    for v in x: c.append(c[-1] + v)
    out = []
    for i in range(len(x)):
        lo, hi = max(0, i - w), min(len(x), i + w + 1)
        out.append(x[i] - (c[hi] - c[lo]) / (hi - lo))
    return out


def best_lag(v, a, lo, hi):
    L = int(MAXLAG * HZ)
    best = None
    scores = []
    for lag in range(-L, L + 1):
        s = n = 0; sv = sa = 0.0
        for i in range(max(lo, L), min(hi, len(v) - L)):
            s += v[i] * a[i + lag]; sv += v[i] * v[i]; sa += a[i + lag] * a[i + lag]
        r = s / math.sqrt(sv * sa) if sv and sa else 0
        scores.append(r)
        if best is None or r > best[1]: best = (lag, r)
    lag, r = best
    k = lag + L
    if 0 < k < len(scores) - 1:   # sub-step peak
        y0, y1, y2 = scores[k - 1], scores[k], scores[k + 1]
        d = y0 - 2 * y1 + y2
        lag = lag + (0.5 * (y0 - y2) / d if d else 0)
    # a(t + lag) matches v(t): voice reaches the face's moment `lag` later; negative lag = voice early.
    return -lag / HZ, r


def measure(rec, max_secs=None):
    """(seconds the voice is early, match 0-1, [(window start, early, match)...]) or None."""
    cam, mic = os.path.join(rec, 'channel-4-webcam-0.mp4'), os.path.join(rec, 'channel-3-microphone-0.m4a')
    if not (os.path.exists(cam) and os.path.exists(mic)):
        return None
    mac = shutil.which('swift') and sys.platform == 'darwin'
    ts, vs = mouth_open(cam, max_secs) if mac else face_motion(cam, max_secs)
    if len(ts) < 2:
        return None
    moff, env = voice_level(mic)
    n = int(min(ts[-1], moff + len(env) / HZ) * HZ)
    v = detrend(to_grid(ts, vs, n))
    a = detrend(to_grid([moff + i / HZ for i in range(len(env))], env, n))
    early, r = best_lag(v, a, 0, n)
    W = 30 * HZ
    windows = [(lo / HZ, *best_lag(v, a, lo, min(n, lo + W))) for lo in range(0, n - W // 2, W)]
    return early, r, windows


if __name__ == '__main__':
    m = measure(sys.argv[1])
    if not m:
        sys.exit('needs a webcam and a mic track')
    early, r, windows = m
    print(f'whole recording: voice early by {early:+.3f}s  (match {r:.2f})')
    for lo, e, wr in windows:
        print(f'{lo:6.0f}s: voice early by {e:+.3f}s  (match {wr:.2f})')
