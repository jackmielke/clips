import { isOwner } from './_auth.js';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { readTitle } from './_titles.js';
import { readPrivate } from './_visibility.js';
import { readOrganize } from './_organize.js';

// The manifest add-clip.sh keeps; bundled via vercel.json includeFiles, never served as a file.
function loadClips() {
  try { return JSON.parse(readFileSync(join(process.cwd(), 'api/_clips.json'), 'utf8')); } catch { return []; }
}

export default async function handler(req, res) {
  if (!isOwner(req)) return res.status(401).json({ error: 'unauthorized' });
  const clips = loadClips();
  const [priv, org] = await Promise.all([readPrivate(), readOrganize()]);
  const list = await Promise.all(clips.map(async (c) => ({ ...c, title: (await readTitle(c.slug)) || c.title, private: priv.has(c.slug), fav: !!org[c.slug]?.fav, tags: org[c.slug]?.tags || [] })));
  list.sort((a, b) => (b.created || '').localeCompare(a.created || ''));
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ clips: list });
}
