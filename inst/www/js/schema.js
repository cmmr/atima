// What the schema means. Pure functions of the schema (/api/schema), the
// arguments the user changed and the open project's summary (BIOM); nothing
// here touches the page.
//
// An argument the user has not changed is absent from `args` and is left out
// of the request, so rbiom's own default applies. `null` is a value: it
// means R's NULL ("no facets", "no statistics").

/** Is this value "no value" in R's sense? */
const isNull = value => value === null || value === undefined || (Array.isArray(value) && value.length === 0);

/** A parameter of a function, by name. */
export function param(def, name) {
  return def.params.find(p => p.name === name) || null;
}

/**
 * A value in the form rbiom's `when` rules use: an array of layer names
 * (not letters), metric ids, or plain values; `null` for NULL.
 */
export function canonical(p, value) {

  if (isNull(value)) return null;
  const values = [].concat(value);

  if (p && p.type === 'layers') {
    const names = [];
    for (const v of values) {
      const match = p.choices.find(c => c.name === v);
      if (match) names.push(match.name);
      else for (const letter of String(v)) {
        const byLetter = p.choices.find(c => c.letter === letter);
        if (byLetter) names.push(byLetter.name);
      }
    }
    return names;
  }

  if (p && p.type === 'metric')
    return values.map(v => {
      const s = String(v).toLowerCase();
      const match = p.choices.find(c => c.id === s || c.name.toLowerCase() === s);
      return match ? match.id : s;
    });

  // A field may carry a comparison prefix: "==Sex" is still the field Sex.
  if (p && p.type === 'field')
    return values.map(v => String(v).replace(/^(==|!=)/, ''));

  return values;
}

/**
 * Every parameter's value as rbiom will see it: what the user set, else the
 * default. A default such as `stat.by = x` follows the other parameter.
 */
export function effective(def, args) {
  const eff = {};
  for (const p of def.params)
    eff[p.name] = p.name in args ? args[p.name] : (p.default === undefined ? null : p.default);
  for (const p of def.params)
    if (!(p.name in args) && p.default_expr && p.default_expr in eff)
      eff[p.name] = eff[p.default_expr];
  return eff;
}

function holds(cond, def, eff) {
  const value = canonical(param(def, cond.param), eff[cond.param]);
  const among = list => value !== null && value.some(v => list.map(String).includes(String(v)));
  if ('is' in cond)       return among(cond.is);
  if ('is_not' in cond)   return !among(cond.is_not);
  if ('has_any' in cond)  return among(cond.has_any);
  if ('is_null' in cond)  return value === null;
  if ('not_null' in cond) return value !== null;
  return true;
}

/** Does the parameter have any effect, given the other values? (`when`) */
export function active(p, def, eff) {
  return (p.when || []).every(cond => holds(cond, def, eff));
}

/**
 * Why the parameter has no effect at the moment, as a sentence for the
 * user; empty when it has one.
 */
export function inactiveReason(p, def, eff) {
  const words = list => list.map(String).join(', ').replace(/, ([^,]*)$/, ' or $1');
  const parts = [];
  for (const cond of p.when || []) {
    if (holds(cond, def, eff)) continue;
    const label = `"${(param(def, cond.param) || { label: cond.param }).label}"`;
    if ('is' in cond)            parts.push(`${label} is ${words(cond.is)}`);
    else if ('is_not' in cond)   parts.push(`${label} is not ${words(cond.is_not)}`);
    else if ('has_any' in cond)  parts.push(`${label} includes ${words(cond.has_any)}`);
    else if ('is_null' in cond)  parts.push(`${label} is not set`);
    else if ('not_null' in cond) parts.push(`${label} is set`);
  }
  return parts.length ? `Has no effect unless ${parts.join(' and ')}.` : '';
}

/**
 * The parameter this one belongs under in the controls: colors, shapes and
 * patterns sit under the parameter whose values they are given to (`by`).
 */
export function parentOf(p, def) {
  return p.type === 'aesthetic' && p.by && param(def, p.by) ? p.by : null;
}

/** The arguments to send: what the user changed, where it has an effect. */
export function payload(def, args) {
  const eff = effective(def, args);
  const out = {};
  for (const p of def.params)
    if (p.name in args && active(p, def, eff)) out[p.name] = args[p.name];
  return out;
}

/**
 * Why a request cannot be sent yet, as sentences for the user; empty when
 * it can. Covers required parameters and the function's `rules`.
 */
export function problems(def, args) {

  const eff   = effective(def, args);
  const label = name => (param(def, name) || { label: name }).label;
  const out   = [];

  for (const p of def.params)
    if (p.required && isNull(eff[p.name]))
      out.push(`Choose a value for "${p.label}".`);

  for (const rule of def.rules || []) {
    const set = names => names.filter(name => !isNull(eff[name]));
    if (rule.one_of && set(rule.one_of).length !== 1)
      out.push(`Choose exactly one of: ${rule.one_of.map(label).join(', ')}.`);
    if (rule.any_of && set(rule.any_of).length === 0)
      out.push(`Choose at least one of: ${rule.any_of.map(label).join(', ')}.`);
  }

  return out;
}


//_____________________________________________________________________________
// Choices that come from the open project.

/** The project's field with this name. */
export function field(biom, name) {
  return (biom.fields || []).find(f => f.name === name) || null;
}

/**
 * The metadata fields a `field` parameter can take, best first: those of
 * its class, then (with `coerce`) numeric fields used as categories.
 * The sample names are only offered where any field will do.
 */
export function fieldChoices(p, biom) {
  const cls    = p.class || 'any';
  const fields = (biom.fields || []).filter(f => cls === 'any' || f.name !== '.sample');
  if (cls === 'any') return fields.map(f => ({ ...f, coerced: false }));
  const own   = fields.filter(f => f.class === cls).map(f => ({ ...f, coerced: false }));
  const other = cls === 'categorical' && p.coerce
    ? fields.filter(f => f.class === 'numeric').map(f => ({ ...f, coerced: true })) : [];
  return [...own, ...other];
}

/** A rank as rbiom reads it (a name, or a position: 1 highest, -1 lowest, 0 the OTUs) as a name. */
export function rankName(value, biom) {
  const ranks = biom.ranks || [];
  const named = ranks.filter(r => r !== '.otu');
  if (isNull(value)) return null;
  const v = Array.isArray(value) ? value[0] : value;
  if (typeof v === 'number') {
    if (v === 0) return '.otu';
    return (v > 0 ? named[v - 1] : named[named.length + v]) || '.otu';
  }
  return ranks.includes(v) ? v : null;
}

/** How a rank is shown. */
export function rankLabel(name) { return name === '.otu' ? 'OTU' : name; }

/** The metrics a `metric` parameter offers for this project: no tree, no phylogenetic metrics. */
export function metricChoices(p, biom) {
  return p.choices.filter(c => biom.tree || !c.phylo);
}

/**
 * The values an aesthetic is mapped to: the levels of its `by` field, if
 * that is known. It is not where the field's values are compared in pairs
 * (a `by` parameter with `ops`, in the beta diversity plots): the groups
 * are then pairs such as "Female vs Male", which only rbiom works out.
 */
export function aestheticLevels(p, eff, biom, def) {
  if (!p.by) return null;
  if (def && (param(def, p.by) || {}).ops) return null;
  const by = eff[p.by];
  if (isNull(by) || Array.isArray(by) && by.length !== 1) return null;
  const f = field(biom, String([].concat(by)[0]).replace(/^(==|!=)/, ''));
  return f && f.class === 'categorical' ? f.levels : null;
}


//_____________________________________________________________________________
// Saying values in words.

/** A value as short text, for "Default: ..." hints. */
export function describe(p, value, biom) {
  if (isNull(value)) return p.null ? plain(p.null).replace(/\.$/, '') : 'None';
  if (value === true)  return 'Yes';
  if (value === false) return 'No';
  if (value === 'Inf') return 'No limit';
  if (p.type === 'rank' && biom) return rankLabel(rankName(value, biom) || String(value));
  if (p.type === 'metric') {
    const ids = canonical(p, value);
    return ids.map(id => (p.choices.find(c => c.id === id) || { name: id }).name).join(', ');
  }
  if (p.type === 'layers') return canonical(p, value).join(', ');
  if (p.type === 'taxa' && typeof value === 'number')
    return value < 1 ? `At least ${value * 100}%` : `Top ${value}`;
  if (typeof value === 'object' && !Array.isArray(value)) return 'Custom';
  return [].concat(value).join(', ');
}

/**
 * How much one click of a number box's arrows changes it: 1 for whole
 * numbers, 0.01 for a share or a probability (limits no more than 1
 * apart), else a tenth of the default's size (10 for 400, 0.1 for 1).
 */
export function numberStep(p) {
  if (p.type === 'integer') return 1;
  if (typeof p.min === 'number' && typeof p.max === 'number' && p.max - p.min <= 1) return 0.01;
  const def = p.default;
  if (typeof def === 'number' && Number.isFinite(def) && def !== 0)
    return Number(Math.pow(10, Math.floor(Math.log10(Math.abs(def))) - 1).toPrecision(1));
  return 1;
}

/** A description with rbiom's backticks removed, for tooltips. */
export function plain(text) { return String(text || '').replace(/`/g, ''); }

/** A function's name in the navigation: the server's short label, under the heading of its area. */
export function shortLabel(def) { return def.short || def.label; }

export const areaLabels = {
  alpha: 'Alpha diversity', beta: 'Beta diversity', taxa: 'Taxa abundance', rarefaction: 'Rarefaction' };


//_____________________________________________________________________________
// Values shared between functions, and keeping them in step with the project.
//
// What the user changed is kept once, not per function: `shared` maps a
// key to a value, and every function with a parameter of that key starts
// from that value. So `stat.by = "Sex"` set on one plot is there on the
// next. The key is the parameter's name and kind (`shareKey()`), which is
// the one place that decides what is shared: a categorical `x` and a
// numeric `x`, or the layers of a box plot and of an ordination, have
// different keys and are remembered side by side.
//
// A shared value applies to a function only where it is valid there
// (`valid()`); elsewhere that function shows its default, and the value is
// still there when the user returns to a plot it fits.

/** The key a parameter's value is shared under. */
export function shareKey(p) {
  const many = p.max_n === 1 || p.per_side ? 'one' : 'many';
  const kind = {
    field:     () => [p.class || 'any', many],
    metric:    () => [p.div || '', many],
    layers:    () => [p.choices.map(c => c.name).join(',')],
    choice:    () => [p.choices.join(','), many, (p.forms || []).join(',')],
    logical:   () => [(p.forms || []).join(','), (p.choices || []).join(',')],
    number:    () => [many],
    integer:   () => [many],
    aesthetic: () => [p.aes || '', p.by || '', (p.forms || []).join(','), p.max_n || ''],
  }[p.type];
  return [p.name, p.type, ...(kind ? kind() : [])].join('|');
}

/**
 * Can this parameter take this value, in this project?
 * @param {object|null} eff  The function's other values (`effective()`), for
 *   what depends on them: taxa names belong to the chosen rank, and colors
 *   named for groups belong to the field they are mapped to. With `null`
 *   the question is only whether the project could ever fit the value.
 * @param {object} def  The function the parameter belongs to.
 */
export function valid(p, value, eff, biom, def) {

  if (value === undefined) return false;
  if (value === null)      return p.null !== undefined;

  const list  = [].concat(value);
  const one   = p.max_n === 1 || !!p.per_side;
  const forms = p.forms || [];

  switch (p.type) {

    case 'field': {
      const ok = fieldChoices(p, biom).map(f => f.name);
      return list.length > 0 && !(one && list.length > 1) &&
        list.every(v => typeof v === 'string' && (!!p.ops || !/^(==|!=)/.test(v)) && ok.includes(v.replace(/^(==|!=)/, '')));
    }

    case 'tracks': {
      const ok = (biom.fields || []).map(f => f.name).filter(name => name !== '.sample');
      return list.length > 0 && list.every(v => ok.includes(v));
    }

    case 'rank':
      return list.length === 1 && (typeof list[0] === 'number' || (biom.ranks || []).includes(list[0]));

    case 'taxa': {
      if (list.every(v => typeof v === 'number')) return list.length === 1;
      const taxa  = biom.taxa || {};
      const known = eff ? [taxa[rankName(eff.rank === undefined ? -1 : eff.rank, biom)] || []] : Object.values(taxa);
      return known.some(names => list.every(v => names.includes(v)));
    }

    case 'metric': {
      const ok = metricChoices(p, biom).map(c => c.id);
      return list.length > 0 && !(one && list.length > 1) && canonical(p, value).every(v => ok.includes(v));
    }

    case 'layers': {
      const ok = p.choices.map(c => c.name);
      return list.length > 0 && list.every(v => ok.includes(v));
    }

    case 'choice':
      return list.length > 0 && !(one && list.length > 1) &&
        list.every(v => p.choices.includes(v) || (v === false && forms.includes('logical')));

    case 'logical':
      if (typeof value === 'boolean') return forms.length === 0 || forms.includes('logical') || (value && forms.includes('true'));
      if (typeof value === 'string')  return (p.choices || []).includes(value) || forms.includes('string');
      return typeof value === 'number' && forms.includes('integer');

    case 'number': case 'integer':
      return list.length > 0 && !(one && list.length > 1) &&
        list.every(v => typeof v === 'number' && Number.isFinite(v) &&
          (p.type !== 'integer' || Number.isInteger(v)) &&
          (p.min === undefined || v >= p.min) && (p.max === undefined || v <= p.max));

    case 'aesthetic': {
      if (typeof value === 'boolean') return true;
      if (typeof value === 'string')  return forms.includes('palette');
      if (Array.isArray(value))       return forms.includes('values');
      if (!forms.includes('named_values')) return false;
      const names  = Object.keys(value);
      const levels = eff
        ? [aestheticLevels(p, eff, biom, def) || []]
        : (biom.fields || []).filter(f => f.class === 'categorical').map(f => f.levels);
      return levels.some(lv => names.every(name => lv.includes(name)));
    }

    case 'palette': case 'string':
      return typeof value === 'string';

    default:
      return true;
  }
}

/**
 * What the user changed, for one function: the shared values of its
 * parameters, where they are valid.
 * @return {object} `{param: value}`, as `effective()` and `payload()` take it.
 */
export function fnArgs(def, shared, biom) {

  const args = {};
  for (const p of def.params) {
    const key = shareKey(p);
    if (key in shared) args[p.name] = shared[key];
  }

  // Dropping one value can make another invalid (colors chosen for the
  // groups of a field that is not valid here), so look again until it holds.
  for (let pass = 0; pass <= def.params.length; pass++) {
    const eff = effective(def, args);
    const bad = def.params.filter(p => p.name in args && !valid(p, args[p.name], eff, biom, def));
    if (!bad.length) break;
    for (const p of bad) delete args[p.name];
  }

  return args;
}

/**
 * Drop the shared values that no function could use with this project (a
 * field that was removed or changed class, a rank, taxa, the groups of a
 * field that is gone).
 * @return A new object; the same object if nothing changed.
 */
export function pruneShared(schema, shared, biom) {

  const keep = new Set();
  for (const def of Object.values(schema.functions))
    for (const p of def.params) {
      const key = shareKey(p);
      if (key in shared && !keep.has(key) && valid(p, shared[key], null, biom, def)) keep.add(key);
    }

  const out = {};
  for (const [key, value] of Object.entries(shared)) if (keep.has(key)) out[key] = value;
  return Object.keys(out).length === Object.keys(shared).length ? shared : out;
}

/** The same for the sample filter. */
export function pruneSubset(subset, biom) {
  const out = { cat: {}, num: {} };
  for (const [name, values] of Object.entries(subset.cat || {})) {
    const f = field(biom, name);
    if (f && f.class === 'categorical' && values.every(v => f.levels.includes(v))) out.cat[name] = values;
  }
  for (const [name, range] of Object.entries(subset.num || {})) {
    const f = field(biom, name);
    if (f && f.class === 'numeric') out.num[name] = range;
  }
  return out;
}

/** The sample filter as the server wants it, or `null` when nothing is filtered. */
export function subsetPayload(subset) {
  const cat = Object.keys(subset.cat || {}).length, num = Object.keys(subset.num || {}).length;
  if (!cat && !num) return null;
  const out = {};
  if (cat) out.cat = subset.cat;
  if (num) out.num = subset.num;
  return out;
}
