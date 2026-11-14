// The open project at a glance: what it holds, saving, links, publishing,
// and downloads of its data.

import { h, fill, icon, button, serverHtml, download } from '../dom.js';
import { call } from '../api.js';
import { picker } from '../widgets.js';
import { saveProject, publishProject, newShareLink, uploadComponent, copyText, projectUrl, busy, go } from '../actions.js';
import * as S from '../schema.js';
import * as store from '../store.js';

export function show(container) {

  async function exportFile(body) {
    const done = await busy('Preparing the file...', () => call('/api/project/export', body));
    if (done) download(done.download_url);
  }

  function draw() {

    const biom   = store.get('biom');
    const schema = store.get('schema');
    const conf   = store.get('conf');
    const fields = (biom.fields || []).filter(f => f.name !== '.sample');
    const nSamples = ((S.field(biom, '.sample') || {}).levels || []).length;
    const ranks  = (biom.ranks || []).filter(r => r !== '.otu');

    //_________________________________________________________________________
    // Saving and sharing

    const actions = h('div.card-actions',
      biom.is_editor ? button('Save', () => saveProject(), { icon: 'floppy-disk', kind: biom.is_saved ? '' : 'primary' }) : null,
      button('Save a copy', () => saveProject({ copy: true }), { icon: 'copy', kind: !biom.is_editor && !biom.is_saved ? 'primary' : '' }),
      biom.is_editor && !conf.is_guest
        ? button(biom.is_public ? 'Public settings' : 'Publish', publishProject, { icon: 'earth-americas' }) : null);

    const links = [];
    if (biom.is_public)
      links.push(linkRow('Public address', projectUrl(biom.public_key), 'Anyone can open this project here.'));
    if (biom.access_key)
      links.push(linkRow('Share link', projectUrl(biom.access_key),
        'Anyone who has this link can open and download the saved project.',
        biom.is_editor ? button('New link', newShareLink, { icon: 'rotate', title: 'Replace the link; older links stop working' }) : null));

    //_________________________________________________________________________
    // Downloads

    const betaChoices = S.metricChoices(
      S.param(schema.functions.bdiv_boxplot || { params: [] }, 'bdiv') || { choices: [] }, biom)
      .map(c => ({ value: c.id, label: c.name }));
    let metric = 'bray', rank = ranks[ranks.length - 1] || '.otu', format = 'json';

    const pair = (label, body) => h('span.button-pair',
      button(`${label}`, () => exportFile({ ...body(), sample_set: 'rare' }), { icon: 'download', title: 'At the rarefaction depth' }),
      button('unrarefied', () => exportFile({ ...body(), sample_set: 'full' }), { title: 'Before rarefying' }));

    const downloads = h('div.downloads',
      h('p.hint', 'Downloads are made from the saved project', biom.is_saved ? '.' : ', not from the unsaved changes in your working copy.'),
      h('div.download-row', h('span.download-name', 'Everything, as an Excel workbook'),
        button('Excel', () => exportFile({ what: 'xlsx' }), { icon: 'file-excel' })),
      h('div.download-row', h('span.download-name', 'The file as it was uploaded'),
        button('Original', () => exportFile({ what: 'original' }), { icon: 'download' })),
      h('div.download-row', h('span.download-name', 'BIOM file'),
        h('select', { 'aria-label': 'BIOM format', onchange: e => { format = e.target.value; } },
          h('option', { value: 'json' }, 'JSON (BIOM 1.0)'), h('option', { value: 'hdf5' }, 'HDF5 (BIOM 2.1)'), h('option', { value: 'tab' }, 'Tab-separated')),
        pair('Rarefied', () => ({ what: 'biom', format }))),
      h('div.download-row', h('span.download-name', 'Sample metadata'),
        button('CSV', () => exportFile({ what: 'metadata' }), { icon: 'download' })),
      h('div.download-row', h('span.download-name', 'Taxonomy'),
        button('CSV', () => exportFile({ what: 'taxonomy' }), { icon: 'download' })),
      biom.tree ? h('div.download-row', h('span.download-name', 'Phylogenetic tree'),
        button('Newick', () => exportFile({ what: 'tree' }), { icon: 'download' })) : null,
      h('div.download-row', h('span.download-name', 'Alpha diversity of every sample'),
        pair('Rarefied', () => ({ what: 'alpha' }))),
      h('div.download-row', h('span.download-name', 'Distances between samples'),
        picker({ options: betaChoices, value: metric, onchange: v => { metric = v; } }),
        button('CSV', () => exportFile({ what: 'beta', method: metric }), { icon: 'download' })),
      h('div.download-row', h('span.download-name', 'Taxa abundances'),
        h('select', { 'aria-label': 'Rank', onchange: e => { rank = e.target.value; } },
          (biom.ranks || []).map(r => h('option', { value: r, selected: r === rank }, S.rankLabel(r)))),
        pair('Rarefied', () => ({ what: 'taxa', rank: rank === '.otu' ? 'otu' : rank }))));

    //_________________________________________________________________________

    // The project in numbers. Names and values come from the user's file: text.
    const nOtus = (((biom.taxa || {})['.otu']) || []).length;
    const tile  = (value, label, title = null) => h('div.tile', { title }, h('strong', value), h('span', label));
    const tiles = h('div.tiles',
      tile(nSamples.toLocaleString(), 'samples', 'Samples with at least as many reads as the rarefaction depth'),
      tile(nOtus.toLocaleString(), 'OTUs', 'OTUs left after rarefying'),
      tile(Number(biom.depth).toLocaleString(), 'reads per sample', 'The rarefaction depth. Change it above any figure.'),
      tile(String(fields.length), fields.length === 1 ? 'metadata field' : 'metadata fields'),
      tile(String(ranks.length), ranks.length === 1 ? 'taxonomic rank' : 'taxonomic ranks'),
      tile(biom.tree ? 'Yes' : 'No', 'phylogenetic tree', biom.tree ? null : 'UniFrac and Faith\'s PD need a tree'));

    const chip = (name, note) => h('span.field-chip', { title: `${name} (${note})` }, h('b', name), h('i', note));

    fill(container, h('div.page.summary',

      h('div.summary-head',
        h('h1', biom.title),
        h('div.tags',
          biom.is_public ? h('span.tag', 'public') : h('span.tag', 'private'),
          h('span.tag', biom.is_editor ? 'you can edit' : 'view only'),
          biom.is_saved ? null : h('span.tag.warn', 'unsaved changes')),
        actions),

      biom.is_saved ? null : h('p.warning', icon('triangle-exclamation'),
        ' Your working copy differs from the saved project. Save it, or save a copy, to keep the changes.'),

      tiles,

      h('div.summary-grid',

        h('div.summary-col',
          h('div.card',
            h('div.card-head',
              h('h2', 'Description'),
              biom.is_editor
                ? button('Edit', () => saveProject({ details: true }), { icon: 'pen', title: 'Edit this project\'s title and description' })
                : h('span.hint', { title: 'Save a copy to give it a title and description of your own.' }, 'view only')),
            serverHtml(h('div.description'), biom.description || '<p><em>No description.</em></p>')),

          h('div.card',
            h('div.card-head',
              h('h2', 'Data'),
              h('div.card-actions',
                button('Metadata', () => go('#/metadata'), { icon: 'table', title: 'See and replace the sample metadata' }),
                button('Taxonomy', () => go('#/taxonomy'), { icon: 'sitemap', title: 'See and replace the taxonomy' }),
                button(biom.tree ? 'Replace tree' : 'Add a tree', () => uploadComponent('tree'), { icon: 'upload', title: 'Upload a phylogenetic tree as a Newick file' }))),
            h('h3', 'Metadata fields'),
            fields.length
              ? h('div.fields', fields.map(f => chip(f.name, f.class === 'numeric' ? 'numeric' : `${f.levels.length} groups`)))
              : h('p.hint', 'This project has no sample metadata.'),
            h('h3', 'Taxonomic ranks'),
            ranks.length
              ? h('div.fields', ranks.map(r => chip(r, `${((biom.taxa || {})[r] || []).length.toLocaleString()} taxa`)))
              : h('p.hint', 'This project has no taxonomy.')),

          links.length ? h('div.card', h('h2', 'Links'), h('div.links', links)) : null),

        h('div.summary-col',
          h('div.card', h('h2', 'Downloads'), downloads)))));
  }

  function linkRow(label, url, hint, extra = null) {
    return h('div.link-row',
      h('span.link-label', label),
      h('code', url),
      button('', () => copyText(url, 'Link copied.'), { icon: 'copy', title: 'Copy' }),
      extra,
      h('p.hint', hint));
  }

  draw();
  return { onBiom: draw };
}
