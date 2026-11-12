// The metadata and taxonomy tables of the working copy.

import { h, fill, button } from '../dom.js';
import { call } from '../api.js';
import { serverTable } from '../tables.js';
import { uploadComponent, busy } from '../actions.js';
import * as store from '../store.js';

const pages = {
  metadata: {
    title: 'Sample metadata',
    hint:  'One row per sample. A column of numbers can be used as numbers (for trends and correlations) or as categories (for groups): choose under its name.',
    file:  'A table with sample names in the first column (CSV or tab-separated).',
  },
  taxonomy: {
    title: 'Taxonomy',
    hint:  'One row per OTU, with its name at each taxonomic rank.',
    file:  'A table with OTU names in the first column and one column per rank.',
  },
};

export function show(container, what) {

  const page = pages[what];

  // The header's "numeric / categorical" selectors switch a column's class.
  // The server counts columns from 1, with the sample names first.
  const onhead = thead => thead.querySelectorAll('select.numcat').forEach(select => {
    select.setAttribute('aria-label', 'Use this column as');
    select.addEventListener('click', e => e.stopPropagation());
    select.addEventListener('change', async () => {
      const done = await busy('Changing the column...', () => call('/api/metadata/change_class',
        { col_num: Number(select.dataset.colnum) + 1 }));
      if (!done) table.reload();
    });
  });

  const table = serverTable({ pageRoute: `/api/${what}/table`, headRoute: `/api/${what}/thead`, onhead });

  fill(container, h('div.page',
    h('div.page-head',
      h('h1', page.title),
      h('div.card-actions',
        button(`Replace the ${what}`, () => uploadComponent(what), { icon: 'upload', title: page.file }))),
    h('p.hint', page.hint),
    store.get('biom').is_saved ? null : h('p.hint', 'This is your working copy, with its unsaved changes.'),
    h('div.card', table)));

  return {
    // A new field, another class or another project: read the table again.
    onBiom(biom, before) {
      if (!before || biom.node_id !== before.node_id || JSON.stringify(biom.fields) !== JSON.stringify(before.fields) ||
          JSON.stringify(biom.ranks) !== JSON.stringify(before.ranks)) table.reload();
    },
  };
}
