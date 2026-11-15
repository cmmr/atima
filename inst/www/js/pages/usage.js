// "Usage": how many people use this server, from where and for what, and
// whether the server keeps up. For administrators of a server with
// accounts; the server refuses its data to anyone else, and a local install
// records nothing and has no such page.
//
// Everything comes from one call, /api/usage/data, for a range of days. The
// numbers are counts: no name, address or project is in them. What each
// number means is printed beside it and again under "What the numbers
// mean", in words that can go into a report.
//
// Names of networks, institutions, AI apps and referring sites come from
// outside: everything is inserted as text.

import { h, fill, button, downloadText } from '../dom.js';
import { call } from '../api.js';
import { showError, spinner } from '../widgets.js';
import { controlRow } from '../controls.js';
import { copyText } from '../actions.js';
import { lineChart, stackedBars, rankedBars, heatMap, toCsv, fmt } from '../charts.js';
import * as S from '../schema.js';
import * as store from '../store.js';

const DOCS_URL = 'https://cmmr.github.io/atima/articles/server.html#usage';

// The colors of the four areas are theirs wherever they are drawn.
const AREAS = ['alpha', 'beta', 'taxa', 'rarefaction'];

const KIND_LABELS = {
  upload: 'Uploads', open: 'Projects opened', export: 'Exports', save: 'Saves', share: 'Shares',
  publish: 'Published', import: 'Imports', download: 'Downloads by link' };

const CLASS_LABELS = {
  user: 'People (counted above)', admin: 'Administrators', bot: 'Crawlers and monitors', loadtest: 'Load tests',
  health: 'Health checks', anonymous: 'Requests that belong to nobody' };

const OUTCOME_LABELS = {
  done: 'Done', rejected: 'Rejected (a wrong argument)', denied: 'Refused (no access, or the session had ended)',
  replaced: 'Replaced by a newer request', cancelled: 'Cancelled', limited: 'Refused: too many jobs for one person',
  busy: 'Refused: the queue was full', timeout: 'Stopped at the time limit', failed: 'Failed (an error of the server)' };

const iso = d => d.toISOString().slice(0, 10);

/** The ranges offered, as {from, to} for today. */
function periods(today) {
  const t = new Date(today + 'T00:00:00Z');
  const back = days => { const d = new Date(t); d.setUTCDate(d.getUTCDate() - days); return iso(d); };
  const year = t.getUTCFullYear();
  return [
    { id: 'd30',  label: 'Last 30 days',   from: back(29),  to: today },
    { id: 'd90',  label: 'Last 90 days',   from: back(89),  to: today },
    { id: 'd365', label: 'Last 12 months', from: back(364), to: today },
    { id: 'year', label: `${year} so far`, from: `${year}-01-01`, to: today },
    { id: 'last', label: String(year - 1), from: `${year - 1}-01-01`, to: `${year - 1}-12-31` },
    { id: 'all',  label: 'Everything',     from: '2000-01-01', to: today, all: true },
    { id: 'own',  label: 'Other dates',    from: null, to: null } ];
}

const monthName = m => new Date(m + '-01T00:00:00Z').toLocaleDateString(undefined, { month: 'short', year: '2-digit', timeZone: 'UTC' });
const dayName   = d => new Date(d + 'T00:00:00Z').toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
const longDay   = d => new Date(d + 'T00:00:00Z').toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC' });

/** Milliseconds as a person reads them. */
function ms(v) {
  if (v === null || v === undefined || Number.isNaN(Number(v))) return 'no data';
  return v < 1000 ? `${fmt(v)} ms` : `${fmt(v / 1000, 1)} s`;
}

/** Bytes as a person reads them. */
function bytes(v) {
  if (v === null || v === undefined) return 'unknown';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${fmt(v, 1)} ${units[i]}`;
}

let regions = null;
/** A country's name from its two-letter code. */
function country(code) {
  try {
    regions = regions || new Intl.DisplayNames(undefined, { type: 'region' });
    return regions.of(code) || code;
  } catch { return code; }
}

const plural = (n, one, many = one + 's') => `${fmt(n)} ${Number(n) === 1 ? one : many}`;

/** A card: a heading, a button that saves its numbers, and what it shows. */
function card(title, csv, ...body) {
  return h('section.card',
    h('div.card-head', h('h2', title),
      csv && csv.rows.length ? button('CSV', () => downloadText(toCsv(csv.rows, csv.columns), `atima-usage-${csv.name}.csv`),
        { icon: 'download', title: 'Download these numbers as a CSV file' }) : null),
    body);
}

/** A number with what it is. */
function tile(value, label, hint = null) {
  return h('div.stat', { title: hint }, h('strong', value), h('span', label));
}

/** Fill in the months that have no row, so that a chart's time axis has no holes. */
function everyMonth(rows, from, to, blank) {
  if (!rows.length) return rows;
  const have = new Map(rows.map(row => [row.month, row]));
  const out  = [];
  const d    = new Date(rows[0].month + '-01T00:00:00Z');
  const end  = to.slice(0, 7);
  for (let m = iso(d).slice(0, 7); m <= end; d.setUTCMonth(d.getUTCMonth() + 1), m = iso(d).slice(0, 7))
    out.push(have.get(m) || { month: m, ...blank });
  return out;
}

/** Long tables to wide: one row per month, one column per value of `key`. */
function spread(rows, key, value = 'n') {
  const months = new Map();
  for (const row of rows) {
    if (!months.has(row.month)) months.set(row.month, { month: row.month });
    months.get(row.month)[row[key]] = (months.get(row.month)[row[key]] || 0) + row[value];
  }
  return [...months.values()].sort((a, b) => a.month.localeCompare(b.month));
}


//_____________________________________________________________________________
// The sections

function verdictLine(v) {
  const rule = `The rule: on more than ${v.days} of the last ${v.window} days, one job in twenty waited longer than ${ms(v.wait_ms)} for a worker.`;
  const text = {
    none: ['', 'No job has been timed in the last 30 days, so there is nothing to say yet about whether the server keeps up.'],
    ok:   ['ok', `The server is keeping up. On ${plural(v.slow_days, 'day')} of the last ${v.window}, one job in twenty waited longer than ${ms(v.wait_ms)} for a worker.`],
    slow: ['warn', `The server is not keeping up. On ${plural(v.slow_days, 'day')} of the last ${v.window}, one job in twenty waited longer than ${ms(v.wait_ms)} for a worker.`],
    full: ['warn', `The server is full at times. On ${plural(v.full_days, 'day')} of the last ${v.window}, requests were refused because the queue was full.`] }[v.state];
  return h('p.verdict', { class: text[0], title: rule }, text[1]);
}

function reachCards(data, group) {

  const r = data.reach, to = longDay(data.range.to);

  const months = everyMonth(r.by_month, data.range.from, data.range.to, { seen: 0, active: 0, accounts: 0, fresh: 0, returning: 0, browser: 0, apps: 0 });
  // A month nobody was new in keeps the count so far.
  months.forEach((row, i) => { if (row.cumulative === undefined) row.cumulative = i ? months[i - 1].cumulative : 0; });

  const over = {
    day:   { rows: r.by_day,   x: 'day',   label: dayName },
    week:  { rows: r.by_week,  x: 'week',  label: dayName },
    month: { rows: months,     x: 'month', label: monthName } }[group];

  return [

    card('Reach', { name: 'reach', rows: months },
      h('p.hint', `People who completed at least one analysis ("active users"), in the days up to ${to}. `,
        'A person is someone with an account or a browser that has not signed in; one who signs in later is counted once.'),
      h('div.stats',
        tile(fmt(r.active.d7), 'active, 7 days'),
        tile(fmt(r.active.d30), 'active, 30 days'),
        tile(fmt(r.active.d90), 'active, 90 days'),
        tile(fmt(r.active.d365), 'active, 365 days'),
        tile(fmt(r.active.all), 'active, ever'),
        tile(fmt(r.registered), 'accounts', 'People who have signed in at least once and whose account exists today'),
        tile(fmt(r.seen.d365), 'seen, 365 days', 'People who opened the app at all, whether or not they ran anything'))),

    card(`Active users per ${group}`, { name: `active-per-${group}`, rows: over.rows },
      lineChart({ rows: over.rows, x: over.x, label: over.label, format: v => fmt(v),
        series: [{ key: 'active', label: 'Active (ran an analysis)' }, { key: 'seen', label: 'Seen (opened the app)', cls: 'muted' }] })),

    card('New and returning users per month', { name: 'new-returning', rows: months, columns: ['month', 'fresh', 'returning', 'active', 'cumulative'] },
      h('p.hint', 'New: active for the first time that month. Returning: active that month and in an earlier one.'),
      stackedBars({ rows: months, x: 'month', label: monthName,
        series: [{ key: 'returning', label: 'Returning' }, { key: 'fresh', label: 'New', cls: 's2' }] })),

    card('Users so far', { name: 'cumulative', rows: months, columns: ['month', 'cumulative'] },
      h('p.hint', 'Everyone who has ever been active, counted up month by month.'),
      lineChart({ rows: months, x: 'month', label: monthName, format: v => fmt(v), series: [{ key: 'cumulative', label: 'Users so far' }] })) ];
}

function repeatCards(data) {

  const rows = data.repeats.cohorts;
  const cohorts = [...new Set(rows.map(row => row.cohort))].sort().slice(-12);
  const after   = (a, b) => (Number(b.slice(0, 4)) - Number(a.slice(0, 4))) * 12 + Number(b.slice(5)) - Number(a.slice(5));
  const lookup  = new Map(rows.map(row => [`${row.cohort} ${after(row.cohort, row.month)}`, row.n]));
  const span    = Math.min(12, Math.max(0, ...rows.map(row => after(row.cohort, row.month))));
  const steps   = Array.from({ length: span }, (_, i) => i + 1);

  const cell = (cohort, step) => {
    const size = lookup.get(`${cohort} 0`) || 0, n = lookup.get(`${cohort} ${step}`);
    if (after(cohort, data.range.to.slice(0, 7)) < step) return h('td.num');
    const td = h('td.num.shade', { title: `${fmt(n || 0)} of ${fmt(size)}` }, size ? `${fmt(100 * (n || 0) / size)}%` : '');
    td.style.setProperty('--share', String(size ? (n || 0) / size : 0));
    return td;
  };

  const flat = rows.map(row => ({ first_month: row.cohort, month: row.month, months_later: after(row.cohort, row.month), users: row.n }));

  return [

    card('Do new users come back?', { name: 'cohorts', rows: flat },
      h('p.hint', 'Each row is the people who were first active in that month; across, the share of them who were active again one, two, three months later.'),
      cohorts.length === 0 ? h('p.empty', 'Nothing was recorded in this period.') :
        h('div.table-scroll', h('table.data.cohorts',
          h('thead', h('tr', h('th', 'First active'), h('th.num', 'People'), steps.map(i => h('th.num', `+${i}`)))),
          h('tbody', cohorts.map(cohort => h('tr',
            h('td', monthName(cohort)), h('td.num', fmt(lookup.get(`${cohort} 0`) || 0)), steps.map(i => cell(cohort, i)))))))),

    card('Days of use per person', { name: 'days-active', rows: data.repeats.days_active },
      h('p.hint', `On how many days each active person used the server, in the 90 days up to ${longDay(data.range.to)}.`),
      stackedBars({ rows: data.repeats.days_active, x: 'days', format: v => fmt(v),
        label: d => String(d), series: [{ key: 'users', label: 'People' }] })) ];
}

function whereCards(data) {

  const w = data.where;
  const share = w.people ? ` Known for ${fmt(w.placed)} of ${fmt(w.people)} people.` : '';

  return [

    card(`Countries (${fmt(w.n_countries)})`, { name: 'countries', rows: w.countries.map(row => ({ code: row.name, country: country(row.name), users: row.users })) },
      h('p.hint', data.range.lookup
        ? `The country each active person's network address was registered in, looked up on this server at their latest visit.${share}`
        : ['No lookup file is set on this server, so countries and networks are not recorded. ',
           h('a', { href: DOCS_URL, target: '_blank', rel: 'noopener noreferrer' }, 'How to supply one'), '.']),
      rankedBars({ rows: w.countries, name: 'name', value: 'users', label: country })),

    card(`Networks (${fmt(w.n_networks)})`, { name: 'networks', rows: w.networks },
      h('p.hint', 'The organisation that owns the network each active person came from. Universities and institutes mostly run their own; someone at home shows as their internet provider.'),
      rankedBars({ rows: w.networks, name: 'name', value: 'users' })),

    card(`Institutions of people with an account (${fmt(w.n_affiliations)})`, { name: 'institutions', rows: w.affiliations },
      h('p.hint', 'The organisation the sign-in provider names for each active person who signed in. Guests have none.'),
      rankedBars({ rows: w.affiliations, name: 'name', value: 'users' })),

    card('Sites that sent visitors', { name: 'referring-sites', rows: w.sites },
      h('p.hint', `${fmt(w.referred)} of ${plural(w.visits, 'visit')} came from a link on another site. A visit is a browser tab opening the app; most arrive from a bookmark or a typed address, which names no site.`),
      rankedBars({ rows: w.sites, name: 'name', value: 'visits' })),

    card('Pages that sent visitors', { name: 'referring-pages', rows: w.pages },
      h('p.hint', 'Many sites tell the browser to name only the site, not the page, so this list is shorter than the one before.'),
      rankedBars({ rows: w.pages, name: 'name', value: 'visits' })) ];
}

function whatCards(data) {

  const w      = data.what;
  const schema = store.get('schema');
  const fnName = fn => (schema.functions[fn] && schema.functions[fn].label) || fn;
  const blank  = Object.fromEntries(AREAS.map(a => [a, 0]));

  const areas  = everyMonth(spread(w.areas, 'area').map(row => ({ ...blank, ...row })), data.range.from, data.range.to, blank);
  const faces  = everyMonth(w.interfaces, data.range.from, data.range.to, { browser: 0, apps: 0 });
  const kinds  = spread(w.kinds, 'kind');
  const shown  = Object.keys(KIND_LABELS).filter(kind => kinds.some(row => row[kind]));
  const users  = everyMonth(data.reach.by_month, data.range.from, data.range.to, { browser: 0, apps: 0 });

  return [

    card('Analyses per month, by kind of diversity', { name: 'analyses-by-area', rows: areas, columns: ['month', ...AREAS] },
      h('p.hint', 'Plots, statistics and clusterings that ran to the end, by the part of rbiom they belong to.'),
      stackedBars({ rows: areas, x: 'month', label: monthName,
        series: AREAS.map((area, i) => ({ key: area, label: S.areaLabels[area] || area, cls: `s${i + 1}` })) })),

    card('Functions', { name: 'functions', rows: w.functions.map(row => ({ function: row.fn, name: fnName(row.fn), area: row.area, runs: row.n, browser: row.browser, apps: row.apps })) },
      h('p.hint', 'How often each rbiom function ran to the end, in the browser and through AI apps together.'),
      rankedBars({ rows: w.functions, name: 'fn', value: 'n', label: fnName, limit: 12 })),

    card('Browser and AI apps: analyses per month', { name: 'browser-and-apps', rows: faces },
      h('p.hint', 'Analyses (plots, statistics, clusterings, rarefactions, exports, uploads, imports) by how they were asked for.'),
      stackedBars({ rows: faces, x: 'month', label: monthName,
        series: [{ key: 'browser', label: 'Browser' }, { key: 'apps', label: 'AI apps (MCP)', cls: 's2' }] })),

    card('Browser and AI apps: active users per month', { name: 'browser-and-apps-users', rows: users, columns: ['month', 'browser', 'apps', 'active'] },
      h('p.hint', 'Someone who used both in a month is on both lines.'),
      lineChart({ rows: users, x: 'month', label: monthName, format: v => fmt(v),
        series: [{ key: 'browser', label: 'Browser' }, { key: 'apps', label: 'AI apps (MCP)', cls: 's2' }] })),

    card('AI apps', { name: 'ai-apps', rows: w.apps },
      h('p.hint', 'Tool calls that ran to the end, by the name each app gives for itself.'),
      rankedBars({ rows: w.apps, name: 'name', value: 'actions' })),

    card('Data in and out, per month', { name: 'data-in-and-out', rows: kinds, columns: ['month', ...Object.keys(KIND_LABELS)] },
      kinds.length === 0 ? h('p.empty', 'Nothing was recorded in this period.') :
        h('div.table-scroll', h('table.data',
          h('thead', h('tr', h('th', 'Month'), shown.map(kind => h('th.num', KIND_LABELS[kind])))),
          h('tbody', kinds.map(row => h('tr', h('td', monthName(row.month)), shown.map(kind => h('td.num', fmt(row[kind] || 0))))))))),

    card('How requests ended', { name: 'outcomes', rows: w.outcomes },
      rankedBars({ rows: w.outcomes, name: 'outcome', value: 'n', label: o => OUTCOME_LABELS[o] || o })) ];
}

function capacityCards(data) {

  const c    = data.capacity;
  const days = c.days.map(row => ({ ...row, median_s: (row.wait_median || 0) / 1000, high_s: (row.wait_high || 0) / 1000,
    share_sec: row.jobs ? 100 * row.waited_sec / row.jobs : 0, share_long: row.jobs ? 100 * row.waited_long / row.jobs : 0 }));
  const secs = v => `${fmt(v, 1)} s`;

  // The heat map is recorded in UTC and shown in the reader's own time.
  const shift = Math.round(-new Date().getTimezoneOffset() / 60);
  const grid  = new Map();
  for (const row of c.heat) {
    const hour = ((row.hour + shift) % 24 + 24) % 24;
    const day  = ((row.weekday + Math.floor((row.hour + shift) / 24)) % 7 + 7) % 7;
    grid.set(`${day} ${hour}`, row.busy);
  }
  const week = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const workers = Math.max(0, ...c.load.map(row => row.workers || 0));

  return [

    card('Waiting for a worker, per day', { name: 'waits', rows: c.days, columns: ['day', 'jobs', 'wait_median', 'wait_high', 'waited_sec', 'waited_long'] },
      h('p.hint', 'How long jobs waited before a worker took them: half of the day\'s jobs waited less than the median, and 19 in 20 less than the 95th percentile. Every job counts here, load tests included.'),
      lineChart({ rows: days, x: 'day', label: dayName, format: secs,
        series: [{ key: 'high_s', label: '95th percentile', cls: 's2' }, { key: 'median_s', label: 'Median', cls: 's1' }] })),

    card('Share of jobs that waited', { name: 'waited-share', rows: days, columns: ['day', 'jobs', 'share_sec', 'share_long'] },
      lineChart({ rows: days, x: 'day', label: dayName, format: v => `${fmt(v, 1)}%`,
        series: [{ key: 'share_sec', label: 'More than 1 second' }, { key: 'share_long', label: 'More than 10 seconds', cls: 's2' }] })),

    card('Requests refused or stopped, per day', { name: 'refused', rows: c.days, columns: ['day', 'busy', 'limited', 'timed_out', 'failed'] },
      h('p.hint', 'The queue was full (503); one person had too many jobs at once (429); a job passed the time limit (504); an error of the server (500).'),
      stackedBars({ rows: c.days, x: 'day', label: dayName,
        series: [{ key: 'busy', label: 'Queue full' }, { key: 'limited', label: 'Per-person limit', cls: 's2' },
                 { key: 'timed_out', label: 'Time limit', cls: 's3' }, { key: 'failed', label: 'Server error', cls: 's4' }] })),

    card(`CPU cores in use, per day${workers ? ` (of ${fmt(workers)})` : ''}`, { name: 'workers', rows: c.load },
      h('p.hint', 'Sampled every minute: the most cores the server had in use at once, the average, and the longest queue of waiting jobs. Cores are counted as the server measures them, four times a second, for its jobs and for the process that answers requests.'),
      lineChart({ rows: c.load, x: 'day', label: dayName, format: v => fmt(v, 1),
        series: [{ key: 'busy_max', label: 'Most cores in use at once' }, { key: 'busy', label: 'Average in use', cls: 's3' }, { key: 'queue_max', label: 'Longest queue', cls: 's2' }] })),

    card('The last two weeks, hour by hour', { name: 'hours', rows: c.hours },
      lineChart({ rows: c.hours, x: 'hour', label: hr => `${dayName(hr.slice(0, 10))} ${hr.slice(11)}h`, format: v => fmt(v, 1),
        series: [{ key: 'busy_max', label: 'Most cores in use at once' }, { key: 'queue_max', label: 'Longest queue', cls: 's2' }] }),
      h('p.hint', 'Hours are in UTC.')),

    card('When the server is busy', { name: 'busy-by-hour', rows: c.heat },
      h('p.hint', 'Average number of CPU cores in use, by day of the week and hour of the day in your time zone. Darker is busier.'),
      c.heat.length === 0 ? h('p.empty', 'Nothing was recorded in this period.') :
        heatMap({ rowLabels: week, colLabels: Array.from({ length: 24 }, (_, i) => String(i)),
          value: (r, col) => grid.has(`${(r + 1) % 7} ${col}`) ? grid.get(`${(r + 1) % 7} ${col}`) : null,
          title: (r, col, v) => `${week[r]} ${col}:00\n${v === null || v === undefined ? 'no data' : `${fmt(v, 2)} cores in use on average`}` })),

    card('How long things take', { name: 'run-times', rows: c.run_times },
      h('p.hint', 'Time on a worker, by rbiom function or kind of action, slowest first. Only what is still in the record of single actions.'),
      c.run_times.length === 0 ? h('p.empty', 'Nothing was recorded in this period.') :
        h('div.table-scroll', h('table.data',
          h('thead', h('tr', h('th', 'Function or action'), h('th.num', 'Runs'), h('th.num', 'Median'), h('th.num', '95th percentile'))),
          h('tbody', c.run_times.map(row => h('tr',
            h('td', h('code', row.name)), h('td.num', fmt(row.n)), h('td.num', ms(row.median)), h('td.num', ms(row.high)))))))),

    card('Disk', null,
      c.disk
        ? h('div.stats',
            tile(bytes(c.disk.used), 'used by ATIMA\'s data', `Measured ${c.disk.hour}:00 UTC`),
            tile(bytes(c.disk.free), 'free on that disk'))
        : h('p.empty', 'Not measured yet.'),
      lineChart({ rows: c.load.filter(row => row.disk_used !== undefined).map(row => ({ day: row.day, gb: row.disk_used / 1073741824 })),
        x: 'day', label: dayName, format: v => `${fmt(v, 1)} GB`, series: [{ key: 'gb', label: 'Used' }] })) ];
}

function leftOutCards(data) {

  const days = data.capacity.days;

  return [

    card('Left out of the counts', { name: 'left-out', rows: data.classes },
      h('p.hint', 'Everything above counts people only. This is the rest, so that nothing is hidden: the lab\'s own administrators, crawlers, load tests and the server\'s own health checks.'),
      h('div.table-scroll', h('table.data',
        h('thead', h('tr', h('th', 'Whose'), h('th.num', 'Requests'), h('th.num', 'Actions'), h('th.num', 'People'))),
        h('tbody', data.classes.map(row => h('tr',
          h('td', CLASS_LABELS[row.class] || row.class), h('td.num', fmt(row.requests)), h('td.num', fmt(row.actions)), h('td.num', fmt(row.people)))))))),

    card('Visits without a session, per day', { name: 'no-session', rows: days, columns: ['day', 'visitors', 'visitor_hits', 'bots', 'bot_hits'] },
      h('p.hint', 'Page loads and downloads by link that came with no cookie and never started a session: scripts, crawlers, and browsers that block scripts. ',
        'They are told apart for one day only, so the same one counts again the next day; they are never added to the people above.'),
      lineChart({ rows: days, x: 'day', label: dayName, format: v => fmt(v),
        series: [{ key: 'visitors', label: 'Visitors without a session' }, { key: 'bots', label: 'Recognised crawlers', cls: 's2' }] })) ];
}

/** The period in a paragraph, with the definitions it rests on. */
function reportText(data) {

  const s = data.summary;
  const places = data.range.lookup
    ? ` They came from ${plural(s.countries, 'country', 'countries')} and ${plural(s.networks, 'network')} (the organisations that own the networks they connected from)` +
      `${s.affiliations ? `; the sign-in provider named ${plural(s.affiliations, 'institution')} for those with an account` : ''}.`
    : (s.affiliations ? ` The sign-in provider named ${plural(s.affiliations, 'institution')} for those with an account.` : '');

  return [
    `Between ${longDay(data.range.from)} and ${longDay(data.range.to)}, ${plural(s.active, 'person', 'people')} used ATIMA to run at least one analysis` +
      ` (${fmt(s.accounts)} of them signed in with an account; the others used it as guests). ${fmt(s.fresh)} of them did so for the first time,` +
      ` and ${fmt(s.came_back)} used it on more than one day.${places}`,
    `They ran ${plural(s.analyses, 'analysis', 'analyses')}, among them ${plural(s.plots, 'figure')} and ${plural(s.stats, 'statistics table')},` +
      ` uploaded ${plural(s.uploads, 'dataset')}, exported ${plural(s.exports, 'file')} and published ${plural(s.published, 'project')}.` +
      ` ${plural(s.browser, 'person', 'people')} worked in the browser and ${fmt(s.apps)} through an AI app.` +
      (s.jobs ? ` Half of all jobs started within ${ms(s.wait_median)} and 19 in 20 within ${ms(s.wait_high)}.` : ''),
    'How these were counted: a person is an account or a browser that has not signed in (a guest); a guest who signs in is counted once.' +
      ' A person is counted as a user if they completed at least one plot, statistics table, clustering, rarefaction, export, upload or import.' +
      ' Administrators of the server, crawlers and load tests are left out. People who run ATIMA on their own computer are not counted at all: a local copy reports nothing.' ];
}

function definitions(data) {
  return h('section.card', h('h2', 'What the numbers mean'),
    h('ul',
      h('li', h('strong', 'Person. '), 'Someone with an account, or a guest: a browser that has not signed in. A guest who signs in is counted as that account from then on. ',
        'A guest who clears their cookies, or uses a second browser, is counted again; so guests are somewhat over-counted and accounts are exact.'),
      h('li', h('strong', 'Seen. '), 'The person opened the app on that day.'),
      h('li', h('strong', 'Active. '), 'The person completed at least one analysis on that day: a plot, a statistics table, a clustering, a rarefaction, an export, an upload or an import. ',
        'This is the definition public Galaxy servers use ("ran at least one job"), so the numbers can be set beside theirs.'),
      h('li', h('strong', 'Left out. '), 'Administrators, recognised crawlers and monitors, load tests and health checks are in no count; they are listed under "Left out of the counts".'),
      h('li', h('strong', 'Countries and networks. '), 'Looked up from the network address in a file on this server when a visit starts; the address is not kept with the record. ',
        'They say where a connection came from, which for someone on a VPN or a phone is not where they work.'),
      h('li', h('strong', 'What this page cannot see. '), 'People who run ATIMA on their own computer (a local copy records and reports nothing), ',
        'citations, and downloads of the package. Those numbers come from elsewhere: a citation index, the package repository\'s download counts, the source repository\'s stars.'),
      h('li', h('strong', 'How long. '), `The record of single actions and visits is deleted after ${plural(data.range.usage_months, 'month')}; the daily counts made from it are kept. `,
        'Run times per function come from the single actions, so they reach back only that far.')),
    data.range.lookup ? h('p.hint', h('a', { href: 'https://db-ip.com', target: '_blank', rel: 'noopener noreferrer' }, 'IP Geolocation by DB-IP'),
      ' if this server\'s lookup files are DB-IP\'s; otherwise see the licence of the files the administrator supplied.') : null);
}


//_____________________________________________________________________________
// The page

export function show(container) {

  const conf = store.get('conf');

  if (conf.auth !== 'oidc' || !conf.usage || !conf.is_admin) {
    fill(container, h('div.page.narrow', h('h1', 'Usage'),
      h('p.empty', conf.auth !== 'oidc'
        ? 'This copy of ATIMA runs on your own computer. It records nothing about how it is used, and reports nothing to anyone.'
        : !conf.usage ? 'This server does not record how it is used.' : 'This page is for the administrators of this server.')));
    return {};
  }

  const body    = h('div.usage-body');
  const state   = { period: 'd365', from: null, to: null, group: 'month', data: null };
  const today   = iso(new Date());
  const choices = periods(today);

  const select = (id, options, value, onchange) => {
    const el = h('select', { id, onchange: () => onchange(el.value) }, options.map(o => h('option', { value: o.id, selected: o.id === value }, o.label)));
    return el;
  };
  const date = (id, onchange) => {
    const el = h('input', { id, type: 'date', max: today, onchange: () => onchange(el.value) });
    return el;
  };

  const rowPeriod = controlRow({ id: 'usage-period', label: 'Period' });
  const rowFrom   = controlRow({ id: 'usage-from',   label: 'From' });
  const rowTo     = controlRow({ id: 'usage-to',     label: 'To' });
  const rowGroup  = controlRow({ id: 'usage-group',  label: 'Count per', help: 'For the chart of active users: per day, per week (starting Monday) or per month.' });

  const from = date('usage-from', v => { state.from = v; load(); });
  const to   = date('usage-to',   v => { state.to = v; load(); });

  rowPeriod.body.append(select('usage-period', choices, state.period, v => {
    state.period = v;
    rowFrom.el.hidden = rowTo.el.hidden = v !== 'own';
    if (v !== 'own') load();
  }));
  rowFrom.body.append(from);
  rowTo.body.append(to);
  rowGroup.body.append(select('usage-group', [{ id: 'day', label: 'Day' }, { id: 'week', label: 'Week' }, { id: 'month', label: 'Month' }],
    state.group, v => { state.group = v; draw(); }));
  rowFrom.el.hidden = rowTo.el.hidden = true;

  function range() {
    if (state.period === 'own') return state.from && state.to ? { from: state.from, to: state.to } : null;
    const p = choices.find(c => c.id === state.period);
    return { from: p.from, to: p.to };
  }

  function draw() {

    const data = state.data;
    if (!data) return;

    // "Everything" starts where the record does.
    if (state.period === 'all' && data.range.first_day) data.range.from = data.range.first_day;

    const text = reportText(data);

    fill(body,
      verdictLine(data.capacity.verdict),
      h('p.hint', `${longDay(data.range.from)} to ${longDay(data.range.to)}, in UTC days.`,
        data.range.first_day ? ` Recording began on ${longDay(data.range.first_day)}.` : ' Nothing has been recorded yet.'),

      h('h2.usage-part', 'Summary for a report'),
      h('section.card',
        h('div.card-head', h('h2', 'This period in words'),
          button('Copy', () => copyText(text.join('\n\n'), 'Summary copied.'), { icon: 'copy', title: 'Copy the summary' })),
        text.map(p => h('p', p))),

      h('h2.usage-part', 'Reach'),         h('div.usage-grid', reachCards(data, state.group)),
      h('h2.usage-part', 'Repeat use'),    h('div.usage-grid', repeatCards(data)),
      h('h2.usage-part', 'Where from'),    h('div.usage-grid', whereCards(data)),
      h('h2.usage-part', 'What for'),      h('div.usage-grid', whatCards(data)),
      h('h2.usage-part', 'Capacity'),      h('div.usage-grid', capacityCards(data)),
      h('h2.usage-part', 'Not counted'),   h('div.usage-grid', leftOutCards(data)),
      definitions(data));
  }

  async function load() {
    const r = range();
    if (!r) return;
    fill(body, spinner('Counting...'));
    try {
      state.data = await call('/api/usage/data', r);
      draw();
    } catch (err) { showError(err); fill(body, h('p.empty', 'The numbers could not be loaded.')); }
  }

  fill(container, h('div.page.usage',
    h('h1', 'Usage'),
    h('p', 'How many people use this server, from where and for what, and whether the server keeps up. Only administrators see this page. ',
      'It holds counts, never names, addresses or projects.'),
    h('div.card.usage-controls', rowPeriod.el, rowFrom.el, rowTo.el, rowGroup.el),
    body));

  load();
  return {};
}
