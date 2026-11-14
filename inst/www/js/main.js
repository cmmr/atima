// The application: starts the tab's one session, builds the navigation
// from the schema, and shows the page the address names.
//
// The address is "/<project key>#/<page>/<argument>": the path says which
// project is open and the part after # which page, e.g. "/hmp50#/plot/adiv_boxplot".

import { h, fill, icon, button } from './dom.js';
import { startSession, loadSchema, startHeartbeat, call } from './api.js';
import { showError, menu } from './widgets.js';
import { uploadProject, saveProject, signIn, signOut, busy } from './actions.js';
import * as S from './schema.js';
import * as store from './store.js';

import * as home      from './pages/home.js';
import * as projects  from './pages/projects.js';
import * as summary   from './pages/summary.js';
import * as datatable from './pages/datatable.js';
import * as sharing   from './pages/sharing.js';
import * as plot      from './pages/plot.js';
import * as clusters  from './pages/clusters.js';
import * as legacy    from './pages/legacy.js';
import * as privacy   from './pages/privacy.js';
import * as cite      from './pages/cite.js';

const pages = {
  home:     { show: home.show },
  projects: { show: projects.show },
  summary:  { show: summary.show },
  metadata: { show: c => datatable.show(c, 'metadata') },
  taxonomy: { show: c => datatable.show(c, 'taxonomy') },
  sharing:  { show: sharing.show },
  plot:     { show: plot.show },
  clusters: { show: clusters.show },
  legacy:   { show: legacy.show },
  privacy:  { show: privacy.show },
  cite:     { show: cite.show },
};

// Where the documentation and the source code are.
const DOCS_URL   = 'https://cmmr.github.io/atima/';
const SOURCE_URL = 'https://github.com/cmmr/atima';

const main    = document.getElementById('main');
const nav     = document.getElementById('nav-links');
const topbar  = document.getElementById('topbar');
let   current = null;     // what the page on screen returned: {onBiom, destroy}


//_____________________________________________________________________________
// Navigation

// A link's label is short (NAV_LABEL_MAX characters at most, which a test
// checks); the page's full name is its tooltip and the page's own heading.
function navLink(hash, label, ico, title = null) {
  return h('a.nav-link', { href: hash, title, dataset: { hash } }, ico ? icon(ico) : null, h('span', label));
}

/** A link that leaves the app: it opens in a new tab and says so. */
function navOutside(url, label, title) {
  return h('a.nav-link', { href: url, title, target: '_blank', rel: 'noopener noreferrer' },
    h('span', label), icon('arrow-up-right-from-square', 'nav-outside'));
}

function buildNav() {

  const schema = store.get('schema');
  const groups = [];

  for (const [area, label] of Object.entries(S.areaLabels)) {
    const fns = Object.values(schema.functions).filter(f => f.area === area);
    if (!fns.length) continue;
    groups.push(h('details.nav-group', { dataset: { area } },
      h('summary', icon({ alpha: 'seedling', beta: 'diagram-project', taxa: 'chart-column', rarefaction: 'chart-line' }[area] || 'chart-simple'),
        h('span', label), icon('chevron-down', 'nav-arrow')),
      fns.map(f => navLink(`#/${f.use === 'plot' ? 'plot' : 'clusters'}/${f.fn}`, S.shortLabel(f), null, f.label))));
  }

  fill(nav,
    navLink('#/home', 'Home', 'house'),
    navLink('#/projects', 'Projects', 'folder-open'),
    h('details.nav-group',
      h('summary', icon('database'), h('span', 'Dataset'), icon('chevron-down', 'nav-arrow')),
      navLink('#/summary', 'Summary'),
      navLink('#/metadata', 'Metadata'),
      navLink('#/taxonomy', 'Taxonomy'),
      store.hasAccounts() ? navLink('#/sharing', 'Sharing') : null),
    groups,
    // Only when the administrator registered an older installation, and
    // only for someone the imported projects can belong to.
    store.get('conf').legacy && store.hasAccount() ? navLink('#/legacy', 'Import', 'file-import', 'Import from an older atima') : null,
    // About the software: how to use it, how to cite it, where its code is,
    // and what this copy keeps and on what terms it is used.
    h('details.nav-group',
      h('summary', icon('circle-info'), h('span', 'About'), icon('chevron-down', 'nav-arrow')),
      navOutside(DOCS_URL, 'Docs', 'Documentation and tutorials (opens in a new tab)'),
      navLink('#/cite', 'Cite', null, 'How to cite ATIMA and rbiom'),
      navOutside(SOURCE_URL, 'GitHub', 'Source code and issue tracker (opens in a new tab)'),
      navLink('#/privacy', 'Privacy', null, 'Privacy and terms')));

  // One group is open at a time: opening one closes the others.
  const all = [...nav.querySelectorAll('details.nav-group')];
  for (const group of all)
    group.addEventListener('toggle', () => {
      if (group.open) for (const other of all) if (other !== group) other.open = false;
    });
}

// The button in the top bar folds the navigation away. A narrow window has
// no room to keep it open: there it starts folded, opens over the page, and
// closes again once a link is followed.
const narrow = window.matchMedia('(max-width: 1099px)');

function navIsOpen() {
  return narrow.matches ? document.body.classList.contains('nav-open') : !document.body.classList.contains('nav-closed');
}

function setNav(open) {
  document.body.classList.toggle(narrow.matches ? 'nav-open' : 'nav-closed', narrow.matches ? open : !open);
  if (!narrow.matches) { try { window.localStorage.setItem('atima.nav', open ? 'open' : 'closed'); } catch { /* no storage: not remembered */ } }
  const toggle = topbar.querySelector('.nav-toggle');
  if (toggle) toggle.setAttribute('aria-expanded', String(navIsOpen()));
  // Opened over the page, it is where the keyboard goes next; closed, back to the button.
  if (narrow.matches) (open ? nav.querySelector('a.active, a') : toggle)?.focus();
}

function startNav() {
  let stored = null;
  try { stored = window.localStorage.getItem('atima.nav'); } catch { /* no storage */ }
  document.body.classList.toggle('nav-closed', stored === 'closed');
  document.getElementById('nav-backdrop').addEventListener('click', () => setNav(false));
  nav.addEventListener('click', e => { if (narrow.matches && e.target.closest('a')) setNav(false); });
  window.addEventListener('keydown', e => { if (e.key === 'Escape' && narrow.matches && navIsOpen()) setNav(false); });
  narrow.addEventListener('change', () => { document.body.classList.remove('nav-open'); setNav(navIsOpen()); });
}

function markNav() {
  const here = window.location.hash || '#/home';
  for (const a of nav.querySelectorAll('a.nav-link')) {
    const on = a.dataset.hash === here;
    a.classList.toggle('active', on);
    if (on) { a.setAttribute('aria-current', 'page'); const group = a.closest('details'); if (group) group.open = true; }
    else a.removeAttribute('aria-current');
  }
}


//_____________________________________________________________________________
// The account, in the top right corner: "Sign in" for a visitor, and for
// someone signed in their name, which opens a menu. A copy without
// accounts says so in the same place.

/** A person's initials, for the round mark beside their name. */
function initials(name) {
  const words = String(name || '').trim().split(/\s+/).filter(Boolean);
  return ((words[0] || '?')[0] + (words.length > 1 ? words[words.length - 1][0] : '')).toUpperCase();
}

function accountControl(conf) {

  const places = [
    { label: 'My projects', icon: 'folder-open', href: '#/projects' },
    conf.legacy && store.hasAccount() ? { label: 'Import older projects', icon: 'file-import', href: '#/legacy' } : null,
    { label: 'Privacy and terms', icon: 'shield-halved', href: '#/privacy' } ];

  // No accounts: this copy has one user, the person at this computer.
  if (conf.auth !== 'oidc')
    return menu({
      label: 'This copy of ATIMA', kind: 'account-button',
      face: [h('span.avatar', icon('laptop')), h('span.account-name', 'Local')],
      header: [h('strong', 'This computer only'),
        h('span', 'This copy of ATIMA runs on your computer and has no accounts. Your projects stay here.')],
      items: places });

  // A visitor. Signing in is also how an account is made: the first time,
  // the sign-in provider's details become the account.
  if (conf.is_guest)
    return h('div.account',
      // Beside "Sign in": what signing in, and using the server at all, means.
      h('a.topbar-link', { href: '#/privacy', title: 'Privacy and terms' }, 'Privacy'),
      button('Sign in', signIn, { icon: 'right-to-bracket', kind: 'signin',
        title: 'Sign in, or create an account, with your institution or ORCID' }));

  // Signed in. The name comes from the identity provider: text, never HTML.
  // The rest of what the server knows about the person is fetched when the
  // menu first opens.
  let details = null;
  const about = h('div.account-about');
  const showAbout = () => fill(about, details ? [
    details.email ? h('span', details.email) : null,
    details.affiliation ? h('span', details.affiliation) : null,
    details.issuer ? h('span.hint', `Signed in through ${String(details.issuer).replace(/^https?:\/\//, '').replace(/\/.*$/, '')}`) : null ] : null);

  return menu({
    label: `Account: ${conf.full_name}`, kind: 'account-button',
    face: [h('span.avatar', initials(conf.full_name)), h('span.account-name', conf.full_name)],
    header: () => {
      if (!details) call('/api/account/details').then(d => { details = d; showAbout(); }).catch(() => {});
      showAbout();
      return [h('strong', conf.full_name), conf.is_admin ? h('span.tag', 'Administrator') : null, about];
    },
    items: [...places, 'divider', { label: 'Sign out', icon: 'right-from-bracket', onclick: signOut }] });
}


//_____________________________________________________________________________
// The bar across the top: the open project, its depth, and the account.

function buildTopbar() {

  const biom = store.get('biom');
  const conf = store.get('conf');

  const depths = [...new Set([...(biom.depth_options || []), biom.depth])].sort((a, b) => a - b);
  const depth  = h('select', {
    id: 'depth', title: 'Reads kept per sample. Samples with fewer reads are left out of rarefied figures.',
    onchange: async () => {
      const done = await busy('Rarefying...', () => call('/api/project/rarefy', { depth: Number(depth.value) }));
      if (!done) depth.value = String(store.get('biom').depth);
    } }, depths.map(d => h('option', { value: d, selected: d === biom.depth }, d.toLocaleString())));

  const account = accountControl(conf);

  fill(topbar,
    h('button.nav-toggle', { type: 'button', title: 'Show or hide the navigation', 'aria-label': 'Navigation',
      'aria-controls': 'nav', 'aria-expanded': String(navIsOpen()), onclick: () => setNav(!navIsOpen()) }, icon('bars')),
    h('a.project-title', { href: '#/summary', title: `The open project: ${biom.title}` }, biom.title),
    biom.is_saved ? null : h('button.tag.warn', { type: 'button', title: 'Your working copy has changes that are not saved. Click to save.',
      onclick: () => saveProject({ copy: !biom.is_editor }) }, 'unsaved'),
    h('span.topbar-space'),
    h('label.depth', { for: 'depth' }, 'Depth'), depth,
    button('Upload', uploadProject, { icon: 'upload', kind: 'on-dark', title: 'Upload a file as a new project' }),
    account);
}


//_____________________________________________________________________________
// Showing pages

function parseHash() {
  const [, page = 'home', arg = null] = (window.location.hash || '#/home').split('/');
  return { page: page || 'home', arg: arg ? decodeURIComponent(arg) : null };
}

function showPage() {
  const route = parseHash();
  const page  = pages[route.page] || pages.home;
  if (current && current.destroy) current.destroy();
  store.set('route', route);
  main.scrollTop = 0;
  fill(main);
  main.dataset.page = route.page;
  try { current = page.show(main, route.arg) || {}; }
  catch (err) { current = {}; fill(main, h('p.empty', 'This page could not be shown.')); showError(err); }
  markNav();
}

/** The project changed: keep the address, the bar, the user's settings and the page in step. */
function projectChanged(biom, before) {

  if (!biom) return;

  // The address names the open project, by a key that is safe to show.
  const path = `/${biom.project_key}`;
  if (window.location.pathname !== path)
    window.history.replaceState(null, '', path + window.location.hash);
  document.title = `${biom.title} | ATIMA`;

  // Settings that name a field, rank or taxon the project does not have go.
  const schema = store.get('schema');
  if (schema) {
    const shared = S.pruneShared(schema, store.get('shared'), biom);
    if (shared !== store.get('shared')) store.set('shared', shared);
    store.set('subset', S.pruneSubset(store.get('subset'), biom));
  }

  if (!current) return;
  buildTopbar();
  if (current.onBiom) current.onBiom(biom, before); else showPage();
}


//_____________________________________________________________________________
// Start

async function start() {
  try {
    await Promise.all([startSession(), loadSchema()]);
  } catch (err) {
    fill(main, h('div.page.narrow', h('h1', 'ATIMA could not start'),
      h('p', err.message || 'The server did not answer.'),
      err.id ? h('p.hint', `Error id: ${err.id}`) : null,
      button('Try again', () => window.location.reload(), { icon: 'rotate-right', kind: 'primary' })));
    return;
  }

  store.on('biom', projectChanged);
  store.on('conf', () => { buildNav(); buildTopbar(); markNav(); });

  buildNav();
  startNav();
  current = {};
  projectChanged(store.get('biom'), null);
  showPage();

  window.addEventListener('hashchange', showPage);
  startHeartbeat();

  // An import from an older atima may be running on the server, started
  // from this tab or another: follow it from whichever page is open.
  if (store.get('conf').legacy && store.hasAccount()) legacy.watchImport();

  // A file dropped anywhere on the page is uploaded as a new project.
  const hasFile = e => e.dataTransfer && [...e.dataTransfer.types].includes('Files');
  window.addEventListener('dragover', e => { if (hasFile(e)) { e.preventDefault(); document.body.classList.add('dropping'); } });
  window.addEventListener('dragleave', e => { if (!e.relatedTarget) document.body.classList.remove('dropping'); });
  window.addEventListener('drop', e => {
    document.body.classList.remove('dropping');
    if (!hasFile(e) || document.querySelector('dialog[open]')) return;
    e.preventDefault();
    if (e.dataTransfer.files[0]) uploadProject(e.dataTransfer.files[0]);
  });
}

start();
