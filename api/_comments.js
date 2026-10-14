import { get, put } from '@vercel/blob';

// One private JSON blob per clip: { comments: [...], reactions: [...] }, stored next to the titles.
const path = (slug) => `comments/${slug}.json`;

export async function readThread(slug) {
  try {
    const r = await get(path(slug), { access: 'private', useCache: false });
    if (!r || r.statusCode !== 200) return { comments: [], reactions: [] };
    const j = JSON.parse(await new Response(r.stream).text());
    return { comments: j.comments || [], reactions: j.reactions || [] };
  } catch { return { comments: [], reactions: [] }; }
}

export async function writeThread(slug, thread) {
  await put(path(slug), JSON.stringify(thread), {
    access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'application/json',
  });
}
