import { randomUUID } from 'node:crypto';
import { isOwner } from './_auth.js';
import { validSlug } from './_titles.js';
import { readThread, writeThread } from './_comments.js';
import { readPrivate } from './_visibility.js';

export const EMOJI = ['👍', '❤️', '😂', '🔥', '👏', '🤯'];
const MAX = 500;   // per clip, comments and reactions each

const clean = (s, n) => (typeof s === 'string' ? s.replace(/\s+/g, ' ').trim().slice(0, n) : '');
// Comment text keeps line breaks (up to one blank line); names stay on one line.
const cleanText = (s) => (typeof s === 'string' ? s.replace(/[^\S\n]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim().slice(0, 1000) : '');
const clampT = (t) => (Number.isFinite(t) ? Math.min(Math.max(0, Math.round(t * 10) / 10), 36000) : null);

// GET ?slug=  ·  POST {slug, name, text, t} or {slug, emoji, t}  ·  DELETE ?slug=&id= (owner only)
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const slug = req.method === 'POST' ? req.body?.slug : req.query.slug;
  if (!validSlug(slug)) return res.status(400).json({ error: 'bad slug' });
  if (!isOwner(req) && (await readPrivate()).has(slug)) return res.status(404).json({ error: 'not found' });

  if (req.method === 'GET') return res.status(200).json(await readThread(slug));

  if (req.method === 'POST') {
    const b = req.body || {};
    const thread = await readThread(slug);
    const at = new Date().toISOString();
    if (b.emoji !== undefined) {
      if (!EMOJI.includes(b.emoji)) return res.status(400).json({ error: 'bad emoji' });
      if (thread.reactions.length >= MAX) return res.status(429).json({ error: 'full' });
      thread.reactions.push({ e: b.emoji, t: clampT(b.t), at });
    } else {
      const name = clean(b.name, 40), text = cleanText(b.text);
      if (!name || !text) return res.status(400).json({ error: 'name and text required' });
      if (thread.comments.length >= MAX) return res.status(429).json({ error: 'full' });
      thread.comments.push({ id: randomUUID(), name, text, t: clampT(b.t), at });
    }
    await writeThread(slug, thread);
    return res.status(200).json(thread);
  }

  if (req.method === 'DELETE') {
    if (!isOwner(req)) return res.status(401).json({ error: 'unauthorized' });
    const thread = await readThread(slug);
    thread.comments = thread.comments.filter((c) => c.id !== req.query.id);
    await writeThread(slug, thread);
    return res.status(200).json(thread);
  }
  res.status(405).end();
}
