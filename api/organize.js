import { isOwner } from './_auth.js';
import { validSlug } from './_titles.js';
import { readOrganize, setOrganize } from './_organize.js';

// Owner only. GET: every clip's favorite flag and tags  ·  POST {slug, fav?, tags?}: change one clip.
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (!isOwner(req)) return res.status(401).json({ error: 'unauthorized' });
  if (req.method === 'GET') return res.status(200).json({ clips: await readOrganize() });
  if (req.method !== 'POST') return res.status(405).end();
  const { slug, fav, tags } = req.body || {};
  if (!validSlug(slug) || (fav !== undefined && typeof fav !== 'boolean') || (tags !== undefined && !Array.isArray(tags))) {
    return res.status(400).json({ error: 'bad input' });
  }
  res.status(200).json({ slug, ...(await setOrganize(slug, { fav, tags })) });
}
