import { next } from '@vercel/functions';

// Only the home page, which lists every clip, needs the shared password (SITE_PASSWORD, "fun" by
// default). Share links (/<slug>, /v/...) stay open. Without the password the home page shows just the
// clips this browser has opened before (public/seen.js keeps that list). A right answer leaves a
// sitePass cookie for a year, and the owner key (?key= or the clipKey cookie, as in api/_auth.js) skips it.
export const config = { matcher: ['/', '/index.html', '/__unlock'] };

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

// The locked home page: the password box, then the clips this browser has watched, drawn from localStorage.
const gatePage = (to, wrong) => new Response(
  '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Clips</title>' +
  '<link rel="icon" href="/jm-logo.png"><style>' +
  ':root{--bg:#f6f5f2;--fg:#16161a;--muted:#6b6b73;--line:#d6d4cf;--field:#fff}' +
  '@media (prefers-color-scheme:dark){:root{--bg:#0f0f11;--fg:#f2f2f3;--muted:#9a9aa3;--line:#2a2a2f;--field:#18181b}}' +
  '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px Inter,system-ui,sans-serif}' +
  'main{max-width:1180px;margin:0 auto;padding:40px 16px 64px}' +
  'form{display:grid;gap:10px;width:min(300px,100%);margin:8vh auto 0;text-align:center}' +
  'h1{font-size:22px;font-weight:600;margin:0}p{color:var(--muted);margin:0 0 6px}' +
  'input,button{font:inherit;padding:10px 12px;border-radius:10px}input{border:1px solid var(--line);background:var(--field);color:inherit}' +
  'button{font-weight:600;border:0;background:var(--fg);color:var(--bg);cursor:pointer}.err{color:#d93025}' +
  'h2{font-size:16px;font-weight:600;margin:56px 0 16px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:20px}' +
  '.card{color:inherit;text-decoration:none;min-width:0}.thumb{aspect-ratio:16/9;border-radius:12px;overflow:hidden;background:#000}' +
  '.thumb img{width:100%;height:100%;object-fit:cover;display:block}.t{font-weight:600;margin-top:10px;line-height:1.3}' +
  '</style><body><main>' +
  `<form method="post" action="${UNLOCK}"><h1>Clips</h1><p>Type the password to see every video.</p>` +
  `<input type="hidden" name="next" value="${esc(to)}">` +
  '<input name="password" type="password" autofocus autocomplete="current-password" aria-label="Password">' +
  '<button>Open</button>' +
  (wrong ? '<div class="err">That isn’t it. Try again.</div>' : '') +
  '</form><section id="seen" hidden><h2>Clips you’ve watched</h2><div class="grid" id="grid"></div></section></main>' +
  '<script>try{var l=JSON.parse(localStorage.getItem("clipsSeen")||"[]"),g=document.getElementById("grid");' +
  'l.forEach(function(c){if(!/^[0-9a-f]{8}$/.test(c.slug))return;var a=document.createElement("a");a.className="card";a.href="/"+c.slug;' +
  'a.innerHTML=\'<div class="thumb"><img alt="" loading="lazy"></div><div class="t"></div>\';a.querySelector("img").src="/v/"+c.slug+"/poster.jpg";' +
  'a.querySelector(".t").textContent=c.title||"Clip";g.appendChild(a)});if(g.children.length)document.getElementById("seen").hidden=false}catch(e){}</script>',
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

  if (url.pathname === UNLOCK || cookie(req, 'sitePass') === pass || isOwner(req, url)) return next();
  return gatePage('/', false);
}
