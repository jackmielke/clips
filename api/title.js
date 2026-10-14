import { isOwner } from './_auth.js';
import { validSlug, writeTitle } from './_titles.js';

export default async function handler(req, res) {
  if (!isOwner(req)) return res.status(401).json({ error: 'unauthorized' });
  if (req.method === 'GET') return res.status(200).json({ ok: true });
  if (req.method !== 'POST') return res.status(405).end();
  const { slug, title } = req.body || {};
  const clean = typeof title === 'string' ? title.replace(/\s+/g, ' ').trim().slice(0, 140) : '';
  if (!validSlug(slug) || !clean) return res.status(400).json({ error: 'bad input' });
  await writeTitle(slug, clean);
  res.status(200).json({ ok: true, title: clean });
}
