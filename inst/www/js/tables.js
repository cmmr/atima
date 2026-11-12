// Two tables: one whose pages the server sorts, searches and sends
// (metadata, taxonomy), and one that holds all its rows in the page (the
// statistics beside a figure).

import { h, fill, icon, button, serverHtml, debounce, downloadText } from './dom.js';
import { call } from './api.js';
import { showError, spinner } from './widgets.js';

/**
 * A table paged by the server.
 *
 * The header row comes from `headRoute` and the cells from `pageRoute`.
 * Both are HTML the server has already escaped (the names and values come
 * from the user's file), so they are inserted as HTML, through DOMPurify.
 *
 * @param {object} opts
 *   pageRoute, headRoute  API paths.
 *   onhead(thead)         Called after the header is inserted, to wire controls in it.
 * @return {HTMLElement} with `.reload()` (header and rows again).
 */
export function serverTable({ pageRoute, headRoute, onhead = () => {} }) {

  const state = { start: 0, length: 25, search: '', column: 0, dir: 'asc', draw: 0, total: 0, filtered: 0 };

  const table  = h('table.data');
  const tbody  = h('tbody');
  const status = h('span.table-status');
  const prev   = button('Previous', () => { state.start = Math.max(0, state.start - state.length); page(); }, { icon: 'chevron-left' });
  const next   = button('Next', () => { state.start += state.length; page(); }, { icon: 'chevron-right' });
  const search = h('input', { type: 'search', placeholder: 'Search', 'aria-label': 'Search the table',
    oninput: debounce(() => { state.search = search.value; state.start = 0; page(); }, 300) });
  const size   = h('select', { 'aria-label': 'Rows per page', onchange: () => { state.length = Number(size.value); state.start = 0; page(); } },
    [10, 25, 50, 100].map(n => h('option', { value: n, selected: n === state.length }, `${n} rows`)));
  const holder = h('div.table-scroll', spinner('Loading...'));
  const root   = h('div.table-wrap', h('div.table-tools', search, size), holder, h('div.table-foot', status, prev, next));

  async function head() {
    const data  = await call(headRoute);
    const thead = serverHtml(h('div'), data.html, { table: true }).querySelector('thead') || h('thead');
    thead.querySelectorAll('tr:first-child th').forEach((th, i) => {
      th.tabIndex = 0;
      th.classList.add('sortable');
      const sort = () => {
        state.dir    = state.column === i && state.dir === 'asc' ? 'desc' : 'asc';
        state.column = i;
        state.start  = 0;
        page();
      };
      th.addEventListener('click', sort);
      th.addEventListener('keydown', e => { if (e.key === 'Enter') sort(); });
    });
    fill(table, thead, tbody);
    fill(holder, table);
    onhead(thead);
  }

  async function page() {
    const draw = ++state.draw;
    try {
      const data = await call(pageRoute, {
        draw, start: state.start, length: state.length,
        search: { value: state.search, regex: false },
        order: [{ column: state.column, dir: state.dir }] });
      if (draw !== state.draw) return;        // a newer page is on its way

      state.total = data.recordsTotal; state.filtered = data.recordsFiltered;

      fill(tbody, data.data.map(row => h('tr', row.map(cell => {
        const td = h('td');
        td.innerHTML = window.DOMPurify.sanitize(String(cell ?? ''), { ALLOWED_TAGS: [] });
        return td;
      }))));

      table.querySelectorAll('thead tr:first-child th').forEach((th, i) =>
        th.setAttribute('aria-sort', i === state.column ? (state.dir === 'asc' ? 'ascending' : 'descending') : 'none'));

      const last = Math.min(state.start + state.length, state.filtered);
      status.textContent = state.filtered === 0 ? 'No rows.'
        : `Rows ${state.start + 1} to ${last} of ${state.filtered}` +
          (state.filtered < state.total ? ` (of ${state.total} in all)` : '');
      prev.disabled = state.start === 0;
      next.disabled = last >= state.filtered;
    } catch (err) { showError(err); }
  }

  root.reload = async () => {
    try { await head(); await page(); } catch (err) { showError(err); fill(holder, h('p.empty', 'The table could not be loaded.')); }
  };

  root.reload();
  return root;
}


/** A number as it is shown in a table: short, with the full value on hover. */
function cellText(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number' && !Number.isInteger(value)) {
    const abs = Math.abs(value);
    return abs !== 0 && (abs < 0.001 || abs >= 1e6) ? value.toExponential(2) : String(Number(value.toPrecision(4)));
  }
  return String(value);
}

const csvCell = value => {
  const s = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/**
 * A table of rows already in the page, with sorting, a filter, paging and
 * a CSV download. Every cell is inserted as text.
 *
 * @param {Array<object>} rows   One object per row.
 * @param {object} opts          `tooltips`: {column: text}; `filename` for the CSV.
 */
export function localTable(rows, { tooltips = {}, filename = 'table.csv' } = {}) {

  const columns = rows.length ? Object.keys(rows[0]) : [];
  const state   = { sort: null, dir: 1, filter: '', start: 0, length: 25 };

  const tbody  = h('tbody');
  const status = h('span.table-status');
  const prev   = button('Previous', () => { state.start = Math.max(0, state.start - state.length); draw(); }, { icon: 'chevron-left' });
  const next   = button('Next', () => { state.start += state.length; draw(); }, { icon: 'chevron-right' });

  const heads = columns.map(col => h('th.sortable', {
    tabindex: 0, title: tooltips[col] || '',
    onclick: () => { state.dir = state.sort === col ? -state.dir : 1; state.sort = col; state.start = 0; draw(); },
    onkeydown: e => { if (e.key === 'Enter') e.target.click(); } }, col));

  function visible() {
    const q = state.filter.trim().toLowerCase();
    let out = q ? rows.filter(r => columns.some(c => String(r[c] ?? '').toLowerCase().includes(q))) : [...rows];
    if (state.sort) {
      const c = state.sort;
      out.sort((a, b) => {
        const x = a[c], y = b[c];
        if (x === y) return 0;
        if (x === null || x === undefined) return 1;
        if (y === null || y === undefined) return -1;
        return (typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y))) * state.dir;
      });
    }
    return out;
  }

  function draw() {
    const all  = visible();
    const page = all.slice(state.start, state.start + state.length);
    fill(tbody, page.map(r => h('tr', columns.map(c =>
      h('td', { title: typeof r[c] === 'number' ? String(r[c]) : null, class: typeof r[c] === 'number' ? 'num' : '' }, cellText(r[c]))))));
    heads.forEach((th, i) => th.setAttribute('aria-sort',
      columns[i] === state.sort ? (state.dir === 1 ? 'ascending' : 'descending') : 'none'));
    const last = Math.min(state.start + state.length, all.length);
    status.textContent = all.length === 0 ? 'No rows.' : `Rows ${state.start + 1} to ${last} of ${all.length}`;
    prev.disabled = state.start === 0;
    next.disabled = last >= all.length;
  }

  const filter = h('input', { type: 'search', placeholder: 'Search', 'aria-label': 'Search the table',
    oninput: () => { state.filter = filter.value; state.start = 0; draw(); } });

  const csv = button('CSV', () => downloadText(
    [columns.map(csvCell).join(',')].concat(visible().map(r => columns.map(c => csvCell(r[c])).join(','))).join('\n'),
    filename), { icon: 'download', title: 'Download these rows as a CSV file' });

  draw();

  return h('div.table-wrap',
    h('div.table-tools', filter, csv),
    h('div.table-scroll', h('table.data', h('thead', h('tr', heads)), tbody)),
    h('div.table-foot', status, prev, next));
}
