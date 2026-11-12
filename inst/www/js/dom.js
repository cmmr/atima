// Building the page. Everything here inserts strings as text nodes, so text
// that came from a user's file, a project title or a provider's name can
// never become markup. The one exception is serverHtml(), for the few
// values the server sends as HTML it has already escaped or sanitized.

/**
 * Create an element.
 * @param {string} tag       Tag name, optionally with classes: "div.row.tight".
 * @param {object} [attrs]   Attributes. `on<event>` adds a listener, `dataset`
 *                           and `style` take objects, `class` a string;
 *                           null, undefined and false values are skipped.
 * @param {...(Node|string|number|Array|null)} children  Strings become text.
 */
export function h(tag, attrs, ...children) {

  const [name, ...classes] = tag.split('.');
  const el = document.createElement(name || 'div');
  if (classes.length) el.className = classes.join(' ');

  if (attrs instanceof Node || typeof attrs === 'string' || typeof attrs === 'number' || Array.isArray(attrs)) {
    children.unshift(attrs);
    attrs = null;
  }

  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
    else if (key === 'class')   el.className = (el.className + ' ' + value).trim();
    else if (key === 'dataset') Object.assign(el.dataset, value);
    else if (key === 'style')   Object.assign(el.style, value);
    else if (key in el && key !== 'list' && key !== 'form') el[key] = value;
    else el.setAttribute(key, value === true ? '' : value);
  }

  append(el, children);
  return el;
}

/** Append children; strings and numbers become text nodes. */
export function append(el, ...children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

/** Replace an element's children. */
export function fill(el, ...children) {
  el.replaceChildren();
  return append(el, ...children);
}

/** A Font Awesome icon, e.g. icon('upload'). */
export function icon(name, extra = '') {
  return h('i', { class: `fa-solid fa-${name} ${extra}`.trim(), 'aria-hidden': 'true' });
}

/** A button with an optional icon. */
export function button(label, onclick, { icon: ico, kind = '', title, disabled } = {}) {
  return h('button', { type: 'button', class: `btn ${kind}`.trim(), onclick, title, disabled },
    ico ? icon(ico) : null, label ? h('span', label) : null);
}

/**
 * Insert HTML that the server has already escaped or sanitized: project
 * descriptions, and the cells and header rows of the metadata and taxonomy
 * tables. It is passed through DOMPurify all the same.
 */
export function serverHtml(el, html, { table = false } = {}) {
  // Header rows only parse as rows inside a table.
  const clean = table
    ? window.DOMPurify.sanitize(`<table>${String(html ?? '')}</table>`, {
        ALLOWED_TAGS: ['table', 'thead', 'tr', 'th', 'td', 'select', 'option'], ALLOWED_ATTR: ['class', 'data-colnum', 'selected'] })
    : window.DOMPurify.sanitize(String(html ?? ''), { FORBID_TAGS: ['style', 'form', 'input', 'button', 'img'], FORBID_ATTR: ['style'] });
  el.innerHTML = clean;
  for (const a of el.querySelectorAll('a[href]')) { a.target = '_blank'; a.rel = 'noopener noreferrer nofollow'; }
  return el;
}

/** Call `fn` once, `ms` after the last call. */
export function debounce(fn, ms) {
  let timer = null;
  const wrapped = (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); };
  wrapped.cancel = () => clearTimeout(timer);
  return wrapped;
}

/** Have the browser save a URL as a file. */
export function download(url, filename = '') {
  const a = h('a', { href: url, download: filename, style: { display: 'none' } });
  document.body.append(a);
  a.click();
  a.remove();
}

/** Save text as a file. */
export function downloadText(text, filename, type = 'text/csv') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  download(url, filename);
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

let uid = 0;
/** A unique id, for tying labels to inputs. */
export function newId(prefix = 'id') { return `${prefix}-${++uid}`; }
