// Small charts, drawn as SVG by hand: the app has no chart library, and its
// Content-Security-Policy allows no inline styles, so every mark is placed
// with attributes and colored by a class (css/app.css, "Charts").
//
// Each function returns an element to put in the page. A chart with more
// than one series comes with a legend, every mark says its value when the
// pointer rests on it (an SVG <title>), and the colors of a set of series
// are given in a fixed order (s1, s2, ...), never by rank.

import { h } from './dom.js';

const NS = 'http://www.w3.org/2000/svg';

/** Create an SVG element; strings among the children become text. */
function s(tag, attrs = {}, ...children) {
  const el = document.createElementNS(NS, tag);
  for (const [key, value] of Object.entries(attrs))
    if (value !== null && value !== undefined && value !== false) el.setAttribute(key, value);
  for (const child of children.flat(Infinity))
    if (child !== null && child !== undefined && child !== false)
      el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return el;
}

const W = 560, LEFT = 46, RIGHT = 10, TOP = 10, BOTTOM = 24;

/** A number as people write it. */
export function fmt(n, digits = 0) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '';
  return Number(n).toLocaleString(undefined, { maximumFractionDigits: digits });
}

/** A round number at or above `max`, and the ticks up to it. */
function scale(max) {
  if (!(max > 0)) return { top: 1, ticks: [0, 1] };
  const pow  = 10 ** Math.floor(Math.log10(max));
  const step = [1, 2, 2.5, 5, 10].map(m => m * pow / 2).find(st => max / st <= 5) || pow * 5;
  const top  = Math.ceil(max / step) * step;
  const ticks = [];
  for (let v = 0; v <= top + step / 1000; v += step) ticks.push(v);
  return { top, ticks };
}

/** The frame every chart with axes shares: grid lines, y labels, some x labels. */
function frame(labels, max, height, format) {

  const { top, ticks } = scale(max);
  const plotW = W - LEFT - RIGHT, plotH = height - TOP - BOTTOM;
  const y     = v => TOP + plotH - (v / top) * plotH;
  const band  = plotW / Math.max(1, labels.length);
  const x     = i => LEFT + band * (i + 0.5);

  const svg = s('svg', { viewBox: `0 0 ${W} ${height}`, class: 'chart', role: 'img' });

  for (const t of ticks)
    svg.append(
      s('line', { x1: LEFT, x2: W - RIGHT, y1: y(t), y2: y(t), class: t === 0 ? 'axis' : 'grid' }),
      s('text', { x: LEFT - 6, y: y(t) + 3.5, class: 'tick', 'text-anchor': 'end' }, format(t)));

  // About eight labels along the bottom, however many points there are.
  const every = Math.max(1, Math.ceil(labels.length / 8));
  labels.forEach((label, i) => {
    if (i % every === 0)
      svg.append(s('text', { x: x(i), y: height - 7, class: 'tick', 'text-anchor': 'middle' }, label));
  });

  return { svg, x, y, band, plotH };
}

/** The key to a chart's colors. */
export function legend(series) {
  return h('div.chart-legend', series.map((ser, i) =>
    h('span', h('i', { class: `swatch ${ser.cls || `s${i + 1}`}` }), ser.label)));
}

function wrap(svg, series, empty) {
  if (empty) return h('p.empty', 'Nothing was recorded in this period.');
  return h('div.chart-box', series.length > 1 ? legend(series) : null, svg);
}

/**
 * Lines over time.
 * @param {object[]} rows    One per point, in order.
 * @param {string}   x       The key of a row's label.
 * @param {object[]} series  {key, label, cls}; `cls` defaults to s1, s2, ...
 * @param {function} format  How a value is written.
 */
export function lineChart({ rows, x, series, height = 200, format = v => fmt(v, 1), label = String }) {

  const value = (row, ser) => Number(row[ser.key]) || 0;
  const max   = Math.max(0, ...rows.flatMap(row => series.map(ser => value(row, ser))));
  const f     = frame(rows.map(row => label(row[x])), max, height, format);

  series.forEach((ser, i) => {
    const cls = ser.cls || `s${i + 1}`;
    const pts = rows.map((row, j) => `${f.x(j).toFixed(1)},${f.y(value(row, ser)).toFixed(1)}`);
    if (rows.length > 1) f.svg.append(s('polyline', { points: pts.join(' '), class: `line ${cls}` }));
    if (rows.length <= 45)
      rows.forEach((row, j) => f.svg.append(s('circle', { cx: f.x(j), cy: f.y(value(row, ser)), r: rows.length > 1 ? 2.6 : 4, class: `dot ${cls}` })));
  });

  // One column per point to rest the pointer on: it names every series' value.
  rows.forEach((row, j) => f.svg.append(
    s('rect', { x: f.x(j) - f.band / 2, y: TOP, width: f.band, height: f.plotH, class: 'hit' },
      s('title', {}, `${label(row[x])}\n${series.map(ser => `${ser.label}: ${format(value(row, ser))}`).join('\n')}`))));

  return wrap(f.svg, series, rows.length === 0);
}

/**
 * Bars over time, one stack per row.
 * @param {object[]} series  {key, label, cls}, bottom first.
 */
export function stackedBars({ rows, x, series, height = 200, format = v => fmt(v), label = String }) {

  const value = (row, ser) => Math.max(0, Number(row[ser.key]) || 0);
  const max   = Math.max(0, ...rows.map(row => series.reduce((sum, ser) => sum + value(row, ser), 0)));
  const f     = frame(rows.map(row => label(row[x])), max, height, format);
  const width = Math.max(2, Math.min(34, f.band * 0.72));

  rows.forEach((row, j) => {
    let base = 0;
    series.forEach((ser, i) => {
      const v = value(row, ser);
      if (v <= 0) return;
      const y1 = f.y(base + v), y0 = f.y(base);
      // A sliver of the surface between two segments keeps them apart.
      const hgt = Math.max(0.5, y0 - y1 - (base > 0 ? 1.5 : 0));
      f.svg.append(s('rect', { x: f.x(j) - width / 2, y: y1, width, height: hgt, rx: Math.min(2, hgt / 2), class: `bar ${ser.cls || `s${i + 1}`}` },
        s('title', {}, `${label(row[x])}\n${ser.label}: ${format(v)}`)));
      base += v;
    });
  });

  return wrap(f.svg, series, rows.length === 0);
}

/**
 * A ranked list as horizontal bars: the name, a bar, the number.
 * @param {object[]} rows   Sorted, largest first.
 * @param {number}   limit  How many to show before "Show all".
 */
export function rankedBars({ rows, name, value, limit = 10, format = v => fmt(v), label = String }) {

  if (!rows.length) return h('p.empty', 'Nothing was recorded in this period.');

  const max  = Math.max(...rows.map(row => Number(row[value]) || 0), 1);
  const line = row => {
    const bar = h('span.rank-bar');
    bar.style.width = `${Math.max(1, 100 * (Number(row[value]) || 0) / max)}%`;
    return h('div.rank-row', h('span.rank-name', { title: label(row[name]) }, label(row[name])), h('span.rank-track', bar), h('span.rank-value', format(row[value])));
  };

  const box = h('div.rank', rows.slice(0, limit).map(line));

  if (rows.length > limit) {
    const more = h('button.link-button', { type: 'button', onclick: () => { more.remove(); box.append(rows.slice(limit).map(line)); } },
      `Show all ${rows.length}`);
    box.append(more);
  }

  return box;
}

/**
 * A grid of cells shaded by value: one hue, darker for more.
 * @param {string[]} rowLabels,colLabels
 * @param {function} value  (row index, column index) -> number or null
 * @param {function} title  (row index, column index, value) -> tooltip
 */
export function heatMap({ rowLabels, colLabels, value, title, colEvery = 3 }) {

  const cell = 22, left = 34, top = 4, bottom = 16;
  const width = left + cell * colLabels.length + 4, height = top + cell * rowLabels.length + bottom;

  let max = 0;
  rowLabels.forEach((_, r) => colLabels.forEach((__, c) => { max = Math.max(max, Number(value(r, c)) || 0); }));

  const svg = s('svg', { viewBox: `0 0 ${width} ${height}`, class: 'chart heat', role: 'img' });

  rowLabels.forEach((name, r) => {
    svg.append(s('text', { x: left - 6, y: top + cell * r + cell / 2 + 3.5, class: 'tick', 'text-anchor': 'end' }, name));
    colLabels.forEach((_, c) => {
      const v = value(r, c);
      const none = v === null || v === undefined;
      svg.append(s('rect', {
        x: left + cell * c + 1, y: top + cell * r + 1, width: cell - 2, height: cell - 2, rx: 2,
        class: none ? 'cell none' : 'cell', 'fill-opacity': none ? null : (max > 0 ? 0.08 + 0.92 * (v / max) : 0.08) },
        s('title', {}, title(r, c, v))));
    });
  });

  colLabels.forEach((name, c) => {
    if (c % colEvery === 0)
      svg.append(s('text', { x: left + cell * c + cell / 2, y: height - 4, class: 'tick', 'text-anchor': 'middle' }, name));
  });

  return h('div.chart-box', svg);
}

/** Rows as the text of a CSV file. */
export function toCsv(rows, columns = null) {
  const cols  = columns || [...new Set(rows.flatMap(row => Object.keys(row)))];
  const quote = v => {
    if (v === null || v === undefined) return '';
    const text = String(v);
    // A cell that a spreadsheet would read as a formula is made plain text.
    const safe = /^[=+\-@\t\r]/.test(text) && typeof v !== 'number' ? `'${text}` : text;
    return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
  };
  return [cols.join(','), ...rows.map(row => cols.map(c => quote(row[c])).join(','))].join('\r\n') + '\r\n';
}
