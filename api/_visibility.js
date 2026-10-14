import { get, put } from '@vercel/blob';

// Every clip is public (anyone with the link) unless its slug is in this one private list.
const PATH = 'settings/private.json';

export async function readPrivate() {
  try {
    const r = await get(PATH, { access: 'private', useCache: false });
    if (!r || r.statusCode !== 200) return new Set();
    return new Set(JSON.parse(await new Response(r.stream).text()));
  } catch { return new Set(); }
}

export async function setPrivate(slug, on) {
  const list = await readPrivate();
  if (on) list.add(slug); else list.delete(slug);
  await put(PATH, JSON.stringify([...list]), {
    access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'application/json',
  });
  return list;
}
