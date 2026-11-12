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

/** The values an aesthetic is mapped to: the levels of its `by` field, if that is known. */
export function aestheticLevels(p, eff, biom) {
  if (!p.by) return null;
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
    return value < 1 ? `At least ${value * 100}% mean abundance` : `The ${value} most abundant`;
  if (typeof value === 'object' && !Array.isArray(value)) return 'Custom';
  return [].concat(value).join(', ');
}

/** A description with rbiom's backticks removed, for tooltips. */
export function plain(text) { return String(text || '').replace(/`/g, ''); }

/** A function's label without its area ("Alpha diversity box plot" -> "Box plot"). */
export function shortLabel(def) {
  const short = def.label.replace(/^(Alpha diversity|Beta diversity|Taxa abundance|Taxa|Rarefaction)\s+/i, '');
  return short.charAt(0).toUpperCase() + short.slice(1);
}

export const areaLabels = {
  alpha: 'Alpha diversity', beta: 'Beta diversity', taxa: 'Taxa abundance', rarefaction: 'Rarefaction' };


//_____________________________________________________________________________
// Keeping what the user set in step with the project.

/**
 * Drop the arguments that name something the project no longer has (a
 * field that was removed or changed class, a rank, taxa of another rank).
 * @return A new `args` object for the function; the same object if nothing changed.
 */
export function prune(def, args, biom) {

  const out = {};
  let changed = false;

  for (const [name, value] of Object.entries(args)) {
    const p = param(def, name);
    let keep = !!p;

    if (keep && !isNull(value)) {
      if (p.type === 'field' || p.type === 'tracks') {
        const ok = fieldChoices(p.type === 'tracks' ? { class: 'any' } : p, biom).map(f => f.name);
        keep = canonical({ type: 'field' }, value).every(v => ok.includes(v));
      }
      else if (p.type === 'rank') {
        keep = [].concat(value).every(v => typeof v === 'number' || (biom.ranks || []).includes(v));
      }
      else if (p.type === 'taxa' && [].concat(value).some(v => typeof v === 'string')) {
        const eff   = effective(def, args);
        const known = (biom.taxa || {})[rankName(eff.rank === undefined ? -1 : eff.rank, biom)] || [];
        keep = [].concat(value).every(v => known.includes(v));
      }
      else if (p.type === 'metric') {
        const ok = metricChoices(p, biom).map(c => c.id);
        keep = canonical(p, value).every(v => ok.includes(v));
      }
      else if (p.type === 'aesthetic' && typeof value === 'object' && !Array.isArray(value)) {
        const levels = aestheticLevels(p, effective(def, args), biom) || [];
        keep = Object.keys(value).every(k => levels.includes(k));
      }
    }

    if (keep) out[name] = value; else changed = true;
  }

  return changed ? out : args;
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
