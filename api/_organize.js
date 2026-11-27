import { get, put } from '@vercel/blob';

// The owner's favorites and tags for every clip, in one private file: { "<slug>": { fav: true, tags: ["demo"] } }.
const PATH = 'settings/organize.json';

export const cleanTags = (tags) => [...new Set((Array.isArray(tags) ? tags : [])
  .map((t) => String(t).replace(/\s+/g, ' ').trim().toLowerCase().slice(0, 40)).filter(Boolean))].slice(0, 20);

export async function readOrganize() {
  try {
    const r = await get(PATH, { access: 'private', useCache: false });
    if (!r || r.statusCode !== 200) return {};
    return JSON.parse(await new Response(r.stream).text()) || {};
  } catch { return {}; }
}

export async function setOrganize(slug, { fav, tags }) {
  const all = await readOrganize();
  const cur = all[slug] || {};
  if (typeof fav === 'boolean') cur.fav = fav;
  if (tags !== undefined) cur.tags = cleanTags(tags);
  if (!cur.fav) delete cur.fav;
  if (!cur.tags?.length) delete cur.tags;
  if (Object.keys(cur).length) all[slug] = cur; else delete all[slug];
  await put(PATH, JSON.stringify(all), { access: 'private', allowOverwrite: true, addRandomSuffix: false, contentType: 'application/json' });
  return all[slug] || {};
}
