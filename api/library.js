import { timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readTitle } from './_titles.js';

function authed(req) {
  const got = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
  const want = Buffer.from(process.env.ADMIN_KEY || '');
  return want.length > 0 && got.length === want.length && timingSafeEqual(got, want);
}

// The manifest add-clip.sh keeps; bundled via vercel.json includeFiles, never served as a file.
function loadClips() {
  try { return JSON.parse(readFileSync(join(process.cwd(), 'api/_clips.json'), 'utf8')); } catch { return []; }
}

export default async function handler(req, res) {
  if (!authed(req)) return res.status(401).json({ error: 'unauthorized' });
  const clips = loadClips();
  const list = await Promise.all(clips.map(async (c) => ({ ...c, title: (await readTitle(c.slug)) || c.title })));
  list.sort((a, b) => (b.created || '').localeCompare(a.created || ''));
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ clips: list });
}
