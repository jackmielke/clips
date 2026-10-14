import { timingSafeEqual } from 'node:crypto';

// The owner proves who they are with the admin key, either as a Bearer header (API calls from the
// pages) or the clipKey cookie the pages set, so plain <video> and page loads work for private clips.
export function isOwner(req) {
  const header = (req.headers.authorization || '').replace(/^Bearer /, '');
  const cookie = /(?:^|;\s*)clipKey=([^;]*)/.exec(req.headers.cookie || '')?.[1];
  const want = Buffer.from(process.env.ADMIN_KEY || '');
  if (!want.length) return false;
  return [header, cookie && decodeURIComponent(cookie)].some((k) => {
    const got = Buffer.from(k || '');
    return got.length === want.length && timingSafeEqual(got, want);
  });
}
