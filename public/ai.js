// AI summary, chapters and a clickable transcript under a clip, from /api/ai (made by ai-clip.py).
// Every timestamp seeks the video, and the transcript follows along as it plays.
(async () => {
  const v = document.getElementById('v');
  const bar = document.querySelector('.bar');
  const player = document.querySelector('.player');
  const slug = location.pathname.replace(/^\/|\/$/g, '');
  if (!v || !bar || !/^[0-9a-f]{8}$/.test(slug)) return;
  const data = await fetch('/api/ai?slug=' + slug).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (!data || !(data.summary || (data.segments || []).length)) return;

  const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const fmt = (t) => { t = Math.max(0, Math.floor(t || 0)); const h = Math.floor(t / 3600), m = Math.floor(t / 60) % 60, s = String(t % 60).padStart(2, '0');
    return h ? h + ':' + String(m).padStart(2, '0') + ':' + s : m + ':' + s; };
  const seek = (t) => { v.currentTime = t; v.play().catch(() => {}); if (player && player.getBoundingClientRect().top < 0) player.scrollIntoView({ behavior: 'smooth', block: 'start' }); };
  const chip = (t) => { const b = el('button', 'ai-chip', fmt(t)); b.type = 'button'; b.title = 'Jump to ' + fmt(t); b.onclick = () => seek(t); return b; };

  const box = el('section', 'ai');
  const tabs = el('div', 'ai-tabs');
  const panes = {};
  const show = (name) => { Object.entries(panes).forEach(([k, p]) => { p.hidden = k !== name; tabs.querySelector('[data-k="' + k + '"]').classList.toggle('on', k === name); });
    try { localStorage.setItem('clipAITab', name); } catch (e) {} };
  const addTab = (k, label) => { const b = el('button', '', label); b.type = 'button'; b.dataset.k = k; b.onclick = () => show(k); tabs.append(b); panes[k] = el('div', 'ai-pane'); };

  const segs = data.segments || [];
  if (data.summary || (data.chapters || []).length) addTab('summary', 'Summary');
  if (segs.length) addTab('transcript', 'Transcript');
  tabs.append(el('span', 'ai-badge', '✨ AI generated'));
  box.append(tabs, ...Object.values(panes));

  if (panes.summary) {
    const p = panes.summary;
    if (data.summary) p.append(el('p', 'ai-summary', data.summary));
    if ((data.points || []).length) { const ul = el('ul', 'ai-points'); data.points.forEach((x) => ul.append(el('li', '', x))); p.append(ul); }
    if ((data.chapters || []).length) {
      p.append(el('h3', 'ai-sub', 'Chapters'));
      const ol = el('ol', 'ai-chapters');
      data.chapters.forEach((c) => { const li = el('li', ''); li.append(chip(c.t), el('span', '', c.title)); li.onclick = (e) => { if (e.target === li || e.target.tagName === 'SPAN') seek(c.t); }; ol.append(li); });
      p.append(ol);
    }
  }

  let rows = [];
  if (panes.transcript) {
    const p = panes.transcript;
    const tools = el('div', 'ai-tools');
    const q = el('input', 'ai-search'); q.type = 'search'; q.placeholder = 'Search the transcript';
    const copy = el('button', 'ai-copy', 'Copy text'); copy.type = 'button';
    copy.onclick = async () => { try { await navigator.clipboard.writeText(segs.map((s) => '[' + fmt(s.t) + '] ' + s.text).join('\n')); copy.textContent = 'Copied'; setTimeout(() => (copy.textContent = 'Copy text'), 1500); } catch (e) {} };
    tools.append(q, copy);
    const list = el('div', 'ai-lines');
    rows = segs.map((s) => { const r = el('div', 'ai-line'); r.append(chip(s.t), el('span', 'ai-text', s.text)); r.querySelector('.ai-text').onclick = () => seek(s.t); list.append(r); return r; });
    q.addEventListener('keydown', (e) => e.stopPropagation());
    q.addEventListener('input', () => { const w = q.value.trim().toLowerCase(); rows.forEach((r, i) => { r.hidden = !!w && !segs[i].text.toLowerCase().includes(w); }); });
    p.append(tools, list);
    // Follow playback: highlight the current line and keep it in view, unless the viewer just scrolled the list.
    let cur = -1, userScroll = 0;
    list.addEventListener('wheel', () => (userScroll = Date.now()), { passive: true });
    list.addEventListener('touchmove', () => (userScroll = Date.now()), { passive: true });
    v.addEventListener('timeupdate', () => {
      const t = v.currentTime; let i = -1;
      for (let k = 0; k < segs.length && segs[k].t <= t + 0.2; k++) i = k;
      if (i === cur) return;
      if (rows[cur]) rows[cur].classList.remove('on');
      cur = i;
      if (!rows[i]) return;
      rows[i].classList.add('on');
      if (!panes.transcript.hidden && Date.now() - userScroll > 4000) list.scrollTo({ top: rows[i].offsetTop - 60, behavior: 'smooth' });
    });
  }

  let first = Object.keys(panes)[0];
  try { const s = localStorage.getItem('clipAITab'); if (panes[s]) first = s; } catch (e) {}
  show(first);
  bar.insertAdjacentElement('afterend', box);
})();
