// Small interface parts used by every page: dialogs, notices, a searchable
// picker, tabs. All text is inserted as text.

import { h, fill, icon, button, newId } from './dom.js';

//_____________________________________________________________________________
// Dialogs, on the browser's own <dialog> element.

/**
 * Show a dialog and wait for it to close.
 * @param {object} opts  `title`; `body` (nodes or text); `buttons`: a list of
 *                       `{label, value, kind, validate}`. A button's `value`
 *                       may be a function, called for the result; if
 *                       `validate` returns a string, it is shown and the
 *                       dialog stays open.
 * @return {Promise<*>}  The pressed button's value; `null` if dismissed.
 */
export function dialog({ title, body, buttons = [{ label: 'Close', value: null }], wide = false }) {
  return new Promise(resolve => {

    const problem = h('p.dialog-problem', { hidden: true, role: 'alert' });
    let result = null;

    const footer = h('div.dialog-buttons', buttons.map(b => button(b.label, async () => {
      const complaint = b.validate ? await b.validate() : null;
      if (typeof complaint === 'string') { problem.textContent = complaint; problem.hidden = false; return; }
      result = typeof b.value === 'function' ? b.value() : b.value;
      el.close();
    }, { kind: b.kind || '' })));

    const el = h('dialog', { class: wide ? 'wide' : '' },
      h('h2', title), h('div.dialog-body', body), problem, footer);

    el.addEventListener('close', () => { el.remove(); resolve(result); });
    document.body.append(el);
    el.showModal();
  });
}

/** Ask a yes/no question. Resolves to true or false. */
export function confirm(title, message, { ok = 'OK', danger = false } = {}) {
  return dialog({
    title,
    body: [].concat(message).map(line => h('p', line)),
    buttons: [
      { label: 'Cancel', value: false },
      { label: ok, value: true, kind: danger ? 'danger' : 'primary' } ],
  }).then(Boolean);
}

/** Ask for one line of text. Resolves to the text, or null. */
export function prompt(title, { label = '', value = '', ok = 'OK', check = null, hint = null } = {}) {
  const id    = newId('prompt');
  const input = h('input', { id, type: 'text', value, autocomplete: 'off' });
  const done  = dialog({
    title,
    body: [h('label', { for: id }, label), input, hint ? h('p.hint', hint) : null],
    buttons: [
      { label: 'Cancel', value: null },
      { label: ok, kind: 'primary', value: () => input.value.trim(),
        validate: () => (check ? check(input.value.trim()) : null) } ],
  });
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); input.closest('dialog').querySelector('.btn.primary').click(); }
  });
  input.select();
  return done;
}

//_____________________________________________________________________________
// Notices at the bottom of the window.

function notices() {
  let box = document.getElementById('notices');
  if (!box) { box = h('div', { id: 'notices', role: 'status', 'aria-live': 'polite' }); document.body.append(box); }
  return box;
}

/** Show a short message. `kind` is "info", "ok" or "error". */
export function notify(message, kind = 'info', { detail = null, ms = kind === 'error' ? 12000 : 5000 } = {}) {
  const el = h('div', { class: `notice ${kind}` },
    icon(kind === 'error' ? 'triangle-exclamation' : kind === 'ok' ? 'circle-check' : 'circle-info'),
    h('div', h('div', message), detail ? h('div.notice-detail', detail) : null),
    h('button.notice-close', { type: 'button', title: 'Dismiss', onclick: () => el.remove() }, icon('xmark')));
  notices().append(el);
  if (ms) setTimeout(() => el.remove(), ms);
  return el;
}

/**
 * Show a failed request, unless it was only replaced or stopped. The
 * server's message is text; its id lets an administrator find the log line.
 */
export function showError(err) {
  if (err && err.superseded) return;
  console.error(err);
  const message = err && err.message ? err.message : 'Something went wrong.';
  notify(message, 'error', { detail: err && err.id ? `Error id: ${err.id}` : null });
}

//_____________________________________________________________________________
// A picker: a searchable drop-down for one value or several.

/**
 * @param {object} opts
 *   options      [{value, label, group?, note?, swatch?: [colors], image?: url}]
 *   value        the selected value, or an array of them when `multiple`
 *   multiple     choose several; the face says how many, and each shows as
 *                a removable chip, in order, in `.chips` (below the face,
 *                unless the caller puts that element somewhere else)
 *   iconOnly     the face shows only the chosen option's picture or swatch
 *   placeholder  shown when nothing is selected
 *   label        what is being chosen, for screen readers, when no <label> is tied to `id`
 *   onchange     called with the new value (array when `multiple`)
 * @return {HTMLElement} with `.setOptions(options, value)`, `.value` and, when `multiple`, `.chips`.
 */
export function picker({ options = [], value = null, multiple = false, iconOnly = false, placeholder = 'Choose...', label = null, onchange = () => {}, id = null }) {

  const same  = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const find  = v => options.find(o => same(o.value, v));
  let selected = multiple ? [...(value || [])] : value;
  let open = false, cursor = 0, shown = [];

  const face   = h('button.picker-face', { type: 'button', id, 'aria-haspopup': 'listbox', 'aria-label': label });
  const chips  = multiple ? h('div.chips', { hidden: true }) : null;
  const search = h('input.picker-search', { type: 'search', placeholder: 'Search...', autocomplete: 'off', 'aria-label': 'Search' });
  const list   = h('ul.picker-list', { role: 'listbox' });
  const popup  = h('div.picker-popup', { hidden: true }, search, list);
  const root   = h('div.picker', { class: [multiple ? 'multiple' : '', iconOnly ? 'icon-only' : ''].join(' ').trim() }, face, popup, chips);

  const optionFace = o => [
    o.swatch ? h('span.swatch', o.swatch.map(c => h('i', { style: { background: c } }))) : null,
    o.image  ? h('img.picker-image', { src: o.image, alt: '' }) : null,
    h('span.picker-label', o.label),
    o.note ? h('span.picker-note', o.note) : null ];

  function drawFace() {
    if (multiple) {
      fill(face, selected.length
        ? h('span.picker-label', `${selected.length} chosen`)
        : h('span.picker-placeholder', placeholder), icon('caret-down', 'picker-caret'));
      face.title = selected.map(v => (find(v) || { label: String(v) }).label).join(', ');
      chips.hidden = selected.length === 0;
      fill(chips, selected.map(v => {
        const o = find(v) || { value: v, label: String(v) };
        return h('span.chip', { title: o.label }, optionFace(o), h('button.chip-x', {
          type: 'button', title: `Remove ${o.label}`, onclick: () => choose(v) }, icon('xmark')));
      }));
    } else {
      const o = selected === null || selected === undefined ? null : find(selected);
      const shown = o && iconOnly ? optionFace(o).slice(0, 2) : o ? optionFace(o) : h('span.picker-placeholder', placeholder);
      fill(face, shown, icon('caret-down', 'picker-caret'));
      // A long value is cut short on the face; this shows it whole.
      face.title = o ? o.label : '';
    }
  }

  function drawList() {
    const q = search.value.trim().toLowerCase();
    const hits = options.filter(o => !q || o.label.toLowerCase().includes(q) || String(o.value).toLowerCase().includes(q));
    shown  = hits.slice(0, 200);
    cursor = Math.min(cursor, Math.max(shown.length - 1, 0));
    let group = null;
    const rows = [];
    shown.forEach((o, i) => {
      if (o.group && o.group !== group) rows.push(h('li.picker-group', o.group));
      group = o.group || null;
      const on = multiple ? selected.some(v => same(v, o.value)) : same(selected, o.value);
      rows.push(h('li', {
        role: 'option', 'aria-selected': String(on), class: (on ? 'on ' : '') + (i === cursor ? 'cursor' : ''),
        onmousedown: e => { e.preventDefault(); choose(o.value); },
      }, multiple ? icon(on ? 'square-check' : 'square', 'picker-check') : null, optionFace(o)));
    });
    if (!shown.length) rows.push(h('li.picker-none', 'Nothing matches.'));
    if (hits.length > shown.length) rows.push(h('li.picker-none', `${hits.length - shown.length} more: type to narrow.`));
    fill(list, rows);
    const at = list.querySelector('.cursor');
    if (at) at.scrollIntoView({ block: 'nearest' });
  }

  function choose(v) {
    if (multiple) {
      selected = selected.some(x => same(x, v)) ? selected.filter(x => !same(x, v)) : [...selected, v];
      drawFace(); drawList();
      onchange([...selected]);
    } else {
      selected = v;
      drawFace(); close();
      onchange(v);
    }
  }

  function show() {
    if (open) return;
    open = true; cursor = 0;
    popup.hidden = false;
    search.value = '';
    search.hidden = options.length < 8;
    drawList();
    // Open upwards when there is no room below.
    const box = root.getBoundingClientRect();
    popup.classList.toggle('up', window.innerHeight - box.bottom < 260 && box.top > 260);
    // And leftwards when it would pass the window's right edge.
    popup.classList.remove('left');
    popup.classList.toggle('left', popup.getBoundingClientRect().right > document.documentElement.clientWidth - 4);
    (search.hidden ? face : search).focus();
    document.addEventListener('mousedown', outside, true);
  }

  function close() {
    if (!open) return;
    open = false;
    popup.hidden = true;
    document.removeEventListener('mousedown', outside, true);
  }

  function outside(e) { if (!root.contains(e.target)) close(); }

  function keys(e) {
    if (e.key === 'Escape') { if (open) { e.stopPropagation(); close(); face.focus(); } return; }
    if (!open) { if (['ArrowDown', 'Enter', ' '].includes(e.key)) { e.preventDefault(); show(); } return; }
    if (e.key === 'ArrowDown')    { e.preventDefault(); cursor = Math.min(cursor + 1, shown.length - 1); drawList(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); cursor = Math.max(cursor - 1, 0); drawList(); }
    else if (e.key === 'Enter')   { e.preventDefault(); if (shown[cursor]) choose(shown[cursor].value); }
    else if (e.key === 'Tab')     { close(); }
  }

  face.addEventListener('click', () => (open ? close() : show()));
  root.addEventListener('keydown', keys);
  search.addEventListener('input', () => { cursor = 0; drawList(); });

  root.setOptions = (next, nextValue) => {
    options  = next;
    selected = multiple ? [...(nextValue || [])] : nextValue;
    drawFace();
    if (open) drawList();
  };
  Object.defineProperty(root, 'value', { get: () => (multiple ? [...selected] : selected) });
  root.chips = chips;

  drawFace();
  return root;
}

//_____________________________________________________________________________
// Tabs.

/**
 * @param {Array} tabs  [{id, label, icon, panel: HTMLElement}]
 * @param {function} onshow  Called with a tab's id when it is shown.
 * @return {HTMLElement} with `.show(id)` and `.current`.
 */
export function tabs(items, onshow = () => {}) {
  const bar  = h('div.tabs', { role: 'tablist' });
  const root = h('div.tabbed', bar, items.map(t => t.panel));
  let current = null;

  root.show = id => {
    current = id;
    for (const t of items) {
      t.button.setAttribute('aria-selected', String(t.id === id));
      t.panel.hidden = t.id !== id;
    }
    onshow(id);
  };

  for (const t of items) {
    t.panel.setAttribute('role', 'tabpanel');
    t.button = h('button', { type: 'button', role: 'tab', onclick: () => root.show(t.id) },
      t.icon ? icon(t.icon) : null, h('span', t.label));
    bar.append(t.button);
  }

  Object.defineProperty(root, 'current', { get: () => current });
  root.bar = bar;
  root.show(items[0].id);
  return root;
}

/** A section that opens and closes. `badge` is a node shown beside the title. */
export function section(title, content, { open = false, badge = null } = {}) {
  return h('details.section', { open },
    h('summary', icon('chevron-right', 'section-arrow'), h('span.section-title', title), badge),
    h('div.section-body', content));
}

/** A spinner with a message. */
export function spinner(message = 'Working...') {
  return h('div.spinner', h('i.spin'), h('span', message));
}
