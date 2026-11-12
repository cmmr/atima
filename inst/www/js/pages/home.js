// The home page: what atima is, and the ways in.

import { h, fill, button } from '../dom.js';
import { uploadProject, go } from '../actions.js';
import * as store from '../store.js';

const examples = [
  { src: '/www/img/boxplot.png', title: 'Box plots',    text: 'Alpha diversity and taxa abundance by group, with statistics.' },
  { src: '/www/img/pcoa.png',    title: 'Ordinations',  text: 'PCoA, NMDS, tSNE and UMAP of beta diversity.' },
  { src: '/www/img/heatmap.png', title: 'Heat maps',    text: 'Clustered taxa abundances and sample distances.' },
  { src: '/www/img/stacked.png', title: 'Stacked bars', text: 'The composition of every sample.' },
];

export function show(container) {

  const local = store.get('conf').auth === 'none';

  fill(container, h('div.page',
    h('section.hero',
      h('h1', 'Explore your microbiome data'),
      h('p', 'Upload a BIOM file, or drop one anywhere on this page, to compare diversity, taxa abundance and statistics across your samples, and take the figures and the R code with you.'),
      h('div.hero-actions',
        button('Upload a BIOM file', uploadProject, { icon: 'upload', kind: 'primary large' }),
        button('Browse projects', () => go('#/projects'), { icon: 'folder-open', kind: 'large' }))),

    h('section.two-col',
      h('div',
        h('h2', 'What is ATIMA?'),
        h('p', 'ATIMA, the Agile Toolkit for Incisive Microbial Analyses, is a web interface to the rbiom R package, developed at the ',
          h('a', { href: 'https://www.bcm.edu/research/centers/metagenomics-and-microbiome-research', target: '_blank', rel: 'noopener noreferrer' },
            'Alkek Center for Metagenomics and Microbiome Research'),
          ' at Baylor College of Medicine.'),
        h('ul.features',
          h('li', h('strong', 'Bring your data. '), 'BIOM files with counts, sample metadata, taxonomy and, for UniFrac, a phylogenetic tree.'),
          h('li', h('strong', 'Explore. '), 'Every figure comes with its statistics table and updates as you change a setting.'),
          h('li', h('strong', 'Reproduce. '), 'Each figure shows the R code that makes it, to run and adapt on your own computer.'),
          local
            ? h('li', h('strong', 'Private. '), 'This copy runs on your computer. Your data stays here.')
            : h('li', h('strong', 'Share. '), 'Give colleagues a link, share with them by name, or publish a project for everyone.'))),
      h('img.logo', { src: '/www/img/CMMR.png', alt: 'Alkek Center for Metagenomics and Microbiome Research' })),

    h('section',
      h('h2', 'What you can make'),
      h('div.gallery', examples.map(e => h('figure',
        h('img', { src: e.src, alt: '' }), h('figcaption', h('strong', e.title), h('span', e.text))))))));

  return {};
}
