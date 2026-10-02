import { readTitle, validSlug } from './_titles.js';

const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const notFound = (res) => res.status(404).setHeader('Content-Type', 'text/html; charset=utf-8').send(
  '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Clip not found</title>' +
  '<link rel="icon" href="/jm-logo.png"><body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f5f2;color:#16161a;font:15px system-ui,sans-serif;text-align:center">' +
  '<div><div style="font-size:22px;font-weight:600;margin-bottom:6px">This clip isn’t here</div><div style="color:#6b6b73">It may have been deleted. <a href="/library" style="color:inherit">Open the library</a></div></div>');

export default async function handler(req, res) {
  const slug = req.query.slug;
  if (!validSlug(slug)) return notFound(res);
  const base = `https://${req.headers.host}`;
  const [pageRes, title] = await Promise.all([fetch(`${base}/c/${slug}.html`), readTitle(slug)]);
  if (!pageRes.ok) return notFound(res);
  let html = await pageRes.text();
  if (title) {
    const orig = html.match(/<meta name="clip-title" content="([^"]*)">/)?.[1];
    if (orig) html = html.split(orig).join(esc(title));
  }
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).send(html);
}
