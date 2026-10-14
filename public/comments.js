// Comments and reactions for a clip page. Comments are signed with a name (remembered in this
// browser) and pinned to a moment in the video; both show as marks under the player.
(() => {
  const v = document.getElementById('v');
  const main = document.querySelector('main');
  const player = document.querySelector('.player');
  const slug = location.pathname.replace(/^\/|\/$/g, '').replace(/^c\//, '').replace(/\.html$/, '');
  if (!v || !main || !player || !/^[0-9a-f]{8}$/.test(slug)) return;

  const EMOJI = ['👍', '❤️', '😂', '🔥', '👏', '🤯'];
  const store = {
    get: (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: (k, val) => { try { localStorage.setItem(k, val); } catch (e) {} },
  };
  const ownerKey = store.get('clipKey');
  const fmt = (t) => { t = Math.max(0, Math.round(t || 0)); return Math.floor(t / 60) + ':' + String(t % 60).padStart(2, '0'); };
  const ago = (iso) => {
    const s = (Date.now() - new Date(iso)) / 1000;
    if (s < 60) return 'just now';
    if (s < 3600) return Math.floor(s / 60) + 'm ago';
    if (s < 86400) return Math.floor(s / 3600) + 'h ago';
    if (s < 86400 * 30) return Math.floor(s / 86400) + 'd ago';
    return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  };
  const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const seek = (t) => { if (t == null) return; v.currentTime = t; v.play().catch(() => {}); player.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); };
  let thread = { comments: [], reactions: [] };

  // Marks under the player
  const marks = el('div', 'cm-marks');
  player.insertAdjacentElement('afterend', marks);

  // Reactions row
  const reacts = el('div', 'cm-reacts');
  const buttons = {};
  EMOJI.forEach((e) => {
    const b = el('button', 'cm-react');
    b.type = 'button';
    b.title = 'React at this moment';
    b.append(el('span', 'cm-emoji', e), el('span', 'cm-count', ''));
    b.onclick = () => react(e, b);
    buttons[e] = b;
    reacts.append(b);
  });

  // Comments section
  const box = el('section', 'cm');
  const head = el('h2', 'cm-head', 'Comments');
  const form = el('form', 'cm-form');
  const text = el('textarea', 'cm-text');
  text.rows = 2; text.maxLength = 1000; text.placeholder = 'Add a comment…';
  const row = el('div', 'cm-row');
  const name = el('input', 'cm-name');
  name.placeholder = 'Your name'; name.maxLength = 40; name.value = store.get('clipName') || '';
  const atLabel = el('label', 'cm-at');
  const atBox = el('input'); atBox.type = 'checkbox'; atBox.checked = true;
  const atText = el('span', '', 'at 0:00');
  atLabel.append(atBox, atText);
  const send = el('button', 'cm-send', 'Post'); send.type = 'submit';
  const err = el('div', 'cm-err');
  row.append(name, atLabel, send);
  form.append(text, row, err);
  const list = el('div', 'cm-list');
  box.append(head, form, list);

  const hint = document.querySelector('.hint');
  (hint || main.lastElementChild).insertAdjacentElement('beforebegin', reacts);
  reacts.insertAdjacentElement('afterend', box);

  // Typing a comment pins it to where the video is, and pauses so the moment holds still.
  let pinned = 0;
  const repin = () => { pinned = v.currentTime || 0; atText.textContent = 'at ' + fmt(pinned); };
  v.addEventListener('timeupdate', () => { if (document.activeElement !== text && !text.value) repin(); });
  text.addEventListener('focus', () => { if (!text.value) repin(); if (!v.paused) v.pause(); });
  // Keep the page's keyboard shortcuts (space, arrows, < >) out of the form.
  form.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) form.requestSubmit();
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.textContent = '';
    if (!name.value.trim()) { err.textContent = 'Add your name so people know who said it.'; name.focus(); return; }
    if (!text.value.trim()) { text.focus(); return; }
    store.set('clipName', name.value.trim());
    send.disabled = true; send.textContent = 'Posting…';
    const ok = await post({ name: name.value, text: text.value, t: atBox.checked ? pinned : null });
    send.disabled = false; send.textContent = 'Post';
    if (ok) { text.value = ''; text.blur(); repin(); } else err.textContent = "Couldn't post that. Try again?";
  });

  async function post(body) {
    try {
      const r = await fetch('/api/comments', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ slug, ...body }) });
      if (!r.ok) return false;
      thread = await r.json(); render(); return true;
    } catch (e) { return false; }
  }

  async function react(e, b) {
    b.classList.remove('cm-pop'); void b.offsetWidth; b.classList.add('cm-pop');
    const burst = el('span', 'cm-burst', e); b.append(burst); setTimeout(() => burst.remove(), 900);
    thread.reactions.push({ e, t: v.currentTime || 0, at: new Date().toISOString() }); render();
    await post({ emoji: e, t: v.currentTime || 0 });
  }

  async function remove(id) {
    if (!confirm('Delete this comment?')) return;
    const r = await fetch('/api/comments?slug=' + slug + '&id=' + encodeURIComponent(id), { method: 'DELETE', headers: { Authorization: 'Bearer ' + ownerKey } }).catch(() => null);
    if (r && r.ok) { thread = await r.json(); render(); }
  }

  function render() {
    const counts = {};
    thread.reactions.forEach((r) => { counts[r.e] = (counts[r.e] || 0) + 1; });
    EMOJI.forEach((e) => { buttons[e].querySelector('.cm-count').textContent = counts[e] || ''; });

    const n = thread.comments.length;
    head.textContent = n ? 'Comments · ' + n : 'Comments';
    list.replaceChildren();
    const sorted = [...thread.comments].sort((a, b) => (a.t ?? 1e9) - (b.t ?? 1e9) || a.at.localeCompare(b.at));
    if (!n) list.append(el('div', 'cm-empty', 'No comments yet. Be the first.'));
    sorted.forEach((c) => {
      const item = el('div', 'cm-item');
      const avatar = el('div', 'cm-avatar', c.name.trim()[0].toUpperCase());
      const bodyEl = el('div', 'cm-body');
      const meta = el('div', 'cm-meta');
      meta.append(el('b', '', c.name));
      if (c.t != null) { const chip = el('button', 'cm-chip', fmt(c.t)); chip.type = 'button'; chip.onclick = () => seek(c.t); meta.append(chip); }
      meta.append(el('span', 'cm-when', ago(c.at)));
      if (ownerKey) { const del = el('button', 'cm-del', 'Delete'); del.type = 'button'; del.onclick = () => remove(c.id); meta.append(del); }
      bodyEl.append(meta, el('div', 'cm-says', c.text));
      item.append(avatar, bodyEl);
      list.append(item);
    });
    drawMarks();
  }

  function drawMarks() {
    const d = v.duration;
    marks.replaceChildren();
    if (!isFinite(d) || d <= 0) return;
    thread.reactions.forEach((r) => {
      if (r.t == null) return;
      const m = el('button', 'cm-mark cm-mark-r', r.e);
      m.type = 'button'; m.style.left = Math.min(100, (r.t / d) * 100) + '%'; m.title = fmt(r.t); m.onclick = () => seek(r.t);
      marks.append(m);
    });
    thread.comments.forEach((c) => {
      if (c.t == null) return;
      const m = el('button', 'cm-mark cm-mark-c', c.name.trim()[0].toUpperCase());
      m.type = 'button'; m.style.left = Math.min(100, (c.t / d) * 100) + '%';
      m.title = fmt(c.t) + ' · ' + c.name + ': ' + c.text.slice(0, 80);
      m.onclick = () => seek(c.t);
      marks.append(m);
    });
  }
  v.addEventListener('durationchange', drawMarks);
  v.addEventListener('loadedmetadata', drawMarks);

  fetch('/api/comments?slug=' + slug).then((r) => r.ok ? r.json() : thread).then((j) => { thread = j; render(); }).catch(render);
})();
