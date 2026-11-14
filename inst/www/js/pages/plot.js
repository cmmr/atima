// The plot page: a figure, its statistics and its R code in the middle,
// and on the right the controls the schema describes for the chosen rbiom
// function, the sample filter and the image settings.

import { h, fill, icon, button, debounce, download, serverHtml, newId } from '../dom.js';
import { call, abortJobs } from '../api.js';
import { tabs, section, spinner, picker, notify, showError } from '../widgets.js';
import { controlPanel, controlRow } from '../controls.js';
import { localTable } from '../tables.js';
import { copyText } from '../actions.js';
import * as S from '../schema.js';
import * as store from '../store.js';

// What the columns of rbiom's statistics tables mean.
const STAT_TOOLTIPS = {
  stat:        'Test statistic. Closer to zero is less significant.',
  mean:        'Estimated marginal mean (least-squares mean).',
  mean_diff:   'Difference in means.',
  slope:       'Slope of the trend line. A horizontal line has slope 0.',
  slope_diff:  'Difference in slopes.',
  h1:          'Alternative hypothesis.',
  p_val:       'Probability of a result at least this extreme if the null hypothesis is true.',
  adj_p:       'p_val after adjusting for multiple comparisons.',
  effect_size: "Observed difference divided by the standard deviation (Cohen's d).",
  lower:       'Lower bound of the confidence interval.',
  upper:       'Upper bound of the confidence interval.',
  se:          'Standard error.',
  n:           'Number of samples.',
  df:          'Degrees of freedom.',
  t_ratio:     'How many standard errors the estimate is away from zero.',
  z:           'Standardized effect size.',
  r_sqr:       'Share of the variation the model explains.',
  adj_r:       'r_sqr, taking degrees of freedom into account.',
  aic:         'Akaike information criterion.',
  bic:         'Bayesian information criterion.',
  loglik:      'Log-likelihood of the fit.',
  fit_p:       'P-value for a fit this good arising by chance.',
};

const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));

/** The R code shown beside a figure. */
function figureCode(code) {
  const load = `biom <- as_rbiom("${window.location.origin}/${code.file}")`;
  return [
    '# Make this figure with rbiom.',
    'library(rbiom)',
    load,
    code.rbiom,
    '',
    '',
    '# To change the figure further, edit the ggplot2 code below.',
    'library(rbiom)',
    'library(ggplot2)',
    load,
    code.ggplot2,
  ].join('\n');
}

/** A block of highlighted R code with a copy button. highlight.js escapes the code. */
function codeBlock(text) {
  const code = h('code.language-r');
  serverHtml(code, window.hljs.highlight(text, { language: 'r' }).value);
  return h('div.code-block',
    button('Copy', () => copyText(text, 'Code copied.'), { icon: 'copy' }),
    h('pre', code));
}


//_____________________________________________________________________________
// The sample filter: which samples every figure is made from.

function subsetEditor(onchange) {

  const root = h('div.subset');

  const update = (kind, name, value) => {
    const subset = store.get('subset');
    const next   = { cat: { ...subset.cat }, num: { ...subset.num } };
    if (value === undefined) delete next[kind][name]; else next[kind][name] = value;
    store.set('subset', next);
    onchange();
  };

  function draw() {
    const biom   = store.get('biom');
    const subset = store.get('subset');
    const used   = [...Object.keys(subset.cat), ...Object.keys(subset.num)];
    const rows   = [];

    for (const name of used) {
      const f = S.field(biom, name);
      if (!f) continue;
      const kind = f.class === 'categorical' ? 'cat' : 'num';
      const id   = newId('keep');
      const row  = controlRow({
        id, label: name === '.sample' ? 'Sample name' : name, kind: 'field',
        reset: { title: 'Remove this filter', icon: 'xmark', onclick: () => { update(kind, name, undefined); draw(); } } });

      if (kind === 'cat') {
        const editor = picker({
          id, multiple: true, placeholder: 'None',
          options: f.levels.map(v => ({ value: v, label: v })), value: subset.cat[name],
          // With nothing chosen no sample would be left, so the filter waits.
          onchange: values => { if (values.length) update('cat', name, values); } });
        row.body.append(editor);
        row.more.append(editor.chips);
      } else {
        const [lo, hi] = subset.num[name];
        const box = (value, i) => h('input', {
          id: i === 0 ? id : null, type: 'number', step: 'any', value,
          'aria-label': i === 0 ? 'Lowest value' : 'Highest value', title: i === 0 ? 'Lowest value' : 'Highest value',
          oninput: e => {
            const range = [...store.get('subset').num[name]];
            const n = Number(e.target.value);
            if (e.target.value.trim() === '' || !Number.isFinite(n)) return;
            range[i] = n;
            if (range[0] <= range[1]) update('num', name, range);
          } });
        row.body.append(h('div.control-pair', box(lo, 0), h('span.unit', 'to'), box(hi, 1)));
      }

      rows.push(row.el);
    }

    const free = (biom.fields || []).filter(f => !used.includes(f.name));
    const add  = picker({
      placeholder: 'Keep samples by...', label: 'Add a sample filter',
      options: free.map(f => ({ value: f.name, label: f.name === '.sample' ? 'Sample name' : f.name, note: f.class })),
      onchange: name => {
        const f = S.field(biom, name);
        if (f.class === 'categorical') update('cat', name, [...f.levels]);
        else if (f.min !== null && f.min !== undefined) update('num', name, [f.min, f.max]);
        draw();
      } });

    fill(root,
      h('p.hint', 'Figures and statistics use only the samples that match every filter here.'),
      h('div.controls', rows), free.length ? add : null);
  }

  draw();
  root.redraw = draw;
  root.count  = () => { const s = store.get('subset'); return Object.keys(s.cat).length + Object.keys(s.num).length; };
  return root;
}


//_____________________________________________________________________________
// The image settings.

function imageEditor(onchange) {

  const schema = store.get('schema');
  const params = schema.save.params.filter(p => p.name !== 'device');
  const root   = h('div.controls');

  function draw() {
    const save = store.get('save'), fit = store.get('fit');
    const setSave = (name, value) => {
      const next = { ...store.get('save') };
      if (value === undefined) delete next[name]; else next[name] = value;
      store.set('save', next);
      onchange();
    };

    const fitId  = newId('img');
    const fitRow = controlRow({ id: fitId, label: 'Fit to window', help: 'Size the figure to the room the window has for it.' });
    fitRow.body.append(h('input', { id: fitId, type: 'checkbox', checked: fit,
      onchange: e => { store.set('fit', e.target.checked); draw(); onchange(); } }));
    const rows = [fitRow.el];

    for (const p of params) {
      if (fit && ['width', 'height', 'units'].includes(p.name)) continue;
      const id  = newId('img');
      const row = controlRow({
        id, label: p.label, help: S.plain(p.desc),
        reset: { title: 'Back to the default', icon: 'rotate-left', onclick: () => { setSave(p.name, undefined); draw(); } } });
      const mark = () => {
        const on = p.name in store.get('save');
        row.reset.hidden = !on;
        row.el.classList.toggle('changed', on);
      };
      mark();
      const problem = h('p.control-problem', { hidden: true, role: 'alert' });
      const editor = p.type === 'choice'
        ? h('select', { id, onchange: e => { setSave(p.name, e.target.value === p.default ? undefined : e.target.value); mark(); } },
            p.choices.map(c => h('option', { selected: (save[p.name] ?? p.default) === c }, c)))
        : h('input', { id, type: 'number', step: 'any', min: p.min, max: p.max, placeholder: p.default,
            value: save[p.name] ?? '',
            oninput: e => {
              const n = Number(e.target.value);
              const bad = e.target.value.trim() !== '' && (!Number.isFinite(n) || n <= 0 || (p.min !== undefined && n < p.min) || (p.max !== undefined && n > p.max));
              e.target.classList.toggle('invalid', bad);
              e.target.setAttribute('aria-invalid', String(bad));
              problem.hidden = !bad;
              problem.textContent = bad ? `Enter a number${p.min !== undefined ? ` from ${p.min}` : ' above 0'}${p.max !== undefined ? ` up to ${p.max}` : ''}.` : '';
              if (!bad) { setSave(p.name, e.target.value.trim() === '' ? undefined : n); mark(); }
            } });
      row.body.append(editor);
      row.more.append(problem);
      rows.push(row.el);
    }
    fill(root, rows);
  }

  draw();
  return root;
}


//_____________________________________________________________________________
// The page

export function show(container, fn) {

  const schema = store.get('schema');
  const def    = schema.functions[fn];

  if (!def || def.use !== 'plot') {
    fill(container, h('p.empty', 'There is no such plot.'));
    return {};
  }

  let seq = 0;              // the newest request's number
  let controller = null;    // to stop the request in flight
  let last = null;          // the newest figure's response
  let lastSize = '';

  //___________________________________________________________________________
  // Middle: figure, statistics, code

  const img       = h('img.figure', { alt: def.label, hidden: true });
  const overlay   = h('div.figure-overlay', { hidden: true });
  const message   = h('div.figure-message', { hidden: true, role: 'alert' });
  const figureBox = h('div.figure-box', img, message, overlay);
  const caption   = h('p.figure-caption');
  const statsPane = h('div.pane');
  const codePane  = h('div.pane');

  const device = h('select', { 'aria-label': 'File format', title: 'File format' },
    schema.save.params.find(p => p.name === 'device').choices.map(c => h('option', { value: c }, c.toUpperCase())));
  const tools = h('div.plot-tools', device, button('Download', downloadFigure, { icon: 'download', title: 'Download the figure in this format' }));

  const panes = tabs([
    { id: 'figure', label: 'Figure',     icon: 'chart-column', panel: h('div.pane.figure-pane', figureBox, caption) },
    { id: 'stats',  label: 'Statistics', icon: 'table',        panel: statsPane },
    { id: 'code',   label: 'R code',     icon: 'code',         panel: codePane },
  ]);
  panes.bar.append(tools);

  //___________________________________________________________________________
  // Right: controls

  const problems = h('div.problems', { hidden: true, role: 'alert' });
  const args     = () => store.fnArgs(def);

  const filter      = subsetEditor(() => { badge.textContent = filter.count() || ''; schedule(); });
  const badge       = h('span.badge', filter.count() || '');
  const image       = imageEditor(() => schedule());
  let   panel       = null;
  const basicBox    = h('div');
  const advancedBox = h('div');

  function buildControls() {
    const biom = store.get('biom');
    panel = controlPanel(def, {
      biom, schema, args,
      // A change can leave another setting pointing at nothing, such as
      // colors chosen for the groups of a field that is no longer used:
      // `args()` then no longer has it, and the panel shows its default.
      set: (name, value) => { store.setArg(def, name, value); schedule(); } });
    fill(basicBox, panel.groups.basic);
    fill(advancedBox, panel.groups.advanced);
  }

  const aside = h('aside.plot-controls',
    h('div.plot-controls-head',
      h('h2', { title: def.label }, def.label),
      button('', () => { store.resetArgs(def); buildControls(); schedule(); }, { icon: 'rotate-left',
        title: 'Put every control of this plot back to its default. Other plots that share a setting follow.' })),
    problems, basicBox,
    section('Advanced', advancedBox),
    section('Samples', filter, { badge }),
    section('Image', image));

  fill(container, h('div.plot-page', h('section.plot-main', panes), aside));

  //___________________________________________________________________________
  // Requests

  /** The image settings to send. On screen the figure fills the box, at the screen's resolution. */
  function saveArgs() {
    const save = { ...store.get('save') };
    if (!store.get('fit')) return { args: save, css: null };
    const { min, max } = schema.save.pixels;
    const ratio = window.devicePixelRatio || 1;
    const css   = { width: Math.floor(figureBox.clientWidth), height: Math.floor(figureBox.clientHeight) };
    const dpi   = save.dpi || schema.save.params.find(p => p.name === 'dpi').default;
    return { css, args: {
      ...save, units: 'px',
      width:  clamp(Math.round(css.width  * ratio), min, max),
      height: clamp(Math.round(css.height * ratio), min, max),
      dpi:    clamp(Math.round(dpi * ratio), 30, 1200) } };
  }

  function requestBody(extra = {}) {
    const body = { plot_fn: fn, plot_args: S.payload(def, args()), depth: store.get('biom').depth, ...extra };
    const subset = S.subsetPayload(store.get('subset'));
    if (subset) body.subset_args = subset;
    return body;
  }

  function setBusy(on, text = `Drawing: ${def.label}`) {
    overlay.hidden = !on;
    if (on) fill(overlay, spinner(text), button('Stop', stop, { icon: 'stop', kind: 'danger' }));
    figureBox.classList.toggle('busy', on);
  }

  function showMessage(text, { retry = false, id = null } = {}) {
    message.hidden = !text;
    if (text) fill(message, icon('triangle-exclamation'), h('p', text),
      id ? h('p.hint', `Error id: ${id}`) : null,
      retry ? button('Try again', () => draw(), { icon: 'rotate-right' }) : null);
    img.classList.toggle('stale', !!text);
  }

  async function draw() {

    const stopReasons = S.problems(def, args());
    problems.hidden = stopReasons.length === 0;
    fill(problems, stopReasons.map(text => h('p', text)));
    if (stopReasons.length) { showMessage('Complete the settings on the right to draw this figure.'); return; }

    if (controller) controller.abort();
    controller = new AbortController();
    const mine = ++seq;
    const size = saveArgs();
    lastSize = JSON.stringify(size.css);

    showMessage(null);
    setBusy(true);

    try {
      const resp = await call('/api/plot', requestBody({ save_args: size.args, attrs: true }), { signal: controller.signal });
      if (mine !== seq) return;
      last = resp;
      showFigure(resp, size.css);
      showStats(resp);
      showCode(resp);
    }
    catch (err) {
      if (mine !== seq) return;       // replaced by a newer request: nothing to say
      if (err.status === 409 || err.status === 0) { /* replaced, cancelled or stopped */ }
      else if (err.status === 503) showMessage('The server is busy. Try again in a moment.', { retry: true });
      else if (err.status === 504) showMessage(err.message, { retry: true });
      else if (err.status === 400) showMessage(err.message);
      else { showMessage(err.message, { retry: true, id: err.id }); console.error(err); }
    }
    finally {
      if (mine === seq) { setBusy(false); controller = null; }
    }
  }

  const schedule = debounce(draw, 400);

  /** The stop button: give up waiting and cancel the job on the server. */
  function stop() {
    seq++;
    if (controller) controller.abort();
    controller = null;
    setBusy(false);
    abortJobs();
    if (!last) showMessage('Stopped. Change a setting to draw the figure.', { retry: true });
  }

  function showFigure(resp, css) {
    img.hidden = false;
    img.src    = resp.image_url;
    img.style.width  = css ? `${css.width}px`  : '';
    img.style.height = css ? `${css.height}px` : '';
    figureBox.classList.toggle('fitted', !!css);
    const biom  = store.get('biom');
    const depth = def.sample_set === 'rare'
      ? `Made from counts rarefied to ${biom.depth.toLocaleString()} reads per sample.`
      : 'Made from the counts before rarefying.';
    const n = filter.count();
    caption.textContent = depth + (n ? ` ${n} sample filter${n > 1 ? 's' : ''} applied.` : '');
  }

  function showStats(resp) {
    if (!resp.stats_table || resp.stats_table.length === 0) {
      fill(statsPane, h('p.empty', 'This figure has no statistics. Statistics need groups to compare or a trend to test.'));
      return;
    }
    fill(statsPane,
      Object.values(resp.stats_title || {}).map(line => h(String(line).includes(' ~ ') ? 'p.stats-model' : 'p.stats-title', String(line))),
      localTable(resp.stats_table, { tooltips: STAT_TOOLTIPS, filename: `${fn}_stats.csv` }),
      resp.code && resp.code.stats
        ? section('R code for this table', codeBlock(`library(rbiom)\nbiom <- as_rbiom("${window.location.origin}/${resp.code.file}")\n${resp.code.stats}`))
        : null);
  }

  function showCode(resp) {
    fill(codePane, resp.code ? codeBlock(figureCode(resp.code)) : h('p.empty', 'No code is available for this figure.'));
  }

  /** Draw the figure again in the chosen format and save that file. */
  async function downloadFigure() {
    if (S.problems(def, args()).length) return;
    const format = device.value;
    const note = notify(`Preparing the ${format.toUpperCase()} file...`, 'info', { ms: 0 });
    note.classList.add('working');
    try {
      const resp = await call('/api/plot', requestBody({ save_args: { ...saveArgs().args, device: format } }));
      download(resp.image_url, `${fn}.${format}`);
    }
    catch (err) { showError(err); }
    finally { note.remove(); }
  }

  //___________________________________________________________________________
  // Keeping up with the window and the project

  const resized = debounce(() => {
    if (!store.get('fit') || figureBox.clientWidth === 0) return;
    if (JSON.stringify(saveArgs().css) !== lastSize) draw();
  }, 400);
  const watcher = new ResizeObserver(resized);
  watcher.observe(figureBox);

  buildControls();
  // The first figure waits a moment: for the page to be laid out, so that
  // it fits, and for a required field to be chosen for the user.
  schedule();

  return {
    // The project changed under the page: another depth, a new field, or
    // another project altogether.
    onBiom(biom, before) {
      buildControls();
      filter.redraw();
      badge.textContent = filter.count() || '';
      const sameData = before && biom.depth === before.depth && biom.node_id === before.node_id &&
        JSON.stringify(biom.fields) === JSON.stringify(before.fields);
      if (!sameData) schedule();
    },
    destroy() {
      seq++;
      schedule.cancel(); resized.cancel();
      watcher.disconnect();
      if (controller) { controller.abort(); abortJobs(); }
    },
  };
}
