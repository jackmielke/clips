import { timingSafeEqual } from 'node:crypto';
import { validSlug, writeTitle } from './_titles.js';

function authed(req) {
  const got = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
  const want = Buffer.from(process.env.ADMIN_KEY || '');
  return want.length > 0 && got.length === want.length && timingSafeEqual(got, want);
}

export default async function handler(req, res) {
  if (!authed(req)) return res.status(401).json({ error: 'unauthorized' });
  if (req.method === 'GET') return res.status(200).json({ ok: true });
  if (req.method !== 'POST') return res.status(405).end();
  const { slug, title } = req.body || {};
  const clean = typeof title === 'string' ? title.replace(/\s+/g, ' ').trim().slice(0, 140) : '';
  if (!validSlug(slug) || !clean) return res.status(400).json({ error: 'bad input' });
  await writeTitle(slug, clean);
  res.status(200).json({ ok: true, title: clean });
}
