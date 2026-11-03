import { get, put } from '@vercel/blob';

// One private JSON blob per clip with what ai-clip.py made from its audio:
// { title, summary, points: [..], chapters: [{ t, title }], segments: [{ t, end, text }], created }
const path = (slug) => `ai/${slug}.json`;

export async function readAI(slug) {
  try {
    const r = await get(path(slug), { access: 'private', useCache: false });
    if (!r || r.statusCode !== 200) return null;
    return JSON.parse(await new Response(r.stream).text());
  } catch { return null; }
}

export async function writeAI(slug, data) {
  await put(path(slug), JSON.stringify(data), {
    access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'application/json',
  });
}
