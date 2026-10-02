#!/usr/bin/env python3
"""Rebuild a Screen Studio recording from its raw tracks: screen + redrawn cursor + click rings
+ rounded facecam (bottom right) + mic and system audio.

Usage: render.py <project.screenstudio> <out.mp4>
"""
import json, os, subprocess, sys, tempfile

FPS = 30
CURSOR_SCALE = 1.5   # draw cursors a bit larger than the system size, like Screen Studio does
CAM = 600            # facecam square size in px
CAM_RADIUS = 70
CAM_MARGIN = 60
RING_SECS = 0.3
HERE = os.path.dirname(os.path.abspath(__file__))


def probe(path):
    out = subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                   'stream=width,height:format=duration', '-of', 'json', path])
    j = json.loads(out)
    return j['streams'][0]['width'], j['streams'][0]['height'], float(j['format']['duration'])


def main(project, out):
    rec = os.path.join(project, 'recording')
    p = lambda name: os.path.join(rec, name)
    meta = {r['id']: r for r in json.load(open(p('metadata.json')))['recorders']}
    start = meta['channel-2-display']['sessions'][0]['processTimeStartMs']
    # The Clips recorder may scale its display track; event coords stay in points.
    W, H, dur = probe(p('channel-2-display-0.mp4'))
    pts_w = meta['channel-2-display'].get('configuration', {}).get('pointWidth')
    px = W / pts_w if pts_w else (2 if W > 2000 else 1)  # event coords are in points

    load = lambda f: json.load(open(p(f))) if os.path.exists(p(f)) else []
    moves = load('mousemoves-0.json')
    clicks = [e for e in load('mouseclicks-0.json') if e['type'] == 'mouseDown']
    info = {c['id']: c for c in json.load(open(p('cursors.json')))}

    used = sorted({e['cursorId'] for e in moves} & {c for c in info if os.path.exists(p(f'cursors/{c}.png'))})
    idx = {c: i for i, c in enumerate(used)}
    size = {c: (round(info[c]['standardSize']['width'] * px * CURSOR_SCALE),
                round(info[c]['standardSize']['height'] * px * CURSOR_SCALE)) for c in used}
    hot = {c: (info[c]['hotSpot']['x'] * px * CURSOR_SCALE, info[c]['hotSpot']['y'] * px * CURSOR_SCALE) for c in used}

    # One sendcmd line per frame where something changed: move the active cursor sprite into place,
    # park the others off-screen, and flash the ring on mouseDown.
    lines, mi, last = [], 0, None
    cur = moves[0] if moves else None
    ring_r = 36
    for f in range(int(dur * FPS) + 1):
        t = f / FPS
        while mi < len(moves) and moves[mi]['processTimeMs'] - start <= t * 1000:
            cur = moves[mi]; mi += 1
        ring = next((c for c in clicks if 0 <= t * 1000 - (c['processTimeMs'] - start) < RING_SECS * 1000), None)
        state = (cur and cur['cursorId'], cur and round(cur['x'], 1), cur and round(cur['y'], 1),
                 ring and ring['processTimeMs'])
        if state == last:
            continue
        last = state
        cmds = []
        cid = cur['cursorId'] if cur and cur['cursorId'] in idx else (used[0] if used else None)
        for c in used:
            if cur and c == cid:
                x, y = cur['x'] * px - hot[c][0], cur['y'] * px - hot[c][1]
            else:
                x, y = -1000, -1000
            cmds += [f'overlay@c{idx[c]} x {x:.0f}', f'overlay@c{idx[c]} y {y:.0f}']
        rx, ry = (ring['x'] * px - ring_r, ring['y'] * px - ring_r) if ring else (-1000, -1000)
        cmds += [f'overlay@ring x {rx:.0f}', f'overlay@ring y {ry:.0f}']
        lines.append(f'{t:.4f} ' + ', '.join(cmds) + ';')

    tmp = tempfile.mkdtemp()
    cmdfile = os.path.join(tmp, 'cursor.cmd')
    open(cmdfile, 'w').write('\n'.join(lines) + '\n')
    mask = os.path.join(tmp, 'mask.png')
    # Camera spot: where the Clips bubble sat on screen (fractions), else Screen Studio's bottom-right default.
    camcfg = meta.get('channel-4-webcam', {}).get('configuration', {})
    if 'size' in camcfg:
        S = max(2, round(camcfg['size'] * W) // 2 * 2)
        cam_x, cam_y = round(camcfg['x'] * W), round(camcfg['y'] * H)
    else:
        S = CAM
        cam_x, cam_y = f'W-w-{CAM_MARGIN}', f'H-h-{CAM_MARGIN}'
    R = round(S * CAM_RADIUS / CAM)
    subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i',
                           f'color=black:s={S}x{S},format=gray', '-frames:v', '1', '-vf',
                           f"geq=lum='if(lte(pow(max(0,abs(X-{S}/2+0.5)-({S}/2-{R})),2)+pow(max(0,abs(Y-{S}/2+0.5)-({S}/2-{R})),2),{R}*{R}),255,0)'",
                           mask])

    has_cam = os.path.exists(p('channel-4-webcam-0.mp4'))
    audio = [f for f in ('channel-3-microphone-0.m4a', 'channel-1-system-audio-0.m4a') if os.path.exists(p(f))]

    # Fixed input order: 0 screen, 1 mask, 2 ring, then cursors, then camera, then audio.
    inputs = ['-i', p('channel-2-display-0.mp4'), '-loop', '1', '-i', mask,
              '-loop', '1', '-i', os.path.join(HERE, 'assets/ring.png')]
    for c in used:
        inputs += ['-loop', '1', '-i', p(f'cursors/{c}.png')]
    cam_i = 3 + len(used)
    if has_cam:
        inputs += ['-i', p('channel-4-webcam-0.mp4')]
    a0 = cam_i + (1 if has_cam else 0)
    for f in audio:
        inputs += ['-i', p(f)]

    g = [f"[0:v]fps={FPS},sendcmd=f='{cmdfile}'[bg0]"]
    for c in used:
        i = idx[c]
        g.append(f'[{3 + i}:v]scale={size[c][0]}:{size[c][1]},format=rgba[k{i}]')
        g.append(f'[bg{i}][k{i}]overlay@c{i}=x=-1000:y=-1000:shortest=1[bg{i + 1}]')
    n = len(used)
    g.append(f'[bg{n}][2:v]overlay@ring=x=-1000:y=-1000:shortest=1[bgr]')
    if has_cam:
        g.append(f'[{cam_i}:v]crop=min(iw\\,ih):min(iw\\,ih),scale={S}:{S},format=yuva420p[cam]')
        g.append(f'[1:v]format=gray,scale={S}:{S}[m]')
        g.append('[cam][m]alphamerge[camr]')
        g.append(f'[bgr][camr]overlay={cam_x}:{cam_y}:shortest=1,format=yuv420p[v]')
    else:
        g.append('[bgr]format=yuv420p[v]')
    maps = ['-map', '[v]']
    if len(audio) == 2:
        g.append(f'[{a0}:a][{a0 + 1}:a]amix=inputs=2:normalize=0:duration=longest[a]')
        maps += ['-map', '[a]']
    elif audio:
        maps += ['-map', f'{a0}:a']
    print(f'DURATION {dur:.2f}', flush=True)

    subprocess.check_call(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-stats', '-y', *inputs,
                           '-filter_complex', ';'.join(g), *maps,
                           '-c:v', 'h264_videotoolbox', '-b:v', '12M', '-c:a', 'aac', '-b:a', '192k',
                           '-shortest', out])


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
