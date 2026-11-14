// The one renderer of controls. It reads a function's parameters from the
// schema and builds an editor for each, by `type`; nothing here knows any
// particular rbiom function or parameter name.
//
// A control is one line: its label on the left, its value on the right. It
// takes more lines only while it holds several values (layers, a list of
// taxa, a color for each group). Colors, shapes and patterns sit under the
// parameter whose values they are given to, and share one table with a row
// for each of those values.
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

// At most this many values get a color, shape or pattern each by hand.
const MAX_LEVELS = 40;


//_____________________________________________________________________________
// The row every control is built on

/**
 * One control: a line with the label on the left, the editor on the right
 * and room for a reset button at the edge; under it, whatever needs lines
 * of its own (`more`) and the controls that belong to this one (`kids`).
 *
 * @param {object} opts
 *   id      the id of the editor's input, which the label is tied to
 *   label   the label; cut with an ellipsis when long, whole in its tooltip
 *   help    text for the small help icon beside the label, if any
 *   kind    "field" marks a control that picks a metadata field
 *   reset   {title, icon, onclick} for the button at the row's edge, if any
 * @return {{el, body, more, kids, help, reset, label}}
 */
export function controlRow({ id, label, help = null, kind = null, reset = null }) {

  const row = {
    label: h('label.control-label', { for: id, id: `${id}-label`, title: label }, label),
    help:  help ? h('span.control-help', { title: help, tabindex: 0, role: 'img', 'aria-label': help }, icon('circle-question')) : null,
    body:  h('div.control-body'),
    more:  h('div.control-more'),
    kids:  h('div.control-kids'),
    reset: reset ? h('button.control-reset', { type: 'button', title: reset.title, onclick: reset.onclick }, icon(reset.icon)) : null,
  };

  row.el = h('div.control', { dataset: kind ? { kind } : {} },
    h('div.control-row',
      h('div.control-name',
        kind === 'field' ? h('i.fa-solid.fa-table-columns.control-kind', { title: 'Chooses a metadata field', 'aria-hidden': 'true' }) : null,
        row.label, row.help),
      row.body, row.reset),
    row.more, row.kids);

  return row;
}

/** A line inside a control's `more`: a small label and an input. */
function subRow(label, input, { unit = null } = {}) {
  const id = input.id || (input.id = newId('sub'));
  return h('div.control-row.sub',
    h('div.control-name', h('label.control-label', { for: id, title: label }, label)),
    h('div.control-body', input, unit ? h('span.unit', unit) : null));
}


//_____________________________________________________________________________
// Building blocks

/** A native drop-down over options of any JSON value (including UNSET). */
function dropdown(options, value, onchange, id) {
  const el = h('select', { id, onchange: () => { el.title = options[el.selectedIndex].label; onchange(options[el.selectedIndex].value); } });
  let group = null, parent = el;
  for (const o of options) {
    if ((o.group || null) !== group) {
      group  = o.group || null;
      parent = group ? el.appendChild(h('optgroup', { label: group })) : el;
    }
    parent.append(h('option', o.label));
  }
  el.selectedIndex = Math.max(0, options.findIndex(o => same(o.value, value)));
  // A long value is cut short in the box; this shows it whole.
  el.title = options.length ? options[el.selectedIndex].label : '';
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

  // Where a rule says "one of these parameters", leaving one empty needs no
  // explanation beyond "None"; the rule itself is shown above the controls.
  const inRule = (env.def.rules || []).some(rule => (rule.one_of || rule.any_of || []).includes(p.name));

  if (p.default_expr)             options.push({ value: UNSET, label: noDot(p.default_note) || 'Default' });
  else if (!inChoices && !p.required)
    options.push({ value: UNSET, label: def === null ? (p.null && !inRule ? noDot(p.null) : 'None') : `Default (${S.describe(p, def, env.biom)})` });

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

/**
 * An editor for "any number of these": the line says how many are chosen,
 * and each is a chip on the lines below. Empty means not set.
 */
function multiEditor(p, choices, env, value, emit, id) {
  const def = p.default === undefined ? null : p.default;
  const el  = picker({
    id, options: choices, multiple: true,
    value: value === UNSET || value === null ? [] : [].concat(value),
    placeholder: def === null ? (p.null ? noDot(p.null) : 'None') : S.describe(p, def, env.biom),
    onchange: values => emit(values.length ? values : UNSET) });
  return { inline: el, below: el.chips };
}

/**
 * A number box. Reports UNSET when empty; refuses what the schema does not
 * allow, and says why through `problem` (a function taking a sentence or null).
 */
function numberBox(p, value, emit, { id, integer = p.type === 'integer', placeholder, min = p.min, max = p.max, problem = () => {} } = {}) {
  const el = h('input', {
    id, type: 'number', step: integer ? 1 : 'any', min, max,
    value: typeof value === 'number' ? value : '',
    placeholder: placeholder ?? '', title: placeholder ? `Default: ${placeholder}` : null,
    oninput: () => {
      const text = el.value.trim();
      const n    = Number(text);
      const bad  = text !== '' && (!Number.isFinite(n) || (integer && !Number.isInteger(n)) ||
                   (min !== undefined && n < min) || (max !== undefined && n > max));
      el.classList.toggle('invalid', bad);
      el.setAttribute('aria-invalid', String(bad));
      problem(bad ? `Enter a${integer ? ' whole' : ''} number${min !== undefined ? ` from ${min}` : ''}${max !== undefined ? ` up to ${max}` : ''}.` : null);
      if (!bad) emit(text === '' ? UNSET : n);
    } });
  return el;
}

const paletteOptions = (schema, kinds) => schema.palettes
  .filter(pal => !kinds || kinds.includes(pal.kind))
  .map(pal => ({ value: pal.name, label: pal.name, group: pal.kind, swatch: pal.colors }));

/** "Reverse", for a palette. */
function reverseRow(reversed, onchange) {
  return subRow('Reverse', h('input', { type: 'checkbox', checked: reversed, onchange: e => onchange(e.target.checked) }));
}


//_____________________________________________________________________________
// One editor per parameter type. Each is called as
//   editor(p, env, value, emit, id) -> element | {inline, below}
// where `value` is what the user set (or UNSET) and `env` has the open
// project (`biom`), the `schema`, the function (`def`), every parameter's
// effective value (`eff`), the id of the control's label (`labelId`) and
// `problem(text)` for saying why an entry was refused. `inline` goes on
// the control's line, `below` on lines of its own under it.

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
        ? subRow('Text', h('input', { type: 'text', value: typeof start === 'string' ? start : '',
            oninput: e => emit(e.target.value.trim() === '' ? UNSET : e.target.value) }))
        : subRow('Number', numberBox({ type: 'integer', min: 1 }, start, emit, { problem: env.problem })));
    };

    const select = dropdown(options, isCustom ? CUSTOM : value, v => {
      drawExtra(v === CUSTOM);
      if (v !== CUSTOM) emit(v);
    }, id);

    drawExtra(isCustom, value);
    return { inline: select, below: extra };
  },

  choice(p, env, value, emit, id) {
    const choices = p.choices.map(c => ({ value: c, label: String(c) }));
    if (p.max_n !== 1 && !p.per_side) return multiEditor(p, choices, env, value, emit, id);
    if ((p.forms || []).includes('logical')) choices.push({ value: false, label: 'None' });
    return singleEditor(p, choices, env, value, emit, id);
  },

  number(p, env, value, emit, id) {
    const def  = p.default === undefined ? null : p.default;
    const hint = def === null ? (p.null ? noDot(p.null) : '') : S.describe(p, def, env.biom);

    if (p.max_n === 1 || p.per_side) return numberBox(p, value, emit, { id, placeholder: hint, problem: env.problem });

    // Several numbers, separated by commas.
    const el = h('input', {
      id, type: 'text', inputmode: 'decimal', placeholder: hint, title: 'One number, or several separated by commas',
      value: value === UNSET || value === null ? '' : [].concat(value).join(', '),
      oninput: () => {
        const parts = el.value.split(/[\s,]+/).filter(Boolean).map(Number);
        const bad   = parts.some(n => !Number.isFinite(n) || (p.min !== undefined && n < p.min) || (p.max !== undefined && n > p.max));
        el.classList.toggle('invalid', bad);
        el.setAttribute('aria-invalid', String(bad));
        env.problem(bad ? `Enter numbers${p.min !== undefined ? ` from ${p.min}` : ''}${p.max !== undefined ? ` up to ${p.max}` : ''}, separated by commas.` : null);
        if (!bad) emit(parts.length === 0 ? UNSET : parts.length === 1 ? parts[0] : parts);
      } });
    return el;
  },

  integer(p, env, value, emit, id) { return editors.number(p, env, value, emit, id); },

  string(p, env, value, emit, id) {
    return h('input', { id, type: 'text', value: typeof value === 'string' ? value : '',
      placeholder: p.default || '', oninput: e => emit(e.target.value === '' ? UNSET : e.target.value) });
  },

  // Several of a short list, each a button that is on or off.
  layers(p, env, value, emit) {
    const def  = S.canonical(p, p.default) || [];
    let chosen = value === UNSET ? [...def] : S.canonical(p, value) || [];
    const box  = h('div.toggles', { role: 'group', 'aria-labelledby': env.labelId });
    const draw = () => fill(box, p.choices.map(c => h('button', {
      type: 'button', class: chosen.includes(c.name) ? 'on' : '', 'aria-pressed': String(chosen.includes(c.name)),
      onclick: e => {
        const next = chosen.includes(c.name) ? chosen.filter(n => n !== c.name) : [...chosen, c.name];
        if (next.length === 0) return;                  // a figure needs a layer
        chosen = p.choices.map(x => x.name).filter(n => next.includes(n));
        const at = [...box.children].indexOf(e.currentTarget);
        draw();
        box.children[at].focus();
        emit(same([...chosen].sort(), [...def].sort()) ? UNSET : chosen);
      } }, c.name)));
    draw();
    return { inline: null, below: box };
  },

  field(p, env, value, emit, id) {

    const choices = S.fieldChoices(p, env.biom).map(f => ({
      value: f.name, label: f.name === '.sample' ? 'Sample name' : f.name,
      group: f.coerced ? 'Numeric, as categories' : null }));

    if (p.required && choices.length === 0)
      return { inline: null, below: h('p.control-missing', `This project has no ${p.class} metadata field.`) };

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
    const pairs = subRow('Pairs', ops);
    pairs.title  = 'Each value comes from a pair of samples: use pairs from the same group, from different groups, or all.';
    pairs.hidden = typeof name !== 'string';

    return {
      inline: singleEditor(p, choices, env, name, v => { name = v; pairs.hidden = typeof name !== 'string'; send(); }, id),
      below:  pairs };
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
        extra.append(subRow('How many', numberBox({ type: 'integer', min: 1 }, typeof start === 'number' ? start : UNSET,
          v => emit(v), { problem: env.problem })));
      if (mode === 'fraction')
        extra.append(subRow('At least', numberBox({ type: 'number' }, typeof start === 'number' ? start * 100 : UNSET,
          v => emit(v === UNSET ? UNSET : v / 100), { min: 0.0001, max: 99.99, problem: env.problem }), { unit: '% mean' }));
      if (mode === 'names') {
        const el = picker({
          multiple: true, placeholder: 'Choose taxa...', label: 'Taxa to show',
          options: names.map(n => ({ value: n, label: n })),
          value: Array.isArray(start) ? start : typeof start === 'string' ? [start] : [],
          onchange: values => emit(values.length ? values : UNSET) });
        extra.append(el, el.chips);
      }
    };

    const mode   = modeOf(value);
    const select = dropdown(options, mode, m => {
      drawExtra(m);
      if (m === 'default') emit(UNSET);
      if (m === 'null')    emit(null);
    }, id);

    drawExtra(mode, value);
    return { inline: select, below: extra };
  },

  // Colors, shapes or patterns: automatic, none, a palette, or chosen by
  // hand. What is chosen by hand is edited in the table the panel draws
  // (`lookTable()`), one row for each value, shared with the other two.
  aesthetic(p, env, value, emit, id) {

    const forms  = p.forms || ['logical'];
    const def    = p.default === undefined ? null : p.default;
    const levels = forms.includes('named_values') ? S.aestheticLevels(p, env.eff, env.biom, env.def) : null;
    const canCustom = levels ? levels.length <= MAX_LEVELS : forms.includes('values');
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

    const drawPalette = name => fill(extra, reverseRow(name.startsWith('-'), on => emit((on ? '-' : '') + name.replace(/^-/, ''))));

    const shown  = isCustom ? CUSTOM : isPalette ? value.replace(/^-/, '') : value;
    const select = chooser(options, shown, v => {
      if (v === CUSTOM)                { fill(extra); emit(startingLook(p, levels, env.schema)); }
      else if (typeof v === 'string')  { drawPalette(v); emit(v); }
      else                             { fill(extra); emit(v); }
    }, id);

    if (isPalette) drawPalette(value);
    return { inline: select, below: extra };
  },

  // A palette for a heat map's color scale.
  palette(p, env, value, emit, id) {
    const def     = typeof p.default === 'string' ? p.default : null;
    let name      = typeof value === 'string' ? value.replace(/^-/, '') : def;
    let reversed  = typeof value === 'string' && value.startsWith('-');
    const send    = () => emit(name === def && !reversed ? UNSET : (reversed ? '-' : '') + name);
    return {
      inline: picker({ id, options: paletteOptions(env.schema, p.palettes), value: name, onchange: v => { name = v; send(); } }),
      below:  reverseRow(reversed, on => { reversed = on; send(); }) };
  },
};

// Editors whose content depends on another parameter's value are rebuilt
// when that value changes: taxa names follow the rank, and an aesthetic's
// values follow the field it is mapped to.
const dependsOn = p => (p.type === 'taxa' ? ['rank'] : p.type === 'aesthetic' && p.by ? [p.by] : []);


//_____________________________________________________________________________
// Colors, shapes and patterns chosen by hand

/** A first color, shape or pattern for the i-th value. */
function starter(p, i, schema) {
  if (p.aes === 'color')
    return ((schema.palettes.find(pal => pal.kind === 'discrete') || { colors: FALLBACK_COLORS }).colors[i % 7] || FALLBACK_COLORS[i % 7]).slice(0, 7);
  return p.aes === 'shape' ? [16, 17, 15, 3, 7, 8, 0, 1, 2][i % 9] : PATTERNS[i % PATTERNS.length];
}

/** What "Choose each" starts from: a value per level, or a short list where the levels are not known. */
function startingLook(p, levels, schema) {
  if (levels) return Object.fromEntries(levels.map((lv, i) => [lv, starter(p, i, schema)]));
  return Array.from({ length: p.max_n || 3 }, (_, i) => starter(p, i, schema));
}

/** The input for one value's color, shape or pattern. */
function lookCell(p, current, onpick, what) {
  const label = `${p.label} for ${what}`;
  if (p.aes === 'color')
    return h('input', { type: 'color', value: current, title: label, 'aria-label': label, oninput: e => onpick(e.target.value) });
  const items = p.aes === 'shape'
    ? SHAPES.map(n => ({ value: n, label: `Shape ${n}`, image: `/www/img/shapes/${n}.png` }))
    : PATTERNS.map(n => ({ value: n, label: n, image: `/www/img/patterns/${n}.png` }));
  return picker({ options: items, value: current, iconOnly: true, label, onchange: onpick });
}

/**
 * The table for what is chosen by hand: one row for each value (a group of
 * the field, or a position where the groups are not known), and in it that
 * value's color, shape and pattern, for whichever of the three are set to
 * "Choose each".
 *
 * @param {Array} params  The aesthetic parameters that share the table.
 * @param {function} args  The arguments the user has changed so far.
 * @return {{el: HTMLElement, draw: function}}  `draw(current, eff)` after every change.
 */
function lookTable(params, def, args, set) {

  const el = h('div.look', { hidden: true, role: 'group', 'aria-label': 'The look of each value' });
  let seen = null;

  function draw(current, eff) {

    const cols = params.filter(p => S.active(p, def, eff) && current[p.name] !== null && typeof current[p.name] === 'object');
    const rows = [];
    for (const p of cols)
      for (const key of Object.keys(current[p.name])) if (!rows.includes(key)) rows.push(key);

    // Inputs keep what the user typed; build again only for other rows or columns.
    const now = JSON.stringify([cols.map(p => p.name), rows]);
    if (now === seen) return;
    seen = now;

    el.hidden = cols.length === 0;
    fill(el, rows.map(key => {
      const named = cols.some(p => !Array.isArray(current[p.name]));
      const what  = named ? key : `value ${Number(key) + 1}`;
      return h('div.look-row',
        cols.map(p => {
          const mine = current[p.name];
          if (!(key in mine)) return h('span.look-gap');
          return lookCell(p, mine[key], v => {
            const now = args()[p.name];           // the other rows may have changed since
            if (now === null || typeof now !== 'object') return;
            set(p.name, Array.isArray(now) ? now.map((x, i) => (String(i) === key ? v : x)) : { ...now, [key]: v });
          }, what);
        }),
        h('span.look-name', { title: what }, named ? key : `${Number(key) + 1}`));
    }));
  }

  return { el, draw };
}


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
 * @return {{groups: {basic: HTMLElement, advanced: HTMLElement}, refresh: function, rebuild: function}}
 *   `refresh()` re-reads `args()`: greys out controls by their `when`
 *   rules and rebuilds those whose value, or a value they depend on, is no
 *   longer what they show.
 */
export function controlPanel(def, { biom, schema, args, set }) {

  const groups = { basic: h('div.controls'), advanced: h('div.controls') };
  const rows   = [];
  const byName = {};
  const looks  = [];

  const change = (name, value) => { set(name, value); refresh(); };

  for (const p of def.params) {

    const id  = newId('ctl');
    const row = controlRow({
      id, label: p.label,
      help: p.desc ? S.plain([p.desc, p.note].filter(Boolean).join(' ')) : null,
      kind: p.type === 'field' || p.type === 'tracks' ? 'field' : null,
      reset: { title: 'Back to the default', icon: 'rotate-left', onclick: () => change(p.name, UNSET) } });

    Object.assign(row, { p, id, deps: null, shown: UNSET, parent: S.parentOf(p, def) });
    Object.assign(row.el.dataset, { param: p.name, type: p.type });

    row.problem = h('p.control-problem', { hidden: true, role: 'alert' });

    row.build = () => {
      const current = args();
      const eff     = S.effective(def, current);
      const make    = editors[p.type] || editors.string;
      const env     = { biom, schema, def, eff, labelId: `${id}-label`,
        problem: text => { row.problem.hidden = !text; row.problem.textContent = text || ''; } };
      row.deps  = JSON.stringify(dependsOn(p).map(name => eff[name]));
      row.shown = current[p.name];
      env.problem(null);
      const made  = make(p, env, current[p.name], value => { row.shown = value; change(p.name, value); }, id);
      const parts = made instanceof Node ? { inline: made, below: null } : made;
      fill(row.body, parts.inline);
      fill(row.more, parts.below, row.problem);
    };

    rows.push(row);
    byName[p.name] = row;
  }

  // Each control goes under the one it belongs to, or into its group. Those
  // set by hand under one parent share a table; one with no parent has its own.
  for (const row of rows) {
    const parent = row.parent ? byName[row.parent] : null;
    if (parent) parent.kids.append(row.el);
    else (groups[row.p.group] || groups.advanced).append(row.el);
  }
  for (const row of rows.filter(r => r.p.type === 'aesthetic')) {
    const host = row.parent ? byName[row.parent] : row;
    if (!host.look) {
      host.look = lookTable(rows.filter(r => r.p.type === 'aesthetic' && (r.parent ? byName[r.parent] : r) === host).map(r => r.p), def, args, change);
      host.kids.append(host.look.el);
      looks.push(host.look);
    }
  }

  function refresh() {
    const current = args();
    const eff     = S.effective(def, current);

    for (const row of rows) {
      const p       = row.p;
      const changed = p.name in current;
      const why     = S.inactiveReason(p, def, eff);

      // What belongs to a parameter that is not set has nothing to act on.
      const parentValue = row.parent ? eff[row.parent] : true;
      row.el.hidden = parentValue === null || parentValue === undefined || (Array.isArray(parentValue) && parentValue.length === 0);

      row.el.classList.toggle('changed', changed);
      row.el.classList.toggle('inactive', !!why);
      row.reset.hidden = !changed;
      for (const part of [row.body, row.more]) part.inert = !!why;
      row.label.title = why ? `${p.label}. ${why}` : p.label;
      if (row.help) {
        const text = [why, row.help.dataset.help || (row.help.dataset.help = row.help.title)].filter(Boolean).join(' ');
        row.help.title = text;
        row.help.setAttribute('aria-label', text);
        row.help.firstChild.className = `fa-solid fa-${why ? 'ban' : 'circle-question'}`;
      }

      if (row.deps !== JSON.stringify(dependsOn(p).map(name => eff[name])) || !same(row.shown, current[p.name])) row.build();
    }

    for (const look of looks) look.draw(current, eff);
  }

  const rebuild = () => { rows.forEach(row => row.build()); refresh(); };
  rebuild();

  return { groups, refresh, rebuild };
}
