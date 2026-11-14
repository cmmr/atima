// How to cite: the wording for ATIMA and for rbiom, with the versions this
// server runs, ready to copy.

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
        'The "R code" tab beside every figure shows the rbiom call that made it, and the "Statistics" tab names the test and the p-value adjustment. ',
        'Where a figure rests on a published method (a diversity metric, a differential abundance test), cite that method too; rbiom\'s help pages give the references.'))));

  return { onBiom() {} };
}
