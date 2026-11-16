// The metadata and taxonomy tables of the working copy.

import { h, fill, button } from '../dom.js';
import { call } from '../api.js';
import { serverTable } from '../tables.js';
import { dialog } from '../widgets.js';
import { uploadComponent, busy } from '../actions.js';
import { defaultColors } from '../schema.js';
import * as store from '../store.js';

// A field with more groups than this gets no "Colors" button: a color for
// each of hundreds of groups is not something to pick by hand.
const MAX_COLOR_GROUPS = 100;

const pages = {
  metadata: {
    title: 'Sample metadata',
    hint:  'One row per sample. A column of numbers can be used as numbers (for trends and correlations) or as categories (for groups): choose under its name. Under a column of categories, "Order" sets the order of its values and "Colors" a color for each, which every figure follows.',
    file:  'To replace it, upload a table with the sample names in the first column (CSV or tab-separated text). Samples the table does not list leave the project.',
    template: 'metadata-template.csv',
  },
  taxonomy: {
    title: 'Taxonomy',
    hint:  'One row per OTU, with its name at each taxonomic rank.',
    file:  'To replace it, upload a table with the OTU names in the first column and a column for each rank (or one column of lineages, "Bacteria; Firmicutes; ..."), or a QIIME 2 taxonomy artifact (.qza). OTUs the table does not list leave the project.',
  },
};

export function show(container, what) {

  const page = pages[what];

  // The header's "numeric / categorical" selectors switch a column's class.
  // The server counts columns from 1, with the sample names first.
  const onhead = thead => {
    thead.querySelectorAll('select.numcat').forEach(select => {
      select.setAttribute('aria-label', 'Use this column as');
      select.addEventListener('click', e => e.stopPropagation());
      select.addEventListener('change', async () => {
        const done = await busy('Changing the column...', () => call('/api/metadata/change_class',
          { col_num: Number(select.dataset.colnum) + 1 }));
        if (!done) table.reload();
      });
    });
    if (what === 'metadata') addOrderButtons(thead);
  };

  const table = serverTable({ pageRoute: `/api/${what}/table`, headRoute: `/api/${what}/thead`, onhead });

  const unsaved = h('p.hint', { hidden: store.get('biom').is_saved }, 'This is your working copy, with its unsaved changes.');

  fill(container, h('div.page',
    h('div.page-head',
      h('h1', page.title),
      h('div.card-actions',
        button(`Replace the ${what}`, () => uploadComponent(what), { icon: 'upload' }))),
    h('p.hint', page.hint),
    h('p.hint', page.file, page.template
      ? [' ', h('a', { href: `/www/templates/${page.template}`, download: page.template }, 'A file to start from'), '.'] : null),
    unsaved,
    h('div.card', table)));

  // An "Order" button under each column of categories with more than one
  // value, and a "Colors" button. The project's fields are in the table's
  // column order, sample names first; the name is compared as well, in
  // case the two disagree.
  function addOrderButtons(thead) {
    const names = [...thead.querySelectorAll('tr:first-child th')].map(th => th.textContent.trim());
    const cells = thead.querySelectorAll('tr:nth-child(2) td');
    (store.get('biom').fields || []).forEach((f, i) => {
      const n = (f.levels || []).length;
      if (i === 0 || f.class !== 'categorical' || n < 1 || !cells[i] || names[i] !== f.name.trim()) return;
      if (n >= 2)
        cells[i].append(' ', button('Order', e => { e.stopPropagation(); orderLevels(f); },
          { kind: 'level-order', title: `Put the values of "${f.name}" in order` }));
      if (n <= MAX_COLOR_GROUPS)
        cells[i].append(' ', button('Colors', e => { e.stopPropagation(); groupColors(f); },
          { kind: 'group-colors', title: `Choose a color for each value of "${f.name}"` }));
    });
  }

  return {
    // A new field, another class or another project: read the table again.
    onBiom(biom, before) {
      unsaved.hidden = biom.is_saved;
      if (!before || biom.node_id !== before.node_id || JSON.stringify(biom.fields) !== JSON.stringify(before.fields) ||
          JSON.stringify(biom.ranks) !== JSON.stringify(before.ranks)) table.reload();
    },
  };
}


/**
 * Let the user put a categorical field's values in order, and send the
 * new order. Figures follow it: groups along an axis, in a legend, in facets.
 */
async function orderLevels(f) {

  const order = [...f.levels];
  const list  = h('ol.level-order');

  // A button that cannot move its value further is marked, not disabled:
  // a disabled button would lose the keyboard focus at the end of a run of
  // presses, and the next press would go to another button.
  function draw(focus = null) {
    fill(list, order.map((level, i) => {
      const up   = button('', () => move(i, -1), { icon: 'arrow-up', title: 'Earlier' });
      const down = button('', () => move(i, +1), { icon: 'arrow-down', title: 'Later' });
      up.setAttribute('aria-label', `Move "${level}" earlier`);
      down.setAttribute('aria-label', `Move "${level}" later`);
      if (i === 0) up.setAttribute('aria-disabled', 'true');
      if (i === order.length - 1) down.setAttribute('aria-disabled', 'true');
      return h('li', h('span.level-name', level === '' ? '(empty)' : level), up, down);
    }));
    // Keep the keyboard on the button that moved the value.
    if (focus) list.children[focus[0]]?.querySelectorAll('button')[focus[1] < 0 ? 0 : 1]?.focus();
  }

  function move(i, dir) {
    const j = i + dir;
    if (j < 0 || j >= order.length) return;
    [order[i], order[j]] = [order[j], order[i]];
    draw([j, dir]);
  }

  draw();

  const save = await dialog({
    title: `Order of "${f.name}"`,
    body: [h('p.hint', 'Figures show the groups in this order: along an axis, in a legend and in facets.'), list],
    buttons: [{ label: 'Cancel', value: false }, { label: 'Save', value: true, kind: 'primary' }],
  });

  if (!save || order.every((level, i) => level === f.levels[i])) return;

  await busy('Changing the order...', () => call('/api/metadata/level_order', { field: f.name, levels: order }));
}


/**
 * Let the user pick a color for each group of a categorical field, kept
 * with the project, and send them. Every figure colored by the field uses
 * them, unless its own "Colors" control says otherwise. A group starts at
 * the color it has, or else at the one rbiom gives it by default.
 */
async function groupColors(f) {

  const own    = f.colors || {};
  const dflt   = defaultColors(f.levels.length, store.get('schema'));
  const start  = f.levels.map((level, i) => (own[level] || dflt[i]).slice(0, 7).toLowerCase());
  const picked = [...start];

  const list = h('ul.group-colors', f.levels.map((level, i) => {
    const name  = level === '' ? '(empty)' : level;
    const input = h('input', { type: 'color', value: picked[i], 'aria-label': `Color for "${name}"`,
      oninput: e => { picked[i] = e.target.value; } });
    return h('li', h('label', input, h('span.level-name', name)));
  }));

  const hasOwn = Object.keys(own).length > 0;

  const choice = await dialog({
    title: `Colors of "${f.name}"`,
    body: [
      h('p.hint', 'Every figure colored by this field uses these colors, unless its own "Colors" control is set. ' +
        'Saving keeps the color shown for each group, so that the same group has the same color in every figure.'),
      list ],
    buttons: [
      ...(hasOwn ? [{ label: 'Back to the defaults', value: 'reset' }] : []),
      { label: 'Cancel', value: false },
      { label: 'Save', value: 'save', kind: 'primary' } ],
  });

  if (choice === 'reset')
    return busy('Changing the colors...', () => call('/api/metadata/colors', { field: f.name, reset: true }));

  // A group with no name cannot be given a color.
  const colors = Object.fromEntries(f.levels.map((level, i) => [level, picked[i]]).filter(([level]) => level !== ''));
  const same   = f.levels.every((level, i) => level === '' || (own[level] || '').slice(0, 7).toLowerCase() === picked[i]);
  if (choice !== 'save' || !Object.keys(colors).length || same) return;

  await busy('Changing the colors...', () => call('/api/metadata/colors', { field: f.name, colors }));
}
