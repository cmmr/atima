// How to cite: the wording for ATIMA and for rbiom, with the versions this
// server runs, ready to copy. The methods text beside a result cites ATIMA
// in the same words (`atima_reference()`, R/methods-text.R).

import { h, fill, button } from '../dom.js';
import { copyText } from '../actions.js';

const SITES = {
  atima: 'https://github.com/cmmr/atima',
  rbiom: 'https://github.com/cmmr/rbiom',
};

function reference(text) {
  return h('div.reference', h('p', text), button('Copy', () => copyText(text, 'Citation copied.'), { icon: 'copy' }));
}

export function show(container) {

  // The page's shell carries the versions (`index.html`).
  const { atima = '', rbiom = '' } = (document.querySelector('.nav-foot') || { dataset: {} }).dataset;
  const year = new Date().getFullYear();

  fill(container, h('div.page.narrow.terms',

    h('h1', 'How to cite'),

    h('p', 'If ATIMA helped with work you publish, please cite it and rbiom, the R package that does its calculations. ',
      'Citations are how the use of research software is counted, and what keeps it maintained.'),

    h('section.card',
      h('h2', 'ATIMA'),
      reference(`Smith DP (${year}). ATIMA: Agile Toolkit for Incisive Microbial Analyses. Version ${atima}. ${SITES.atima}`)),

    h('section.card',
      h('h2', 'rbiom'),
      reference(`Smith DP (${year}). rbiom: Integrated Analysis and Visualization of Microbiome Data. R package version ${rbiom}. ${SITES.rbiom}`)),

    h('section.card',
      h('h2', 'In your methods'),
      h('p', `Name the versions you used: ATIMA ${atima} with rbiom ${rbiom}. `,
        'The "Methods" tab beside every figure and table has a paragraph to start from: how the samples were rarefied and filtered, the metrics, tests and p-value adjustment, the software versions, and the references for the published methods it rests on. ',
        'The "R code" tab shows the rbiom call that made the result.'))));

  return { onBiom() {} };
}
