// render-web-icons.mjs — the dashboard's app icons (`doz ui`'s web app manifest): render the PNGs the
// manifest and Safari need from the two SVG masters in Sources/DozerWeb/WebSource/icons, ONCE, with
// headless Chrome over the DevTools protocol, and record what was rendered from what in
// icons/PROVENANCE.json. The PNGs are committed; `make web-assets-check` (Scripts/build-web-assets.swift)
// refuses them when a master's or a PNG's sha256 is not the one recorded here — an SVG edited without a
// re-render cannot ship.
//
//   icon.svg           the "any" icon (a tile on the macOS icon grid, transparent around it):
//                      the favicon, the manifest's SVG and its 192/512 PNGs
//   icon-maskable.svg  full-bleed (the drawing inside the central 80 % circle): the maskable 512 PNG and
//                      the 180 px apple-touch-icon (iOS and Safari round the corners themselves)
//
// Usage: node Scripts/render-web-icons.mjs        (CHROME=… for another Chrome). Node ≥ 22, no packages.
// Writes only inside the icons directory (and a scratch Chrome profile it removes).
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const ICONS = join(dirname(fileURLToPath(import.meta.url)), '..', 'Sources/DozerWeb/WebSource/icons');
const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const OUTPUTS = [
  { file: 'icon-192.png', size: 192, from: 'icon.svg' },
  { file: 'icon-512.png', size: 512, from: 'icon.svg' },
  { file: 'icon-maskable-512.png', size: 512, from: 'icon-maskable.svg' },
  { file: 'icon-180.png', size: 180, from: 'icon-maskable.svg' },
];
const sha = (b) => createHash('sha256').update(b).digest('hex');

const profile = mkdtempSync(join(tmpdir(), 'doz-icons-'));
const chrome = spawn(CHROME, ['--headless=new', `--user-data-dir=${profile}`, '--remote-debugging-port=0', '--no-first-run',
  '--no-default-browser-check', '--force-device-scale-factor=1', 'about:blank'], { stdio: 'ignore' });
let ws, nextId = 1;
const pending = new Map();
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, { resolve, reject });
  ws.send(JSON.stringify({ id, method, params }));
});
try {
  const f = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 100 && !existsSync(f); i++) await sleep(100);
  const port = readFileSync(f, 'utf8').split('\n')[0];
  let page;
  for (let i = 0; i < 50 && !page; i++) { page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); if (!page) await sleep(100); }
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener('open', r, { once: true }));
  ws.addEventListener('message', (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(m.error.message)) : p.resolve(m.result); }
  });
  await send('Page.enable');
  await send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  for (const o of OUTPUTS) {
    const svg = readFileSync(join(ICONS, o.from));
    await send('Emulation.setDeviceMetricsOverride', { width: o.size, height: o.size, deviceScaleFactor: 1, mobile: false });
    const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:transparent}</style></head><body>` +
      `<img id="i" width="${o.size}" height="${o.size}" style="display:block" src="data:image/svg+xml;base64,${svg.toString('base64')}"></body></html>`;
    await send('Page.navigate', { url: 'data:text/html;base64,' + Buffer.from(html).toString('base64') });
    await sleep(400);
    const r = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width: o.size, height: o.size, scale: 1 } });
    const png = Buffer.from(r.data, 'base64');
    const w = png.readUInt32BE(16), h = png.readUInt32BE(20);
    if (w !== o.size || h !== o.size) throw new Error(`${o.file} came out ${w}x${h}`);
    writeFileSync(join(ICONS, o.file), png);
    console.log(`rendered ${o.file} (${o.size}x${o.size}) from ${o.from}`);
  }
  const prov = {
    renderer: 'Scripts/render-web-icons.mjs — headless Google Chrome over the DevTools protocol, transparent background, device scale 1',
    sources: [
      { file: 'icon.svg', served: true, sha256: sha(readFileSync(join(ICONS, 'icon.svg'))) },
      { file: 'icon-maskable.svg', served: false, sha256: sha(readFileSync(join(ICONS, 'icon-maskable.svg'))) },
    ],
    files: OUTPUTS.map((o) => ({ file: o.file, from: o.from, size: o.size, sha256: sha(readFileSync(join(ICONS, o.file))) })),
  };
  writeFileSync(join(ICONS, 'PROVENANCE.json'), JSON.stringify(prov, null, 2) + '\n');
  console.log('wrote PROVENANCE.json');
} finally {
  chrome.kill();
  await sleep(300);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(0);
