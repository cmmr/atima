// The part of the address after #: which page is on screen and, for a
// figure, the settings it was made with, so that a reload or a bookmark
// comes back to the same figure:
//
//   #/plot/adiv_boxplot              the page and its argument
//   #/plot/adiv_boxplot/eyJhIjp7...  and the figure's settings
//
// The settings are JSON, written in the letters an address may hold
// (base64url). This file is pure (no page, no imports), so the tests can
// run it.

const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

// The settings in an address are no longer than this. Longer ones (a
// colour chosen by hand for each of very many groups) are left out, and
// the address then names the page alone.
export const STATE_MAX = 6000;

/** Text as base64url. */
function toLetters(text) {
  // One character per byte of the text's UTF-8.
  const bytes = unescape(encodeURIComponent(text));
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2);
    out += LETTERS[a >> 2] + LETTERS[(a & 3) << 4 | (b || 0) >> 4];
    if (i + 1 < bytes.length) out += LETTERS[(b & 15) << 2 | (c || 0) >> 6];
    if (i + 2 < bytes.length) out += LETTERS[c & 63];
  }
  return out;
}

/** base64url back to text. Throws on what is not. */
function fromLetters(letters) {
  let bytes = '';
  for (let i = 0; i < letters.length; i += 4) {
    const n = [0, 1, 2, 3].map(k => (i + k < letters.length ? LETTERS.indexOf(letters[i + k]) : 0));
    if (n.includes(-1)) throw new Error('not base64url');
    bytes += String.fromCharCode(n[0] << 2 | n[1] >> 4);
    if (i + 2 < letters.length) bytes += String.fromCharCode((n[1] & 15) << 4 | n[2] >> 2);
    if (i + 3 < letters.length) bytes += String.fromCharCode((n[2] & 3) << 6 | n[3]);
  }
  return decodeURIComponent(escape(bytes));
}

/**
 * A figure's settings as they go into the address.
 * @param {object} state  `{a, s, v, f, d}`: the function's arguments, the
 *   sample filter, the image settings, "fit to window" and the rarefaction
 *   depth. Whatever is at its default is left out by the caller.
 * @return {string} '' when there is nothing to keep, or too much.
 */
export function encodeState(state) {
  const kept = {};
  for (const [key, value] of Object.entries(state || {})) {
    if (value === undefined || value === null) continue;
    if (typeof value === 'object' && !Array.isArray(value) && JSON.stringify(value) === '{}') continue;
    kept[key] = value;
  }
  if (Object.keys(kept).length === 0) return '';
  const text = toLetters(JSON.stringify(kept));
  return text.length > STATE_MAX ? '' : text;
}

/**
 * The settings in an address, or null when it has none or they cannot be
 * read (a link cut short, or written by hand).
 */
export function decodeState(text) {
  if (typeof text !== 'string' || text === '' || text.length > STATE_MAX) return null;
  try {
    const state = JSON.parse(fromLetters(text));
    return state !== null && typeof state === 'object' && !Array.isArray(state) ? state : null;
  } catch { return null; }
}

/**
 * Settings read from an address, in the shapes the rest of the app counts
 * on. An address can be written by anyone, so whatever is not of the
 * right shape is dropped here; whether a value suits the open project is
 * for the controls (`schema.js`) and, in the end, the server to say.
 *
 * @return {{args, subset, save, fit, depth}}  `args`: {parameter: value};
 *   `subset`: {cat: {field: [values]}, num: {field: [lo, hi]}}; `save`:
 *   {setting: number or text}; `fit`: boolean; `depth`: a whole number or null.
 */
export function cleanState(state) {

  const isObject = x => x !== null && typeof x === 'object' && !Array.isArray(x);
  const entries  = x => (isObject(x) ? Object.entries(x) : []);
  const source   = isObject(state) ? state : {};

  const subset = { cat: {}, num: {} };
  const filter = isObject(source.s) ? source.s : {};
  for (const [name, values] of entries(filter.cat))
    if (Array.isArray(values) && values.length && values.every(v => typeof v === 'string')) subset.cat[name] = values;
  for (const [name, range] of entries(filter.num))
    if (Array.isArray(range) && range.length === 2 && range.every(Number.isFinite) && range[0] <= range[1]) subset.num[name] = range;

  const save = {};
  for (const [name, value] of entries(source.v))
    if (typeof value === 'string' || (Number.isFinite(value) && value > 0)) save[name] = value;

  return {
    args:   Object.fromEntries(entries(source.a)),
    subset, save,
    fit:    source.f !== false,
    depth:  Number.isInteger(source.d) && source.d >= 1 ? source.d : null };
}

/** "#/plot/adiv_boxplot/eyJ..." -> {page, arg, state}; state is still text. */
export function parseHash(hash) {
  const [, page = 'home', arg = null, state = null] = (hash || '#/home').split('/');
  let name = arg;
  try { name = arg ? decodeURIComponent(arg) : null; } catch { /* as it is */ }
  return { page: page || 'home', arg: name, state: state || null };
}

/** The address of a page; with `state`, of a figure with its settings. */
export function buildHash(page, arg = null, state = '') {
  return '#/' + [page, arg === null ? null : encodeURIComponent(arg), state || null].filter(part => part !== null).join('/');
}
