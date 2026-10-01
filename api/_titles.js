import { get, put } from '@vercel/blob';

const path = (slug) => `titles/${slug}.txt`;
export const validSlug = (s) => typeof s === 'string' && /^[0-9a-f]{8}$/.test(s);

export async function readTitle(slug) {
  try {
    const r = await get(path(slug), { access: 'private', useCache: false });
    if (!r || r.statusCode !== 200) return null;
    return (await new Response(r.stream).text()).trim() || null;
  } catch { return null; }
}

export async function writeTitle(slug, title) {
  await put(path(slug), title, { access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'text/plain' });
}
