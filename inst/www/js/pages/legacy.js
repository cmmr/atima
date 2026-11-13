// Importing projects from an older atima. The administrator has saved the
// old installation's database; a signed-in person proves who they were
// there with their old email address and password, and picks the projects
// to bring over.
//
// The import itself runs on the server, in the background: this page hands
// over the list and can be left. watchImport() asks how far it has come,
// from whichever page is open, and says so when it is done.
//
// The old password is sent with "find my projects" and with "import". This
// page keeps it in memory until the page is left, so that an import can be
// started without typing it twice; the server keeps it only while an import
// runs. Project titles come from the old database: they are inserted as
// text.

import { h, fill, icon, button, newId } from '../dom.js';
import { call } from '../api.js';
import { confirm, showError, spinner, notify } from '../widgets.js';
import { signIn } from '../actions.js';
import * as store from '../store.js';

const listText = {
  new:    '',
  shared: 'Someone you shared it with has imported it. You will be added to their copy.',
  have:   'Already in your projects.',
};

const stateText = {
  queued:        'Waiting',
  running:       'Importing...',
  imported:      'Imported',
  added:         'Added to your projects',
  have:          'Already in your projects',
  needs_scaling: 'Not imported: its counts are not whole numbers',
  failed:        'Not imported',
  cancelled:     'Cancelled',
};

const stateIcon = {
  queued: 'clock', imported: 'circle-check', added: 'circle-check', have: 'circle-check',
  needs_scaling: 'triangle-exclamation', failed: 'triangle-exclamation', cancelled: 'ban',
};


//_____________________________________________________________________________
// Following an import, from any page.

const watchers = new Set();     // called with each status
let   timer    = null;
let   note     = null;          // the "importing" notice
let   wasActive = false;
let   arrived  = -1;            // projects that had arrived at the last look

function count(status, ...states) {
  return status.projects.filter(p => states.includes(p.state)).length;
}

function report(status) {

  for (const fn of watchers) fn(status);

  if (status.active) {
    const done = status.projects.length - count(status, 'queued', 'running');
    const text = `Importing from ${status.source}: ${done} of ${status.projects.length} done`;
    if (!note || !note.isConnected) { note = notify(text, 'info', { ms: 0 }); note.classList.add('working'); }
    else note.querySelector('div > div').textContent = text;
  } else {
    if (note) note.remove();
    note = null;
    // Say how it ended, once, wherever the person is by now.
    if (wasActive) {
      const added   = count(status, 'imported', 'added');
      const trouble = count(status, 'needs_scaling', 'failed');
      notify(`Import finished: ${added} project${added === 1 ? '' : 's'} added` +
        (trouble ? `, ${trouble} not imported. See "Import from an older atima".` : '.'), trouble ? 'info' : 'ok', { ms: 12000 });
    }
  }

  wasActive = status.active;
}

/** Ask the server how the import is doing, and keep asking while it runs. */
export async function watchImport() {
  clearTimeout(timer);
  try {
    let status = await call('/api/legacy/status');
    // A project has arrived: ask again with the project tree, which call()
    // puts in the store, so that the list of projects shows it.
    const now = count(status, 'imported', 'added');
    if (arrived >= 0 && now > arrived) status = await call('/api/legacy/status', { tree: true });
    arrived = now;
    report(status);
    if (status.active) timer = setTimeout(watchImport, 3000);
    return status;
  } catch (err) {
    // Not worth a message every few seconds; try again more slowly.
    if (wasActive) timer = setTimeout(watchImport, 15000);
    return null;
  }
}


//_____________________________________________________________________________
// The page

export function show(container) {

  const conf = store.get('conf');

  if (!conf.legacy) {
    fill(container, h('div.page.narrow', h('h1', 'Import from an older atima'),
      h('p.empty', 'This server has no older installation to import from.')));
    return {};
  }

  if (!store.hasAccount()) {
    fill(container, h('div.page.narrow',
      h('h1', 'Import from an older atima'),
      h('div.card',
        h('p', 'Sign in first. The projects you import are added to your account.'),
        h('div.card-actions', button('Sign in', signIn, { icon: 'right-to-bracket', kind: 'primary' })))));
    return {};
  }

  let login   = null;     // {source, email, password} once the server has accepted them
  let working = false;    // a request of this page is under way
  let running = false;    // an import is running on the server

  const ids      = { source: newId('legacy'), email: newId('legacy'), password: newId('legacy') };
  const source   = h('select', { id: ids.source });
  const email    = h('input', { id: ids.email, type: 'email', autocomplete: 'off', spellcheck: false });
  const password = h('input', { id: ids.password, type: 'password', autocomplete: 'off' });
  const problem  = h('p.form-problem', { hidden: true, role: 'alert' });
  const find     = button('Find my projects', check, { icon: 'magnifying-glass', kind: 'primary' });
  const progress = h('div');
  const found    = h('div');

  // Enter in either box does what the button does.
  for (const input of [email, password])
    input.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); check(); } });

  const form = h('form.form-grid', { onsubmit: e => e.preventDefault() },
    h('label', { for: ids.source }, 'Installation'), source,
    h('label', { for: ids.email }, 'Email address there'), email,
    h('label', { for: ids.password }, 'Password there'), password);

  function complain(message) {
    problem.textContent = message || '';
    problem.hidden = !message;
  }

  /** A wrong password, or too many of them, is said next to the form. */
  function failed(err) {
    if (err.code === 'wrong_credentials' || err.status === 429) { login = null; complain(err.message); }
    else showError(err);
  }

  /** Check the old email address and password, and list that account's projects. */
  async function check() {

    if (working) return;
    complain('');

    const attempt = typed();
    if (!source.value) return;
    if (!attempt) { complain('Enter the email address and password you used there.'); return; }

    working = true;
    find.disabled = true;
    fill(found, spinner('Checking...'));

    try {
      const data = await call('/api/legacy/list', attempt);
      login = attempt;
      list(data.projects);
    } catch (err) {
      fill(found);
      failed(err);
    } finally {
      working = false;
      find.disabled = false;
    }
  }

  /** What is typed in the form, if it is complete. */
  function typed() {
    const attempt = { source: source.value, email: email.value.trim(), password: password.value };
    return attempt.source && attempt.email.length >= 3 && attempt.password ? attempt : null;
  }

  /** Hand the server a list of projects to import. */
  async function start(projects, inflate = false, who = login) {
    if (working || !who || projects.length === 0) return;
    working = true;
    complain('');
    try {
      report(await call('/api/legacy/start', { ...who, projects, inflate }));
      login = who;
      fill(found);
      watchImport();
    } catch (err) { failed(err); }
    finally { working = false; }
  }

  /** The old account's projects, with a box to tick for each that can be imported. */
  function list(projects) {

    if (projects.length === 0) {
      fill(found, h('div.card', h('p.empty', 'That account has no projects to import.')));
      return;
    }

    const rows = projects.map(project => {
      const box = h('input', { type: 'checkbox', checked: project.status !== 'have', disabled: project.status === 'have',
        'aria-label': `Import ${project.title}` });
      return { project, box, row: h('tr',
        h('td', box),
        h('td', h('strong', project.title), ' ', h('span.hint', listText[project.status] || '')),
        h('td', project.created || ''),
        h('td', h('span.tag', project.level === 'editor' ? 'can edit' : 'can view'))) };
    });

    const open = rows.filter(r => !r.box.disabled);
    const all  = h('input', { type: 'checkbox', checked: true, 'aria-label': 'Select all',
      onchange: () => { for (const r of open) r.box.checked = all.checked; } });

    const go = button('Import selected', () => {
      if (running) { complain('An import is already running. Wait for it to finish, or cancel it.'); return; }
      start(open.filter(r => r.box.checked).map(r => r.project.id));
    }, { icon: 'file-import', kind: 'primary' });

    fill(found, h('div.card',
      h('h2', 'Your projects there'),
      h('p.hint', 'Each project is imported once. A project you could only view there, you can only view here; "Save a copy" makes one you can change.'),
      h('table.data.wrap', h('thead', h('tr', h('th', open.length > 1 ? all : ''), h('th', 'Project'), h('th', 'Created'), h('th', 'Access'))),
        h('tbody', rows.map(r => r.row))),
      h('div.card-actions', go,
        h('span.hint', 'The import runs in the background. You can keep working, or leave this page.'))));
  }

  /** The import that is running, or the last one that ran. */
  function drawProgress(status) {

    running = status.active;

    if (status.projects.length === 0) { fill(progress); return; }

    const scaling = status.projects.filter(p => p.state === 'needs_scaling');
    const left    = status.projects.filter(p => p.state === 'queued' || p.state === 'running').length;

    const scale = async () => {
      // The page was left since the import was started, and with it the password.
      const who = login || typed();
      if (!who) { complain('To import these, first enter your old email address and password again below.'); email.focus(); return; }
      const ok = await confirm(`Scale the counts of ${scaling.length === 1 ? `"${scaling[0].title}"` : `${scaling.length} projects`}?`,
        scaling[0].message, { ok: 'Scale and import' });
      if (ok) start(scaling.map(p => p.id), true, who);
    };

    fill(progress, h('div.card',
      h('h2', status.active ? `Importing from ${status.source}` : `Last import from ${status.source}`),
      status.active ? h('p.hint', { role: 'status' }, `${left} of ${status.projects.length} still to do. You can keep working, or leave this page.`) : null,
      h('table.data.wrap', h('tbody', status.projects.map(p => h('tr',
        h('td', p.state === 'running' ? icon('spinner', 'fa-spin') : icon(stateIcon[p.state] || 'circle')),
        h('td', h('strong', p.title), ' ',
          h('span', { class: p.state === 'failed' ? 'hint problem' : 'hint' },
            stateText[p.state] || p.state, p.state === 'failed' && p.message ? `: ${p.message}` : '')))))),
      h('div.card-actions',
        status.active ? button('Cancel', () => call('/api/legacy/cancel').then(report).catch(showError), { icon: 'ban' }) : null,
        !status.active && scaling.length ? button('Scale and import', scale, { icon: 'file-import' }) : null,
        !status.active && scaling.length ? h('span.hint', 'Scaling estimates whole-number counts. You are shown what that means first.') : null)));
  }

  fill(container, h('div.page.narrow',
    h('h1', 'Import from an older atima'),
    progress,
    h('div.card',
      h('p', 'If you had an account on an earlier version of this site, you can bring its projects into the account you are signed in with now.'),
      h('p.hint', 'Your old password is used to unlock your old projects while they are copied. It is not stored.'),
      form, problem,
      h('div.card-actions', find)),
    found));

  call('/api/legacy/sources')
    .then(data => fill(source, data.sources.map(s => h('option', { value: s.id }, s.label))))
    .catch(showError);

  watchers.add(drawProgress);
  watchImport();

  return {
    // The open project changing has nothing to do with this page.
    onBiom: () => {},
    destroy: () => { watchers.delete(drawProgress); login = null; password.value = ''; },
  };
}
