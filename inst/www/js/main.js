// The application: starts the tab's one session, builds the navigation
// from the schema, and shows the page the address names.
//
// The address is "/<project key>#/<page>/<argument>": the path says which
// project is open and the part after # which page, e.g. "/hmp50#/plot/adiv_boxplot".

import { h, fill, icon, button } from './dom.js';
import { startSession, loadSchema, startHeartbeat, call } from './api.js';
import { showError } from './widgets.js';
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
};

const main    = document.getElementById('main');
const nav     = document.getElementById('nav-links');
const topbar  = document.getElementById('topbar');
let   current = null;     // what the page on screen returned: {onBiom, destroy}


//_____________________________________________________________________________
// Navigation

function navLink(hash, label, ico) {
  return h('a.nav-link', { href: hash, dataset: { hash } }, ico ? icon(ico) : null, h('span', label));
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
      fns.map(f => navLink(`#/${f.use === 'plot' ? 'plot' : 'clusters'}/${f.fn}`, S.shortLabel(f)))));
  }

  fill(nav,
    navLink('#/home', 'Home', 'house'),
    navLink('#/projects', 'Projects', 'folder-open'),
    h('details.nav-group', { open: true },
      h('summary', icon('database'), h('span', 'Dataset'), icon('chevron-down', 'nav-arrow')),
      navLink('#/summary', 'Summary'),
      navLink('#/metadata', 'Metadata'),
      navLink('#/taxonomy', 'Taxonomy'),
      store.hasAccounts() ? navLink('#/sharing', 'Sharing') : null),
    groups,
    // Only when the administrator registered an older installation, and
    // only for someone the imported projects can belong to.
    store.get('conf').legacy && store.hasAccount() ? navLink('#/legacy', 'Import from an older atima', 'file-import') : null,
    // A shared server says what it keeps and on what terms it is used.
    store.hasAccounts() ? navLink('#/privacy', 'Privacy and terms', 'shield-halved') : null);
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

  let account = null;
  if (conf.auth === 'oidc') {
    // The name comes from the identity provider: text, never HTML.
    // Beside "Sign in": what signing in, and using the server at all, means.
    account = conf.is_guest
      ? h('div.account', h('a.topbar-link', { href: '#/privacy' }, 'Privacy and terms'),
          button('Sign in', signIn, { icon: 'right-to-bracket', kind: 'on-dark' }))
      : h('div.account', h('span.account-name', { title: 'Signed in' }, icon('user'), ' ', conf.full_name),
          button('Sign out', signOut, { kind: 'on-dark' }));
  }

  fill(topbar,
    h('a.project-title', { href: '#/summary', title: 'The open project' }, biom.title),
    biom.is_saved ? null : h('button.tag.warn', { type: 'button', title: 'Your working copy has changes that are not saved. Click to save.',
      onclick: () => saveProject({ copy: !biom.is_editor }) }, 'unsaved'),
    h('span.topbar-space'),
    h('label.depth', { for: 'depth' }, 'Depth'), depth,
    button('Upload', uploadProject, { icon: 'upload', kind: 'on-dark' }),
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
    const args = { ...store.get('args') };
    let changed = false;
    for (const [fn, fnArgs] of Object.entries(args)) {
      const def = schema.functions[fn];
      const pruned = def ? S.prune(def, fnArgs, biom) : {};
      if (pruned !== fnArgs) { args[fn] = pruned; changed = true; }
    }
    if (changed) store.set('args', args);
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
