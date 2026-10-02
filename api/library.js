import { timingSafeEqual } from 'node:crypto';
import clips from './_clips.json' with { type: 'json' };
import { readTitle } from './_titles.js';

function authed(req) {
  const got = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
  const want = Buffer.from(process.env.ADMIN_KEY || '');
  return want.length > 0 && got.length === want.length && timingSafeEqual(got, want);
}

export default async function handler(req, res) {
  if (!authed(req)) return res.status(401).json({ error: 'unauthorized' });
  const list = await Promise.all(clips.map(async (c) => ({ ...c, title: (await readTitle(c.slug)) || c.title })));
  list.sort((a, b) => (b.created || '').localeCompare(a.created || ''));
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ clips: list });
}
