// Clip videos live in Cloudflare R2 once offload-media.sh has moved them out of public/v/ (Vercel's
// free plan caps a deploy at 100 MB). Anything still in public/v/ is served directly, since Vercel
// checks files before rewrites; everything else under /v/ is sent on to the bucket.
export default function handler(req, res) {
  const path = String(req.query.path || '');
  const base = (process.env.CLIPS_MEDIA_URL || '').replace(/\/$/, '');
  if (!base || !/^[0-9a-f]{8}\/[\w.-]+$/.test(path)) return res.status(404).end();
  res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
  res.redirect(308, `${base}/v/${path}`);
}
