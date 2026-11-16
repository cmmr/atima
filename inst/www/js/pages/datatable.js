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

  return {
    // A new field, another class or another project: read the table again.
    onBiom(biom, before) {
      unsaved.hidden = biom.is_saved;
      if (!before || biom.node_id !== before.node_id || JSON.stringify(biom.fields) !== JSON.stringify(before.fields) ||
          JSON.stringify(biom.ranks) !== JSON.stringify(before.ranks)) table.reload();
    },
  };
}
