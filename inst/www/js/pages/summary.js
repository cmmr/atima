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

    fill(container, h('div.page',
      h('div.page-head',
        h('h1', biom.title),
        h('div.tags',
          biom.is_public ? h('span.tag', 'public') : h('span.tag', 'private'),
          h('span.tag', biom.is_editor ? 'you can edit' : 'view only'),
          biom.is_saved ? null : h('span.tag.warn', 'unsaved changes'))),

      h('div.summary-grid',
        h('div.card',
          h('div.card-head',
            h('h2', 'Description'),
            biom.is_editor
              ? button('Edit', () => saveProject({ details: true }), { icon: 'pen', title: 'Edit this project\'s title and description' })
              : h('span.hint', { title: 'Save a copy to give it a title and description of your own.' }, 'view only')),
          serverHtml(h('div.description'), biom.description || '<p><em>No description.</em></p>'),
          biom.is_saved ? null : h('p.warning', icon('triangle-exclamation'),
            ' Your working copy differs from the saved project. Save it, or save a copy, to keep the changes.'),
          actions,
          links.length ? h('div.links', links) : null),

        h('div.card',
          h('h2', 'Contents'),
          h('dl.facts',
            h('dt', 'Samples'), h('dd', `${nSamples.toLocaleString()} at this depth`),
            h('dt', 'OTUs'),    h('dd', `${(((biom.taxa || {})['.otu']) || []).length.toLocaleString()} at this depth`),
            h('dt', 'Ranks'),   h('dd', ranks.join(', ') || 'none'),
            h('dt', 'Rarefied to'), h('dd', `${Number(biom.depth).toLocaleString()} reads per sample`),
            h('dt', 'Phylogenetic tree'), h('dd', biom.tree ? 'yes' : 'no (UniFrac and Faith\'s PD need one)'),
            h('dt', 'Metadata'), h('dd', fields.length
              ? fields.map(f => `${f.name} (${f.class === 'numeric' ? 'numeric' : `${f.levels.length} groups`})`).join(', ')
              : 'none')),
          h('div.card-actions',
            button('Metadata', () => go('#/metadata'), { icon: 'table' }),
            button('Taxonomy', () => go('#/taxonomy'), { icon: 'sitemap' }),
            button(biom.tree ? 'Replace the tree' : 'Add a tree', () => uploadComponent('tree'), { icon: 'upload', title: 'A Newick file' }))),

        h('div.card.wide', h('h2', 'Downloads'), downloads))));
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
