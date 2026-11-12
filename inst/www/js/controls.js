// The one renderer of controls. It reads a function's parameters from the
// schema and builds an editor for each, by `type`; nothing here knows any
// particular rbiom function or parameter name.
//
// An editor reports a JSON value to send, or UNSET when the user is back at
// rbiom's default, in which case the argument is left out of the request.
// Choices that depend on the data (fields, ranks, taxa, metrics that need a
// tree) are filled in from the open project's summary.

import { h, fill, icon, newId } from './dom.js';
import { picker } from './widgets.js';
import * as S from './schema.js';

const UNSET = undefined;
const same  = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const noDot = text => S.plain(text).replace(/\.$/, '');

// R's plotting symbols and the fill patterns of the fillpattern package,
// which have pictures under /www/img.
const SHAPES   = Array.from({ length: 19 }, (_, i) => i);
const PATTERNS = [
  'bricks', 'checkerboard', 'circles', 'crosshatch', 'crosshatch30', 'crosshatch45', 'fishscales',
  'hexagons', 'horizontal', 'horizontal2', 'horizontal3', 'horizontalsaw', 'hs_bdiagonal', 'hs_cross',
  'hs_diagcross', 'hs_fdiagonal', 'hs_horizontal', 'hs_vertical', 'left30', 'left45', 'leftshingle',
  'octagons', 'right30', 'right45', 'rightshingle', 'smallfishscales', 'vertical', 'vertical2',
  'vertical3', 'verticalbricks', 'verticalleftshingle', 'verticalrightshingle', 'verticalsaw' ];
const FALLBACK_COLORS = ['#4477aa', '#ee6677', '#228833', '#ccbb44', '#66ccee', '#aa3377', '#bbbbbb'];


//_____________________________________________________________________________
// Building blocks

/** A native drop-down over options of any JSON value (including UNSET). */
function dropdown(options, value, onchange, id) {
  const el = h('select', { id, onchange: () => onchange(options[el.selectedIndex].value) });
  let group = null, parent = el;
  for (const o of options) {
    if ((o.group || null) !== group) {
      group  = o.group || null;
      parent = group ? el.appendChild(h('optgroup', { label: group })) : el;
    }
    parent.append(h('option', o.label));
  }
  el.selectedIndex = Math.max(0, options.findIndex(o => same(o.value, value)));
  return el;
}

/** A drop-down, or a searchable picker when the list is long. */
function chooser(options, value, onchange, id) {
  if (options.length <= 12) return dropdown(options, value, onchange, id);
  // The picker compares by value, and UNSET has none, so it stands in as a marker.
  const mark  = v => (v === UNSET ? { unset: true } : v);
  const items = options.map(o => ({ ...o, value: mark(o.value) }));
  return picker({
    id, options: items, value: mark(value),
    onchange: v => onchange(v && v.unset === true ? UNSET : v) });
}

/**
 * The options for a parameter that takes one of a list: first whatever
 * "not set" means (the default, or nothing), then "none" where NULL is
 * allowed and is not already the default, then the choices.
 */
function singleOptions(p, choices, env) {
  const options = [];
  const def = p.default === undefined ? null : p.default;
  const inChoices = choices.some(c => same(c.value, def)) || choices.some(c => same(c.value, canonicalDefault(p, env)));

  if (p.default_expr)             options.push({ value: UNSET, label: noDot(p.default_note) || 'Default' });
  else if (!inChoices && !p.required)
    options.push({ value: UNSET, label: def === null ? (p.null ? noDot(p.null) : 'None') : `Default (${S.describe(p, def, env.biom)})` });

  if (p.null !== undefined && (p.default_expr || def !== null))
    options.push({ value: null, label: noDot(p.null) || 'None' });

  return options.concat(choices);
}

/** A parameter's default in the form its choices use (a metric's id, a rank's name). */
function canonicalDefault(p, env) {
  const def = p.default === undefined ? null : p.default;
  if (def === null) return null;
  if (p.type === 'metric') return S.canonical(p, def)[0];
  if (p.type === 'rank')   return S.rankName(def, env.biom);
  return def;
}

/**
 * An editor for "one of these". Choosing the default again counts as not
 * set, so the request stays as short as the user's changes.
 */
function singleEditor(p, choices, env, value, emit, id) {
  const options = singleOptions(p, choices, env);
  const def     = canonicalDefault(p, env);
  const hasUnset = options.some(o => o.value === UNSET);
  const shown   = value === UNSET ? (hasUnset ? UNSET : def) : value;
  return chooser(options, shown, v => emit(!hasUnset && same(v, def) ? UNSET : v), id);
}

/** An editor for "any number of these", as chips. Empty means not set. */
function multiEditor(p, choices, env, value, emit, id) {
  const def = p.default === undefined ? null : p.default;
  return picker({
    id, options: choices, multiple: true,
    value: value === UNSET || value === null ? [] : [].concat(value),
    placeholder: def === null ? (p.null ? noDot(p.null) : 'None') : S.describe(p, def, env.biom),
    onchange: values => emit(values.length ? values : UNSET) });
}

/** A number box. Reports UNSET when empty; refuses what the schema does not allow. */
function numberBox(p, value, emit, { id, integer = p.type === 'integer', placeholder, min = p.min, max = p.max } = {}) {
  const el = h('input', {
    id, type: 'number', step: integer ? 1 : 'any', min, max,
    value: typeof value === 'number' ? value : '',
    placeholder: placeholder ?? '',
    oninput: () => {
      const text = el.value.trim();
      const n    = Number(text);
      const bad  = text !== '' && (!Number.isFinite(n) || (integer && !Number.isInteger(n)) ||
                   (min !== undefined && n < min) || (max !== undefined && n > max));
      el.classList.toggle('invalid', bad);
      el.title = bad ? `A${integer ? ' whole' : ''} number${min !== undefined ? ` from ${min}` : ''}${max !== undefined ? ` up to ${max}` : ''}.` : '';
      if (!bad) emit(text === '' ? UNSET : n);
    } });
  return el;
}

const paletteOptions = (schema, kinds) => schema.palettes
  .filter(pal => !kinds || kinds.includes(pal.kind))
  .map(pal => ({ value: pal.name, label: pal.name, group: pal.kind, swatch: pal.colors }));


//_____________________________________________________________________________
// One editor per parameter type. Each is called as
//   editor(p, env, value, emit, id) -> element
// where `value` is what the user set (or UNSET) and `env` has the open
// project (`biom`), the `schema`, the function (`def`) and every
// parameter's effective value (`eff`).

const editors = {

  logical(p, env, value, emit, id) {

    const forms = p.forms || ['logical'];
    const def   = p.default === undefined ? null : p.default;

    // A plain yes/no with a yes/no default is a checkbox.
    if (same(forms, ['logical']) && typeof def === 'boolean' && p.null === undefined) {
      return h('input', { id, type: 'checkbox', checked: value === UNSET ? def : value === true,
        onchange: e => emit(e.target.checked === def ? UNSET : e.target.checked) });
    }

    const options = [{ value: UNSET, label: `Default (${S.describe(p, def, env.biom)})` }];
    if (forms.includes('logical') || forms.includes('true')) options.push({ value: true, label: 'Yes' });
    if (forms.includes('logical')) options.push({ value: false, label: 'No' });
    if (p.null !== undefined && def !== null) options.push({ value: null, label: noDot(p.null) });
    if (forms.includes('choice')) for (const c of p.choices) options.push({ value: c, label: c });

    const custom = forms.includes('string') ? 'string' : forms.includes('integer') ? 'integer' : null;
    const CUSTOM = { custom: true };
    if (custom) options.push({ value: CUSTOM, label: custom === 'string' ? 'Text...' : 'A number...' });

    const isCustom = value !== UNSET && (typeof value === 'string' && !(p.choices || []).includes(value) || typeof value === 'number');
    const extra = h('div.control-extra');

    const drawExtra = (on, start) => {
      fill(extra);
      if (!on) return;
      extra.append(custom === 'string'
        ? h('input', { type: 'text', value: typeof start === 'string' ? start : '', placeholder: 'Text',
            oninput: e => emit(e.target.value.trim() === '' ? UNSET : e.target.value) })
        : numberBox({ type: 'integer', min: 1 }, start, emit, { placeholder: 'Number' }));
    };

    const select = dropdown(options, isCustom ? CUSTOM : value, v => {
      drawExtra(v === CUSTOM);
      if (v !== CUSTOM) emit(v);
    }, id);

    drawExtra(isCustom, value);
    return h('div', select, extra);
  },

  choice(p, env, value, emit, id) {
    const choices = p.choices.map(c => ({ value: c, label: c }));
    if (p.max_n !== 1 && !p.per_side) return multiEditor(p, choices, env, value, emit, id);
    if ((p.forms || []).includes('logical')) choices.push({ value: false, label: 'None' });
    return singleEditor(p, choices, env, value, emit, id);
  },

  number(p, env, value, emit, id) {
    const def  = p.default === undefined ? null : p.default;
    const hint = def === null ? (p.null ? noDot(p.null) : '') : S.describe(p, def, env.biom);

    if (p.max_n === 1 || p.per_side) return numberBox(p, value, emit, { id, placeholder: hint });

    // Several numbers, separated by commas.
    const el = h('input', {
      id, type: 'text', inputmode: 'decimal', placeholder: hint,
      value: value === UNSET || value === null ? '' : [].concat(value).join(', '),
      oninput: () => {
        const parts = el.value.split(/[\s,]+/).filter(Boolean).map(Number);
        const bad   = parts.some(n => !Number.isFinite(n) || (p.min !== undefined && n < p.min) || (p.max !== undefined && n > p.max));
        el.classList.toggle('invalid', bad);
        if (!bad) emit(parts.length === 0 ? UNSET : parts.length === 1 ? parts[0] : parts);
      } });
    return el;
  },

  integer(p, env, value, emit, id) { return editors.number(p, env, value, emit, id); },

  string(p, env, value, emit, id) {
    return h('input', { id, type: 'text', value: typeof value === 'string' ? value : '',
      placeholder: p.default || '', oninput: e => emit(e.target.value === '' ? UNSET : e.target.value) });
  },

  layers(p, env, value, emit) {
    const def  = S.canonical(p, p.default) || [];
    let chosen = value === UNSET ? [...def] : S.canonical(p, value) || [];
    const box  = h('div.toggles', { role: 'group' });
    const draw = () => fill(box, p.choices.map(c => h('button', {
      type: 'button', class: chosen.includes(c.name) ? 'on' : '', 'aria-pressed': String(chosen.includes(c.name)),
      onclick: () => {
        const next = chosen.includes(c.name) ? chosen.filter(n => n !== c.name) : [...chosen, c.name];
        if (next.length === 0) return;                  // a figure needs a layer
        chosen = p.choices.map(x => x.name).filter(n => next.includes(n));
        draw();
        emit(same([...chosen].sort(), [...def].sort()) ? UNSET : chosen);
      } }, c.name)));
    draw();
    return box;
  },

  field(p, env, value, emit, id) {

    const choices = S.fieldChoices(p, env.biom).map(f => ({
      value: f.name, label: f.name === '.sample' ? 'Sample name' : f.name,
      group: f.coerced ? 'Numeric, as categories' : null }));

    if (p.required && choices.length === 0)
      return h('p.control-missing', `This project has no ${p.class} metadata field.`);

    // A parameter with no default needs a value before anything can be
    // drawn: start with the first field that suits it.
    if (p.required && value === UNSET) queueMicrotask(() => emit(choices[0].value));

    if (p.max_n !== 1) return multiEditor(p, choices, env, value, emit, id);

    // Fields that can be compared within or between groups: "==Sex", "!=Sex".
    if (!p.ops) return singleEditor(p, choices, env, value, emit, id);

    const split = v => (typeof v === 'string' ? [v.replace(/^(==|!=)/, ''), (v.match(/^(==|!=)/) || [''])[0]] : [v, '']);
    let [name, op] = split(value);
    const send = () => emit(typeof name === 'string' ? op + name : name);

    const ops = dropdown([
      { value: '',   label: 'all pairs' },
      { value: '==', label: 'within groups' },
      { value: '!=', label: 'between groups' } ], op, v => { op = v; if (typeof name === 'string') send(); });
    ops.title = 'Each value comes from a pair of samples: use pairs from the same group, from different groups, or all.';

    return h('div.control-pair', singleEditor(p, choices, env, name, v => { name = v; send(); }, id), ops);
  },

  rank(p, env, value, emit, id) {
    const choices = (env.biom.ranks || []).map(r => ({ value: r, label: S.rankLabel(r) }));
    const shown   = typeof value === 'number' ? S.rankName(value, env.biom) : Array.isArray(value) ? value[0] : value;
    return singleEditor(p, choices, env, shown, emit, id);
  },

  metric(p, env, value, emit, id) {
    const choices = S.metricChoices(p, env.biom).map(c => ({ value: c.id, label: c.name }));
    const shown   = value === UNSET || value === null ? value : S.canonical(p, value);
    if (p.max_n !== 1) return multiEditor(p, choices, env, shown, emit, id);
    return singleEditor(p, choices, env, shown === UNSET || shown === null ? shown : shown[0], emit, id);
  },

  tracks(p, env, value, emit, id) {
    const choices = S.fieldChoices({ class: 'any' }, env.biom)
      .filter(f => f.name !== '.sample').map(f => ({ value: f.name, label: f.name }));
    return multiEditor(p, choices, env, Array.isArray(value) || typeof value === 'string' ? [].concat(value) : UNSET, emit, id);
  },

  // Which taxa: the n most abundant, those above a mean abundance, or named ones.
  taxa(p, env, value, emit, id) {

    const def   = p.default === undefined ? null : p.default;
    const names = (env.biom.taxa || {})[S.rankName('rank' in env.eff ? env.eff.rank : -1, env.biom)] || [];
    const forms = p.forms || ['count', 'fraction', 'names'];

    const modeOf = v => (v === UNSET ? 'default' : v === null ? 'null'
      : typeof v === 'number' ? (v < 1 ? 'fraction' : 'count') : 'names');

    const options = [{ value: 'default', label: `Default (${S.describe(p, def, env.biom)})` }];
    if (p.null !== undefined && def !== null) options.push({ value: 'null', label: noDot(p.null) });
    if (forms.includes('count'))    options.push({ value: 'count',    label: 'The most abundant...' });
    if (forms.includes('fraction')) options.push({ value: 'fraction', label: 'By mean abundance...' });
    if (forms.includes('names'))    options.push({ value: 'names',    label: 'Choose taxa...' });

    const extra = h('div.control-extra');

    const drawExtra = (mode, start) => {
      fill(extra);
      if (mode === 'count')
        extra.append(numberBox({ type: 'integer', min: 1 }, typeof start === 'number' ? start : UNSET,
          v => emit(v), { placeholder: 'How many taxa' }));
      if (mode === 'fraction')
        extra.append(h('div.control-pair',
          numberBox({ type: 'number' }, typeof start === 'number' ? start * 100 : UNSET,
            v => emit(v === UNSET ? UNSET : v / 100), { min: 0.0001, max: 99.99, placeholder: 'At least' }),
          h('span.unit', '% mean abundance')));
      if (mode === 'names')
        extra.append(picker({
          multiple: true, placeholder: 'Choose taxa...',
          options: names.map(n => ({ value: n, label: n })),
          value: Array.isArray(start) ? start : typeof start === 'string' ? [start] : [],
          onchange: values => emit(values.length ? values : UNSET) }));
    };

    const mode   = modeOf(value);
    const select = dropdown(options, mode, m => {
      drawExtra(m);
      if (m === 'default') emit(UNSET);
      if (m === 'null')    emit(null);
    }, id);

    drawExtra(mode, value);
    return h('div', select, extra);
  },

  // Colors, shapes or patterns: automatic, none, a palette, or chosen by hand
  // for each value of the field they are mapped to.
  aesthetic(p, env, value, emit, id) {

    const forms  = p.forms || ['logical'];
    const def    = p.default === undefined ? null : p.default;
    const levels = forms.includes('named_values') ? S.aestheticLevels(p, env.eff, env.biom) : null;
    const canCustom = levels ? levels.length <= 40 : forms.includes('values');
    const CUSTOM = { custom: true };

    const options = [
      { value: def === true  ? UNSET : true,  label: 'Automatic' },
      { value: def === false ? UNSET : false, label: 'None' } ];
    if (forms.includes('palette'))
      options.push(...paletteOptions(env.schema, p.palettes).map(o => ({ ...o, group: `Palette: ${o.group}` })));
    if (canCustom) options.push({ value: CUSTOM, label: 'Choose each...' });

    const isPalette = typeof value === 'string';
    const isCustom  = value !== UNSET && typeof value === 'object' && value !== null;
    const extra     = h('div.control-extra');

    const one = (current, onpick, label) => {
      if (p.aes === 'color')
        return h('label.aes-row', h('input', { type: 'color', value: current, oninput: e => onpick(e.target.value) }), h('span', label));
      const items = p.aes === 'shape'
        ? SHAPES.map(n => ({ value: n, label: `Shape ${n}`, image: `/www/img/shapes/${n}.png` }))
        : PATTERNS.map(n => ({ value: n, label: n, image: `/www/img/patterns/${n}.png` }));
      return h('div.aes-row', picker({ options: items, value: current, onchange: onpick }), h('span', label));
    };

    const starter = i => (p.aes === 'color'
      ? ((env.schema.palettes.find(pal => pal.kind === 'discrete') || { colors: FALLBACK_COLORS }).colors[i % 7] || FALLBACK_COLORS[i % 7]).slice(0, 7)
      : p.aes === 'shape' ? [16, 17, 15, 3, 7, 8, 0, 1, 2][i % 9] : PATTERNS[i % PATTERNS.length]);

    const drawCustom = start => {
      fill(extra);
      if (levels) {
        const map = {};
        levels.forEach((lv, i) => { map[lv] = start && typeof start === 'object' && !Array.isArray(start) && lv in start ? start[lv] : starter(i); });
        extra.append(levels.map(lv => one(map[lv], v => { map[lv] = v; emit({ ...map }); }, lv)));
        return map;
      }
      const n    = p.max_n || 3;
      const list = Array.from({ length: n }, (_, i) => (Array.isArray(start) && start[i] !== undefined ? start[i] : starter(i)));
      extra.append(list.map((v, i) => one(v, nv => { list[i] = nv; emit([...list]); }, `${i + 1}`)));
      return list;
    };

    const drawPalette = name => {
      fill(extra, h('label.inline', h('input', {
        type: 'checkbox', checked: name.startsWith('-'),
        onchange: e => emit((e.target.checked ? '-' : '') + name.replace(/^-/, '')) }), 'Reverse'));
    };

    const shown  = isCustom ? CUSTOM : isPalette ? value.replace(/^-/, '') : value;
    const select = chooser(options, shown, v => {
      if (v === CUSTOM)                { emit(drawCustom(null)); }
      else if (typeof v === 'string')  { drawPalette(v); emit(v); }
      else                             { fill(extra); emit(v); }
    }, id);

    if (isCustom) drawCustom(value);
    if (isPalette) drawPalette(value);
    return h('div', select, extra);
  },

  // A palette for a heat map's color scale.
  palette(p, env, value, emit, id) {
    const def     = typeof p.default === 'string' ? p.default : null;
    let name      = typeof value === 'string' ? value.replace(/^-/, '') : def;
    let reversed  = typeof value === 'string' && value.startsWith('-');
    const send    = () => emit(name === def && !reversed ? UNSET : (reversed ? '-' : '') + name);
    return h('div',
      picker({ id, options: paletteOptions(env.schema, p.palettes), value: name, onchange: v => { name = v; send(); } }),
      h('div.control-extra', h('label.inline', h('input', {
        type: 'checkbox', checked: reversed, onchange: e => { reversed = e.target.checked; send(); } }), 'Reverse')));
  },
};

// Editors whose content depends on another parameter's value are rebuilt
// when that value changes: taxa names follow the rank, and an aesthetic's
// values follow the field it is mapped to.
const dependsOn = p => (p.type === 'taxa' ? ['rank'] : p.type === 'aesthetic' && p.by ? [p.by] : []);


//_____________________________________________________________________________
// The panel

/**
 * Build the controls of one function.
 *
 * @param {object} def     The function's schema entry.
 * @param {object} opts
 *   biom, schema          The open project's summary and the whole schema.
 *   args()                The arguments the user has changed so far.
 *   set(name, value)      Called when the user changes one (UNSET to forget it).
 * @return {{groups: {basic: HTMLElement, advanced: HTMLElement}, refresh: function}}
 *   `refresh()` re-reads `args()`: shows and hides controls by their `when`
 *   rules and rebuilds those that depend on a value that changed.
 */
export function controlPanel(def, { biom, schema, args, set }) {

  const groups = { basic: h('div.controls'), advanced: h('div.controls') };
  const rows   = [];

  for (const p of def.params) {

    const id    = newId('ctl');
    const body  = h('div.control-body');
    const reset = h('button.control-reset', {
      type: 'button', title: 'Back to the default', hidden: true,
      onclick: () => { set(p.name, UNSET); row.build(); refresh(); } }, icon('rotate-left'));

    const row = { p, body, reset, seen: null,
      el: h('div.control', { dataset: { param: p.name, type: p.type } },
        h('div.control-head',
          h('label', { for: id }, p.label),
          p.desc ? h('span.control-help', { title: S.plain([p.desc, p.note].filter(Boolean).join(' ')), tabindex: 0 }, icon('circle-question')) : null,
          reset),
        body) };

    row.build = () => {
      const current = args();
      const eff     = S.effective(def, current);
      const make    = editors[p.type] || editors.string;
      row.seen = JSON.stringify(dependsOn(p).map(name => eff[name]));
      fill(body, make(p, { biom, schema, def, eff }, current[p.name], value => { set(p.name, value); refresh(); }, id));
    };

    (groups[p.group] || groups.advanced).append(row.el);
    rows.push(row);
  }

  function refresh() {
    const current = args();
    const eff     = S.effective(def, current);
    for (const row of rows) {
      row.el.hidden    = !S.active(row.p, def, eff);
      row.reset.hidden = !(row.p.name in current);
      row.el.classList.toggle('changed', row.p.name in current);
      if (row.seen !== JSON.stringify(dependsOn(row.p).map(name => eff[name]))) row.build();
    }
  }

  rows.forEach(row => row.build());
  refresh();

  return { groups, refresh, rebuild: () => { rows.forEach(row => row.build()); refresh(); } };
}
