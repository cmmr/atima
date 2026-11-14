// Cluster functions: group the samples and add the groups to the working
// copy's metadata as a new field, which any plot can then color, facet or
// test by. The controls come from the schema, as on the plot page.

import { h, fill, button } from '../dom.js';
import { call } from '../api.js';
import { section, notify } from '../widgets.js';
import { controlPanel, controlRow } from '../controls.js';
import { busy, go } from '../actions.js';
import * as S from '../schema.js';
import * as store from '../store.js';

export function show(container, fn) {

  const schema = store.get('schema');
  const def    = schema.functions[fn];

  if (!def || def.use !== 'clusters') {
    fill(container, h('p.empty', 'There is no such function.'));
    return {};
  }

  const args     = () => store.fnArgs(def);
  const basic    = h('div');
  const advanced = h('div');
  const name     = h('input', { type: 'text', maxLength: 50, value: 'Cluster', id: 'cluster-name' });
  const problem  = h('p.dialog-problem', { hidden: true, role: 'alert' });
  const existing = h('div');
  const nameRow  = controlRow({ id: 'cluster-name', label: 'Name of the new field' });
  nameRow.body.append(name);

  function build() {
    const biom  = store.get('biom');
    const panel = controlPanel(def, { biom, schema, args, set: (param, value) => store.setArg(def, param, value) });
    fill(basic, panel.groups.basic);
    fill(advanced, panel.groups.advanced.children.length ? section('Advanced', panel.groups.advanced) : null);
    const fields = (biom.fields || []).filter(f => f.class === 'categorical' && f.name !== '.sample');
    fill(existing, h('p.hint', `Categorical fields in this project: ${fields.map(f => f.name).join(', ') || 'none'}.`));
  }

  async function run() {
    const field = name.value.trim();
    const taken = (store.get('biom').fields || []).some(f => f.name === field);
    const bad   = !/^[A-Za-z][A-Za-z0-9 _-]*$/.test(field)
      ? 'The name starts with a letter and has only letters, digits, spaces, hyphens and underscores.'
      : taken ? 'The project already has a field with that name.' : null;
    problem.hidden = !bad;
    problem.textContent = bad || '';
    if (bad) return;

    const done = await busy(`${def.label}...`, () => call('/api/metadata/add_clusters',
      { cluster_fn: fn, cluster_args: S.payload(def, args()), name: field }));
    if (done) notify(`The field "${field}" was added to your working copy. Use it in any plot, and save the project to keep it.`, 'ok', { ms: 9000 });
  }

  build();

  fill(container, h('div.page.narrow',
    h('h1', def.label),
    h('p', 'Samples are sorted into groups, and each sample\'s group is added to the metadata as a new categorical field. ',
      'Any plot can then color, facet or compare by it. Samples that rarefying left out get no group.'),
    h('div.card',
      basic, advanced,
      h('div.controls', nameRow.el),
      problem,
      h('div.card-actions',
        button('Add clusters to the metadata', run, { icon: 'object-group', kind: 'primary' }),
        button('See the metadata', () => go('#/metadata'), { icon: 'table' }))),
    existing));

  return { onBiom: build };
}
