import { readTitle, validSlug } from './_titles.js';
import { isOwner } from './_auth.js';
import { readPrivate } from './_visibility.js';

const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const notFound = (res) => res.status(404).setHeader('Content-Type', 'text/html; charset=utf-8').send(
  '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Clip not found</title>' +
  '<link rel="icon" href="/jm-logo.png"><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f5f2;color:#16161a;font:15px system-ui,sans-serif;text-align:center">' +
  '<div><div style="font-size:22px;font-weight:600;margin-bottom:6px">This clip isn’t here</div><div style="color:#6b6b73">It may have been deleted. <a href="/library" style="color:inherit">Open the library</a></div></div>');

// A private clip shows this to everyone but Jack. If this browser holds the owner key (from the
// library or an earlier ?key= visit) but hasn't sent it as a cookie yet, it sets the cookie and reloads.
const privatePage = (res) => res.status(404).setHeader('Content-Type', 'text/html; charset=utf-8').setHeader('Cache-Control', 'no-store').send(
  '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Private video</title>' +
  '<link rel="icon" href="/jm-logo.png"><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f5f2;color:#16161a;font:15px system-ui,sans-serif;text-align:center">' +
  '<div><div style="font-size:22px;font-weight:600;margin-bottom:6px">This video is private</div><div style="color:#6b6b73">Ask Jack to share it if you need to see it.</div></div>' +
  '<script>try{var p=new URLSearchParams(location.search),k=p.get("key")||localStorage.getItem("clipKey");' +
  'if(k&&document.cookie.indexOf("clipKey=")<0){localStorage.setItem("clipKey",k);document.cookie="clipKey="+encodeURIComponent(k)+"; Path=/; Max-Age=31536000; SameSite=Lax; Secure";location.replace(location.pathname)}}catch(e){}</script>');

export default async function handler(req, res) {
  const slug = req.query.slug;
  if (!validSlug(slug)) return notFound(res);
  if (!isOwner(req) && (await readPrivate()).has(slug)) return privatePage(res);
  const base = `https://${req.headers.host}`;
  const [pageRes, title] = await Promise.all([fetch(`${base}/c/${slug}.html`), readTitle(slug)]);
  if (!pageRes.ok) return notFound(res);
  let html = await pageRes.text();
  if (title) {
    const orig = html.match(/<meta name="clip-title" content="([^"]*)">/)?.[1];
    if (orig) html = html.split(orig).join(esc(title));
  }
  // Comments and reactions live in one script so every clip, old or new, gets them.
  html = html.replace('</body>', '<link rel="stylesheet" href="/comments.css"><script src="/comments.js" defer></script><script src="/owner.js" defer></script><script src="/seen.js" defer></script>\n</body>');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).send(html);
}
