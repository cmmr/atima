// The table page: a table that an rbiom function makes (the most abundant
// taxa, the taxa that groups share) and its R code in the middle, and on
// the right the function's controls from the schema and the sample filter,
// as on the plot page.

import { h, fill, icon, button, debounce } from '../dom.js';
import { call, abortJobs } from '../api.js';
import { tabs, section, spinner } from '../widgets.js';
import { controlPanel } from '../controls.js';
import { localTable } from '../tables.js';
import { subsetEditor, codeBlock } from './plot.js';
import * as S from '../schema.js';
import * as store from '../store.js';

// What the columns of rbiom's tables mean.
const COLUMN_TOOLTIPS = {
  rank:       'Taxonomic rank.',
  top:        "The taxon's position in its group: 1 is the most abundant.",
  taxa:       'The taxon.',
  mean:       "Mean abundance over the group's samples.",
  prevalence: "Share of the group's samples in which the taxon was observed.",
  abundance:  'Abundance in the sample.',
  n_groups:   'How many groups the taxon belongs to.',
  set:        'The combination of groups the taxon belongs to.',
};

/** Tooltips for the columns of a table, with those rbiom names after a group. */
function tooltips(rows) {
  const out = { ...COLUMN_TOOLTIPS };
  for (const column of rows.length ? Object.keys(rows[0]) : [])
    if (column.startsWith('prev_')) out[column] = "Share of this group's samples in which the taxon is present.";
  return out;
}

export function show(container, fn) {

  const schema = store.get('schema');
  const def    = schema.functions[fn];

  if (!def || def.use !== 'table') {
    fill(container, h('p.empty', 'There is no such table.'));
    return {};
  }

  let seq = 0;              // the newest request's number
  let controller = null;    // to stop the request in flight

  //___________________________________________________________________________
  // Middle: table, code

  const working   = spinner(`Making the table: ${def.label}`);
  const message   = h('div.problems', { hidden: true, role: 'alert' });
  const tableBody = h('div'), codeBody = h('div');
  working.hidden  = true;

  const panes = tabs([
    { id: 'table', label: 'Table',  icon: 'table', panel: h('div.pane', working, message, tableBody) },
    { id: 'code',  label: 'R code', icon: 'code',  panel: h('div.pane', codeBody) },
  ]);

  //___________________________________________________________________________
  // Right: controls

  const problems = h('div.problems', { hidden: true, role: 'alert' });
  const args     = () => store.fnArgs(def);

  const filter      = subsetEditor(() => { badge.textContent = filter.count() || ''; changed(); });
  const badge       = h('span.badge', filter.count() || '');
  const basicBox    = h('div');
  const advancedBox = h('div');

  function buildControls() {
    const panel = controlPanel(def, {
      biom: store.get('biom'), schema, args,
      set: (name, value) => { store.setArg(def, name, value); changed(); } });
    fill(basicBox, panel.groups.basic);
    fill(advancedBox, panel.groups.advanced);
  }

  const aside = h('aside.plot-controls',
    h('div.plot-controls-head',
      h('h2', { title: def.label }, def.label),
      button('', () => { store.resetArgs(def); buildControls(); changed(); }, { icon: 'rotate-left',
        title: 'Put every control of this table back to its default. Plots that share a setting follow.' })),
    problems, basicBox,
    section('Advanced', advancedBox),
    section('Samples', filter, { badge }));

  fill(container, h('div.plot-page', h('section.plot-main', panes), aside));

  //___________________________________________________________________________
  // Requests

  /** Are the required settings all there? Says which are not, beside the controls. */
  function complete() {
    const stopReasons = S.problems(def, args());
    problems.hidden = stopReasons.length === 0;
    fill(problems, stopReasons.map(text => h('p', text)));
    return stopReasons.length === 0;
  }

  function showMessage(text, { retry = false, id = null } = {}) {
    message.hidden = !text;
    fill(message, text ? [h('p', text), id ? h('p.hint', `Error id: ${id}`) : null,
      retry ? button('Try again', () => run(), { icon: 'rotate-right' }) : null] : null);
  }

  async function run() {

    schedule.cancel();
    if (!complete()) { showMessage('Complete the settings on the right to make this table.'); return; }

    if (controller) controller.abort();
    controller = new AbortController();
    const mine = ++seq;

    const body   = { table_fn: fn, table_args: S.payload(def, args()), depth: store.get('biom').depth };
    const subset = S.subsetPayload(store.get('subset'));
    if (subset) body.subset_args = subset;

    showMessage(null);
    working.hidden = false;

    try {
      const resp = await call('/api/table', body, { signal: controller.signal });
      if (mine !== seq) return;
      showTable(resp);
    }
    catch (err) {
      if (mine !== seq) return;       // replaced by a newer request: nothing to say
      if (err.status === 409 || err.status === 0) { /* replaced or cancelled */ }
      else if (err.status === 503) showMessage('The server is busy. Try again in a moment.', { retry: true });
      else if (err.status === 504) showMessage(err.message, { retry: true });
      else if (err.status === 400) showMessage(err.message);
      else { showMessage(err.message, { retry: true, id: err.id }); console.error(err); }
    }
    finally {
      if (mine === seq) { working.hidden = true; controller = null; }
    }
  }

  const schedule = debounce(run, 400);

  /** A setting changed: make the table again. */
  function changed() { schedule(); }

  function showTable(resp) {

    const rows = resp.table || [];
    const biom = store.get('biom');
    const n    = filter.count();
    const made = (def.sample_set === 'rare'
      ? `Made from counts rarefied to ${biom.depth.toLocaleString()} reads per sample.`
      : 'Made from the counts before rarefying.') + (n ? ` ${n} sample filter${n > 1 ? 's' : ''} applied.` : '');

    fill(tableBody,
      h('p.hint', made),
      (resp.warnings || []).map(text => h('p.stale-note', icon('triangle-exclamation'), text)),
      rows.length === 0 ? h('p.empty', 'The table has no rows.')
        : localTable(rows, { tooltips: tooltips(rows), filename: `${fn}.csv`, url: resp.file_url }),
      resp.rows_total > rows.length
        ? h('p.hint', `Showing the first ${rows.length.toLocaleString()} of ${resp.rows_total.toLocaleString()} rows. The CSV file has them all.`)
        : null);

    fill(codeBody, codeBlock([
      '# Make this table with rbiom.',
      'library(rbiom)',
      `biom <- as_rbiom("${window.location.origin}/${resp.code.file}")`,
      `data <- ${resp.code.cmd}`,
    ].join('\n')));
  }

  buildControls();
  changed();

  return {
    // The project changed under the page: another depth, a new field, or
    // another project altogether.
    onBiom(biom, before) {
      buildControls();
      filter.redraw();
      badge.textContent = filter.count() || '';
      const sameData = before && biom.depth === before.depth && biom.node_id === before.node_id &&
        JSON.stringify(biom.fields) === JSON.stringify(before.fields);
      if (!sameData) changed();
    },
    destroy() {
      seq++;
      schedule.cancel();
      if (controller) { controller.abort(); abortJobs(); }
    },
  };
}
