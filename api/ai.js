import { isOwner } from './_auth.js';
import { readTitle, validSlug, writeTitle } from './_titles.js';
import { readPrivate } from './_visibility.js';
import { readAI, writeAI } from './_ai.js';

const str = (s, n) => (typeof s === 'string' ? s.replace(/\s+/g, ' ').trim().slice(0, n) : '');
const num = (t) => (Number.isFinite(+t) && +t >= 0 ? Math.round(+t * 10) / 10 : 0);

// The AI title, summary, chapters and transcript for one clip.
// GET ?slug=  anyone who can watch the clip  ·  POST {slug, data, setTitle}  owner only (ai-clip.py)
// setTitle only fills in a title when the clip has never been renamed, so a hand-picked title always wins.
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'GET') {
    const slug = req.query.slug;
    if (!validSlug(slug)) return res.status(400).json({ error: 'bad slug' });
    if (!isOwner(req) && (await readPrivate()).has(slug)) return res.status(404).json({ error: 'not found' });
    const data = await readAI(slug);
    return data ? res.status(200).json(data) : res.status(404).json({ error: 'not found' });
  }
  if (req.method !== 'POST') return res.status(405).end();
  if (!isOwner(req)) return res.status(401).json({ error: 'unauthorized' });
  const { slug, data, setTitle } = req.body || {};
  if (!validSlug(slug) || !data || typeof data !== 'object') return res.status(400).json({ error: 'bad input' });
  const clean = {
    title: str(data.title, 140),
    summary: str(data.summary, 2000),
    points: (Array.isArray(data.points) ? data.points : []).map((p) => str(p, 300)).filter(Boolean).slice(0, 8),
    chapters: (Array.isArray(data.chapters) ? data.chapters : []).map((c) => ({ t: num(c.t), title: str(c.title, 120) })).filter((c) => c.title).slice(0, 30),
    segments: (Array.isArray(data.segments) ? data.segments : []).map((s) => ({ t: num(s.t), end: num(s.end), text: str(s.text, 2000) })).filter((s) => s.text).slice(0, 20000),
    created: new Date().toISOString(),
  };
  await writeAI(slug, clean);
  let titleSet = false;
  if (setTitle && clean.title && !(await readTitle(slug))) { await writeTitle(slug, clean.title); titleSet = true; }
  res.status(200).json({ ok: true, titleSet, title: titleSet ? clean.title : null });
}
