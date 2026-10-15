// The style guide's script. Everything it draws comes from the repository itself, read over HTTP:
//  · the icons: the dashboard's vendored Lucide set — VENDOR.json's list, each file fetched and made one inline sprite
//    (as the asset build makes it); then every <i data-i="name"> becomes the dashboard's icon markup.
//  · the marks: the icon registry (Sources/DozerKit/Recipes/icons/icons.json and its files) — every <span data-mark=ID>
//    gets that mark, and the registry section lists them all.
//  · light and dark: each .pair's panel is cloned as the dark one (color-scheme decides app.css's light-dark()).
//  · the theme switch: auto · light · dark — the app's own data-theme on <html>.
// No framework; nothing outside the repository is fetched.
(async function () {
  const NS = 'http://www.w3.org/2000/svg';
  const ROOT = '../../';
  const VENDOR = ROOT + 'Sources/DozerWeb/WebSource/vendor/lucide-static/';
  const ICONS = ROOT + 'Sources/DozerKit/Recipes/icons/';
  // One file at a time, retried once: a simple local server (python3 -m http.server) drops some of 60 parallel requests.
  const get = async (url, as) => {
    for (let i = 0; ; i++) {
      try { const r = await fetch(url); if (!r.ok) throw new Error(r.status + ' ' + url); return as === 'json' ? await r.json() : await r.text(); }
      catch (e) { if (i >= 1) throw e; }
    }
  };
  const parse = (text) => new DOMParser().parseFromString(text, 'image/svg+xml').documentElement;

  // Light and dark side by side (before any icon is expanded, so both panels get theirs).
  for (const p of document.querySelectorAll('.pair')) {
    const l = p.querySelector('.scheme'); if (!l || p.querySelectorAll('.scheme').length > 1) continue;
    l.dataset.s = 'light'; const d = l.cloneNode(true); d.dataset.s = 'dark'; p.append(d);
  }

  // The vendored Lucide set → one inline sprite.
  const sprite = document.createElementNS(NS, 'svg');
  sprite.setAttribute('width', '0'); sprite.setAttribute('height', '0'); sprite.setAttribute('aria-hidden', 'true');
  sprite.style.position = 'absolute';
  const defs = document.createElementNS(NS, 'defs');
  sprite.append(defs);
  document.body.prepend(sprite);
  let names = [];
  try {
    const v = await get(VENDOR + 'VENDOR.json', 'json');
    names = v.files.filter((f) => f.serve === 'icon').map((f) => f.file.replace(/\.svg$/, '')).sort();
    document.querySelector('[data-icon-count]').textContent = names.length + ' icons, ' + v.package + ' ' + v.version + ' (' + v.licence + ')';
    const files = [];
    for (const n of names) files.push(await get(VENDOR + n + '.svg'));
    names.forEach((n, i) => {
      const svg = parse(files[i]);
      const sym = document.createElementNS(NS, 'symbol');
      sym.id = n; sym.setAttribute('viewBox', svg.getAttribute('viewBox') || '0 0 24 24');
      for (const c of [...svg.children]) sym.append(document.importNode(c, true));
      defs.append(sym);
    });
  } catch (e) {
    document.querySelector('[data-icon-count]').textContent = 'the vendored icons could not be read (' + e.message + ') — serve the repository root over HTTP';
  }
  const one = (n) => { const s = document.createElementNS(NS, 'svg'); s.setAttribute('class', 'icon'); s.setAttribute('aria-hidden', 'true');
    s.setAttribute('data-icon', n); const u = document.createElementNS(NS, 'use'); u.setAttribute('href', '#' + n); s.append(u); return s; };
  for (const i of document.querySelectorAll('i[data-i]')) {
    const n = i.dataset.i;
    if (n.includes('+')) { const g = document.createElement('span'); g.className = 'icon-pair'; g.setAttribute('aria-hidden', 'true'); for (const x of n.split('+')) g.append(one(x)); i.replaceWith(g); }
    else i.replaceWith(one(n));
  }
  const index = document.getElementById('icons');
  for (const n of names) { const d = document.createElement('div'); d.append(one(n), document.createTextNode(n)); index.append(d); }

  // The icon registry → the marks.
  try {
    const reg = await get(ICONS + 'icons.json', 'json');
    const svgs = {};
    for (const e of reg.icons) svgs[e.id] = await get(ICONS + e.variants.mono);
    const markNode = (id) => { const s = document.createElement('span'); s.className = 'mark'; s.setAttribute('aria-hidden', 'true');
      if (svgs[id]) s.append(document.importNode(parse(svgs[id]), true)); return s; };
    for (const m of document.querySelectorAll('span[data-mark]')) {
      const n = markNode(m.dataset.mark); n.className = m.className || 'mark'; m.replaceWith(n);
    }
    for (const list of document.querySelectorAll('.marks')) {   // one per panel (light and dark)
      for (const e of reg.icons) {
        const d = document.createElement('div');
        const b = document.createElement('b'); b.textContent = e.name;
        const meta = document.createElement('span'); meta.textContent = e.kind + (e.vendor ? ' · ' + e.vendor : '') + ' · ' + e.allowed;
        d.append(markNode(e.id), b, meta);
        list.append(d);
      }
    }
  } catch (e) {
    for (const list of document.querySelectorAll('.marks')) list.textContent = 'the icon registry could not be read (' + e.message + ')';
  }

  for (const e of document.querySelectorAll('[data-token]')) {
    e.textContent = getComputedStyle(document.documentElement).getPropertyValue(e.dataset.token).trim().replace(/\s+/g, ' ');
  }

  // The theme switch (the app's data-theme); remembered for this page.
  const bar = document.createElement('div');
  bar.className = 'sg-bar'; bar.setAttribute('aria-label', 'Theme of this page');
  const apply = (t) => {
    if (t === 'auto') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = t;
    for (const b of bar.querySelectorAll('button')) b.setAttribute('aria-pressed', String(b.dataset.t === t));
    try { localStorage.setItem('sg.theme', t); } catch (_) { /* no storage: this visit only */ }
  };
  for (const t of ['auto', 'light', 'dark']) {
    const b = document.createElement('button'); b.type = 'button'; b.dataset.t = t; b.textContent = t;
    b.addEventListener('click', () => apply(t)); bar.append(b);
  }
  document.body.append(bar);
  let saved = 'auto';
  try { saved = localStorage.getItem('sg.theme') || 'auto'; } catch (_) { /* */ }
  apply(new URLSearchParams(location.hash.slice(1)).get('theme') || saved);
  document.documentElement.dataset.ready = '1';
})();
