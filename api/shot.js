// Screenshot links: /s/<slug> goes straight to the image in R2 (shot.sh uploads it as s/<slug>.png).
// Redirecting to the png keeps the link short and lets Slack, iMessage and browsers show the picture itself.
export default function handler(req, res) {
  const slug = String(req.query.slug || '');
  const base = (process.env.CLIPS_MEDIA_URL || '').replace(/\/$/, '');
  if (!base || !/^[0-9a-f]{8}$/.test(slug)) return res.status(404).end();
  res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
  res.redirect(308, `${base}/s/${slug}.png`);
}
