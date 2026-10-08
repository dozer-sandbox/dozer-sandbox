// components/qr — An invite's QR code (606), drawn as SVG from the module matrix the server sends (rows of 0/1) —
// createElementNS and attributes only, never markup. Dark on light whatever the theme (a camera needs the contrast),
// with the standard four-module quiet zone.
import { SVG_NS } from '../dom/icons-8392ebb8cb8879e3.js';

/**
 * @param {string[]} rows   the matrix, one string of '0'/'1' per row
 * @param {string} label    what it is, for assistive tech
 * @returns {SVGSVGElement}
 */
export function qrSvg(rows, label) {
  const n = rows.length, q = 4, size = n + 2 * q;
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('class', 'qr');
  svg.setAttribute('viewBox', '0 0 ' + size + ' ' + size);
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', label);
  svg.setAttribute('shape-rendering', 'crispEdges');
  const bg = document.createElementNS(SVG_NS, 'rect');
  bg.setAttribute('class', 'qr-light');
  bg.setAttribute('width', String(size));
  bg.setAttribute('height', String(size));
  let d = '';
  rows.forEach((row, y) => {
    let x = 0;
    while (x < n) {
      if (row[x] !== '1') { x++; continue; }
      let end = x;
      while (end < n && row[end] === '1') end++;
      d += 'M' + (x + q) + ' ' + (y + q) + 'h' + (end - x) + 'v1h-' + (end - x) + 'z';
      x = end;
    }
  });
  const path = document.createElementNS(SVG_NS, 'path');
  path.setAttribute('class', 'qr-dark');
  path.setAttribute('d', d);
  svg.append(bg, path);
  return svg;
}
