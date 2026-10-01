import { readTitle, validSlug } from './_titles.js';

const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export default async function handler(req, res) {
  const slug = req.query.slug;
  if (!validSlug(slug)) return res.status(404).send('Not found');
  const base = `https://${req.headers.host}`;
  const [pageRes, title] = await Promise.all([fetch(`${base}/c/${slug}.html`), readTitle(slug)]);
  if (!pageRes.ok) return res.status(404).send('Not found');
  let html = await pageRes.text();
  if (title) {
    const orig = html.match(/<meta name="clip-title" content="([^"]*)">/)?.[1];
    if (orig) html = html.split(orig).join(esc(title));
  }
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).send(html);
}
