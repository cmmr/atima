// The home page: what atima is, and the ways in.

import { h, fill, button } from '../dom.js';
import { uploadProject, uploadHelp, go } from '../actions.js';
import * as store from '../store.js';

const examples = [
  { src: '/www/img/boxplot.png', title: 'Box plots',    text: 'Alpha diversity and taxa abundance by group, with statistics.' },
  { src: '/www/img/pcoa.png',    title: 'Ordinations',  text: 'PCoA, NMDS, tSNE and UMAP of beta diversity.' },
  { src: '/www/img/heatmap.png', title: 'Heat maps',    text: 'Clustered taxa abundances and sample distances.' },
  { src: '/www/img/stacked.png', title: 'Stacked bars', text: 'The composition of every sample.' },
];

/**
 * AI apps and scripts: the MCP endpoint, the example script (a Python file
 * served with the app) and the article on connecting an app. The script
 * does not sign in, so on a shared server it is for an ATIMA of one's own.
 */
function scripting(local) {
  const endpoint = h('code', `${window.location.origin}/mcp`);
  const script   = h('a', { href: '/www/examples/atima_mcp.py', download: 'atima_mcp.py' }, 'An example script');
  const article  = h('a', { href: 'https://cmmr.github.io/atima/articles/ai-apps.html', target: '_blank', rel: 'noopener noreferrer' }, 'Connecting an AI app');
  return local
    ? h('li', h('strong', 'Script it. '), 'AI apps and your own programs can list projects, run statistics and draw figures through this copy\'s MCP endpoint, ',
        endpoint, '. ', script, ' (Python) does all three: ', h('code', `python atima_mcp.py --url ${window.location.origin}/mcp`), '. See ', article, '.')
    : h('li', h('strong', 'Script it. '), 'AI apps can list projects, run statistics and draw figures through this server\'s MCP endpoint, ',
        endpoint, ', once you sign in from the app (', article, '). ', script, ' (Python) does the same with an ATIMA on your own computer.');
}

export function show(container) {

  const local = store.get('conf').auth === 'none';

  fill(container, h('div.page',
    h('section.hero',
      h('h1', 'Explore your microbiome data'),
      h('p', 'Upload your counts, or drop the file anywhere on this page, to compare diversity, taxa abundance and statistics across your samples, and take the figures and the R code with you.'),
      h('div.hero-actions',
        button('Upload a file', uploadProject, { icon: 'upload', kind: 'primary large' }),
        button('Browse projects', () => go('#/projects'), { icon: 'folder-open', kind: 'large' })),
      uploadHelp()),

    h('section.two-col',
      h('div',
        h('h2', 'What is ATIMA?'),
        h('p', 'ATIMA, the Agile Toolkit for Incisive Microbial Analyses, is a web interface to the rbiom R package, developed at the ',
          h('a', { href: 'https://www.bcm.edu/research/centers/metagenomics-and-microbiome-research', target: '_blank', rel: 'noopener noreferrer' },
            'Alkek Center for Metagenomics and Microbiome Research'),
          ' at Baylor College of Medicine.'),
        h('ul.features',
          h('li', h('strong', 'Bring your data. '), 'Counts from a BIOM file, QIIME 2, mothur or a plain table, with sample metadata, taxonomy and, for UniFrac, a phylogenetic tree.'),
          h('li', h('strong', 'Explore. '), 'Every figure comes with its statistics table and updates as you change a setting, or, if you prefer, when you press Render.'),
          h('li', h('strong', 'Reproduce. '), 'Each figure shows the R code that makes it, to run and adapt on your own computer.'),
          local
            ? h('li', h('strong', 'Private. '), 'This copy runs on your computer. Your data stays here.')
            : h('li', h('strong', 'Share. '), 'Give colleagues a link, share with them by name, or publish a project for everyone.'),
          scripting(local))),
      h('img.logo', { src: '/www/img/CMMR.png', alt: 'Alkek Center for Metagenomics and Microbiome Research' })),

    h('section',
      h('h2', 'What you can make'),
      h('div.gallery', examples.map(e => h('figure',
        h('img', { src: e.src, alt: '' }), h('figcaption', h('strong', e.title), h('span', e.text))))))));

  return {};
}
