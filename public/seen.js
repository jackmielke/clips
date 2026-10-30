// Remembers the clips this browser has opened, newest first, so the locked home page can list them.
try {
  const slug = location.pathname.slice(1);
  if (/^[0-9a-f]{8}$/.test(slug)) {
    const title = document.querySelector('meta[name="clip-title"]')?.content || document.title;
    const seen = JSON.parse(localStorage.getItem('clipsSeen') || '[]').filter((c) => c.slug !== slug);
    localStorage.setItem('clipsSeen', JSON.stringify([{ slug, title }, ...seen].slice(0, 100)));
  }
} catch {}
