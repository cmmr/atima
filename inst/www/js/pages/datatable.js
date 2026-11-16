// The metadata and taxonomy tables of the working copy.

import { h, fill, button } from '../dom.js';
import { call } from '../api.js';
import { serverTable } from '../tables.js';
import { dialog } from '../widgets.js';
import { uploadComponent, busy } from '../actions.js';
import * as store from '../store.js';

const pages = {
  metadata: {
    title: 'Sample metadata',
    hint:  'One row per sample. A column of numbers can be used as numbers (for trends and correlations) or as categories (for groups): choose under its name. "Order" under a column of categories sets the order of its values, which every figure follows.',
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
  // value. The project's fields are in the table's column order, sample
  // names first; the name is compared as well, in case the two disagree.
  function addOrderButtons(thead) {
    const names = [...thead.querySelectorAll('tr:first-child th')].map(th => th.textContent.trim());
    const cells = thead.querySelectorAll('tr:nth-child(2) td');
    (store.get('biom').fields || []).forEach((f, i) => {
      if (i === 0 || f.class !== 'categorical' || (f.levels || []).length < 2 || !cells[i] || names[i] !== f.name.trim()) return;
      cells[i].append(' ', button('Order', e => { e.stopPropagation(); orderLevels(f); },
        { kind: 'level-order', title: `Put the values of "${f.name}" in order` }));
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
