import { next } from '@vercel/functions';

// The whole site sits behind one shared password (SITE_PASSWORD, "fun" by default) until clips can be
// picked one by one. A right answer leaves a sitePass cookie for a year. The owner key (?key=, the
// clipKey cookie or a Bearer header, as in api/_auth.js) skips the gate so the Mac app keeps working.
export const config = { matcher: '/((?!jm-logo\\.png|apple-touch-icon\\.png|favicon\\.ico).*)' };

const PASSWORD = process.env.SITE_PASSWORD || 'fun';
const UNLOCK = '/__unlock';

async function token() {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`clips-gate:${PASSWORD}`));
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

const cookie = (req, name) => {
  const v = new RegExp(`(?:^|;\\s*)${name}=([^;]*)`).exec(req.headers.get('cookie') || '')?.[1];
  return v && decodeURIComponent(v);
};

function isOwner(req, url) {
  const want = process.env.ADMIN_KEY;
  if (!want) return false;
  const header = (req.headers.get('authorization') || '').replace(/^Bearer /, '');
  return [header, cookie(req, 'clipKey'), url.searchParams.get('key')].includes(want);
}

// Only send people back to a path on this site.
const safeNext = (s) => (typeof s === 'string' && s.startsWith('/') && !s.startsWith('//') ? s : '/');

const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const gatePage = (to, wrong) => new Response(
  '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Clips</title>' +
  '<link rel="icon" href="/jm-logo.png"><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f5f2;color:#16161a;font:15px system-ui,sans-serif;text-align:center">' +
  `<form method="post" action="${UNLOCK}" style="display:grid;gap:10px;width:min(280px,calc(100vw - 32px))">` +
  '<div style="font-size:22px;font-weight:600">Password</div>' +
  `<input type="hidden" name="next" value="${esc(to)}">` +
  '<input name="password" type="password" autofocus autocomplete="current-password" aria-label="Password" style="font:inherit;padding:10px 12px;border:1px solid #d6d4cf;border-radius:10px;background:#fff">' +
  '<button style="font:inherit;font-weight:600;padding:10px 12px;border:0;border-radius:10px;background:#16161a;color:#fff;cursor:pointer">Open</button>' +
  (wrong ? '<div style="color:#b3261e">That isn’t it. Try again.</div>' : '') +
  '</form>',
  { status: 401, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } },
);

export default async function middleware(req) {
  const url = new URL(req.url);
  const pass = await token();

  if (url.pathname === UNLOCK && req.method === 'POST') {
    const form = await req.formData().catch(() => null);
    const to = safeNext(form?.get('next'));
    if (form?.get('password') !== PASSWORD) return gatePage(to, true);
    return new Response(null, {
      status: 303,
      headers: { Location: to, 'Set-Cookie': `sitePass=${pass}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax` },
    });
  }

  if (cookie(req, 'sitePass') === pass || isOwner(req, url)) return next();

  // Videos and API calls get a plain 401; pages get the password form.
  if (url.pathname.startsWith('/v/') || url.pathname.startsWith('/api/')) return new Response('Password required', { status: 401 });
  return gatePage(url.pathname + url.search, false);
}
