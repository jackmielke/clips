// Owner tools on a clip page: a Public / Private switch next to Copy link. Only shows in a browser
// holding the owner key, and keeps the clipKey cookie set so private videos play for the owner.
(async () => {
  const slug = location.pathname.replace(/^\/|\/$/g, '');
  const actions = document.querySelector('.actions');
  let key = null;
  try { key = localStorage.getItem('clipKey'); } catch (e) {}
  if (!key || !actions || !/^[0-9a-f]{8}$/.test(slug)) return;
  const auth = { Authorization: 'Bearer ' + key };
  if (!(await fetch('/api/title', { headers: auth }).then((r) => r.ok).catch(() => false))) return;
  document.cookie = 'clipKey=' + encodeURIComponent(key) + '; Path=/; Max-Age=31536000; SameSite=Lax; Secure';

  const list = await fetch('/api/visibility').then((r) => r.json()).catch(() => null);
  if (!list) return;
  let priv = list.private.includes(slug);
  const btn = document.createElement('button');
  btn.className = 'btn';
  const show = () => {
    btn.textContent = priv ? '🔒 Private' : '🌐 Public';
    btn.title = priv ? 'Only you can watch this. Click to make it public.' : 'Anyone with the link can watch. Click to make it private.';
  };
  show();
  btn.onclick = async () => {
    btn.disabled = true;
    const r = await fetch('/api/visibility', { method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' }, body: JSON.stringify({ slug, private: !priv }) }).catch(() => null);
    if (r && r.ok) priv = !priv;
    btn.disabled = false;
    show();
  };
  actions.prepend(btn);
})();
