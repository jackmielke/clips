import { isOwner } from './_auth.js';
import { validSlug } from './_titles.js';
import { readPrivate, setPrivate } from './_visibility.js';

// GET: the private slugs (so the home page can hide them)  ·  POST {slug, private} (owner only)
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'GET') return res.status(200).json({ private: [...await readPrivate()] });
  if (req.method !== 'POST') return res.status(405).end();
  if (!isOwner(req)) return res.status(401).json({ error: 'unauthorized' });
  const { slug, private: on } = req.body || {};
  if (!validSlug(slug) || typeof on !== 'boolean') return res.status(400).json({ error: 'bad input' });
  await setPrivate(slug, on);
  res.status(200).json({ slug, private: on });
}
