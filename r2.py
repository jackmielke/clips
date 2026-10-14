#!/usr/bin/env python3
"""Tiny Cloudflare R2 client (S3 API, standard library only), so clip videos live in R2 instead
of inside every Vercel deploy.

  r2.py put <file> <key>     upload one file (streamed, any size up to 5 GB)
  r2.py cors                 let the clip pages fetch videos from R2 (Save video, old HLS clips)
  r2.py check                print OK if .env.r2 is filled in and the bucket answers

Reads .env.r2 next to this file:
  R2_ACCOUNT_ID=...  R2_ACCESS_KEY_ID=...  R2_SECRET_ACCESS_KEY=...  R2_BUCKET=...
  R2_PUBLIC_URL=https://pub-xxxx.r2.dev   (the bucket's public URL, no trailing slash)
"""
import base64, datetime, hashlib, hmac, http.client, mimetypes, os, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))


def config():
    path = os.path.join(HERE, '.env.r2')
    if not os.path.exists(path):
        sys.exit('no .env.r2')
    env = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"\'')
    for k in ('R2_ACCOUNT_ID', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY', 'R2_BUCKET'):
        if not env.get(k):
            sys.exit(f'.env.r2 is missing {k}')
    return env


def request(env, method, key='', query='', body=b'', headers=None, body_file=None, size=None):
    host = f"{env['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com"
    path = '/' + env['R2_BUCKET'] + ('/' + urllib.parse.quote(key) if key else '')
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, day = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
    payload = 'UNSIGNED-PAYLOAD' if body_file else hashlib.sha256(body).hexdigest()
    h = {'host': host, 'x-amz-date': amz, 'x-amz-content-sha256': payload, **{k.lower(): v for k, v in (headers or {}).items()}}
    signed = ';'.join(sorted(h))
    canon = '\n'.join([method, path, query, ''.join(f'{k}:{h[k]}\n' for k in sorted(h)), signed, payload])
    scope = f'{day}/auto/s3/aws4_request'
    to_sign = '\n'.join(['AWS4-HMAC-SHA256', amz, scope, hashlib.sha256(canon.encode()).hexdigest()])
    k = ('AWS4' + env['R2_SECRET_ACCESS_KEY']).encode()
    for part in (day, 'auto', 's3', 'aws4_request'):
        k = hmac.new(k, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    h['authorization'] = f"AWS4-HMAC-SHA256 Credential={env['R2_ACCESS_KEY_ID']}/{scope}, SignedHeaders={signed}, Signature={sig}"
    h['content-length'] = str(size if body_file else len(body))
    conn = http.client.HTTPSConnection(host, timeout=600)
    conn.putrequest(method, path + ('?' + query if query else ''), skip_host=True, skip_accept_encoding=True)
    for name, value in h.items():
        conn.putheader(name, value)
    conn.endheaders()
    if body_file:
        while chunk := body_file.read(1 << 20):
            conn.send(chunk)
    elif body:
        conn.send(body)
    r = conn.getresponse()
    data = r.read()
    if r.status >= 300:
        sys.exit(f'R2 {method} {key or query} failed: {r.status} {data[:300].decode(errors="replace")}')
    return data


def put(env, file, key):
    ctype = mimetypes.guess_type(file)[0] or ('video/mp2t' if file.endswith('.ts') else
                                              'application/vnd.apple.mpegurl' if file.endswith('.m3u8') else
                                              'application/octet-stream')
    with open(file, 'rb') as f:
        request(env, 'PUT', key, headers={'content-type': ctype, 'cache-control': 'public, max-age=31536000, immutable'},
                body_file=f, size=os.path.getsize(file))


def cors(env):
    xml = (b'<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod>'
           b'<AllowedMethod>HEAD</AllowedMethod><AllowedHeader>*</AllowedHeader><ExposeHeader>Content-Length</ExposeHeader>'
           b'<ExposeHeader>Content-Range</ExposeHeader><MaxAgeSeconds>86400</MaxAgeSeconds></CORSRule></CORSConfiguration>')
    md5 = base64.b64encode(hashlib.md5(xml).digest()).decode()
    request(env, 'PUT', query='cors=', body=xml, headers={'content-md5': md5, 'content-type': 'application/xml'})


if __name__ == '__main__':
    env = config()
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'put' and len(sys.argv) == 4:
        put(env, sys.argv[2], sys.argv[3])
    elif cmd == 'cors':
        cors(env)
    elif cmd == 'check':
        request(env, 'GET', query='list-type=2&max-keys=1')
        print('OK')
    else:
        sys.exit(__doc__)
