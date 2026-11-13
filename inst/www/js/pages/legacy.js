// Importing projects from an older atima. The administrator has saved the
// old installation's database; a signed-in person proves who they were
// there with their old email address and password, and picks the projects
// to bring over.
//
// The old password is needed for every request (the old projects are
// encrypted with it), so it is kept in this page's memory until the page
// is left, and nowhere else. Project titles come from the old database:
// they are inserted as text.

import { h, fill, icon, button, newId } from '../dom.js';
import { call } from '../api.js';
import { confirm, showError, spinner, notify } from '../widgets.js';
import { signIn } from '../actions.js';
import * as store from '../store.js';

const statusText = {
  new:    '',
  shared: 'Someone you shared it with has imported it. You will be added to their copy.',
  have:   'Already in your projects.',
};

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
  let working = false;

  const ids      = { source: newId('legacy'), email: newId('legacy'), password: newId('legacy') };
  const source   = h('select', { id: ids.source });
  const email    = h('input', { id: ids.email, type: 'email', autocomplete: 'off', spellcheck: false });
  const password = h('input', { id: ids.password, type: 'password', autocomplete: 'off' });
  const problem  = h('p.form-problem', { hidden: true, role: 'alert' });
  const find     = button('Find my projects', check, { icon: 'magnifying-glass', kind: 'primary' });
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

  /** Check the old email address and password, and list that account's projects. */
  async function check() {

    if (working) return;
    complain('');

    const attempt = { source: source.value, email: email.value.trim(), password: password.value };
    if (!attempt.source) return;
    if (attempt.email.length < 3 || !attempt.password) { complain('Enter the email address and password you used there.'); return; }

    working = true;
    find.disabled = true;
    fill(found, spinner('Checking...'));

    try {
      const data = await call('/api/legacy/list', attempt);
      login = attempt;
      list(data.projects);
    } catch (err) {
      login = null;
      fill(found);
      // A wrong password, or too many of them: say so next to the form.
      if (err.code === 'wrong_credentials' || err.status === 429) complain(err.message);
      else showError(err);
    } finally {
      working = false;
      find.disabled = false;
    }
  }

  /** The old account's projects, with a box to tick for each that can be imported. */
  function list(projects) {

    if (projects.length === 0) {
      fill(found, h('div.card', h('p.empty', 'That account has no projects to import.')));
      return;
    }

    const rows = projects.map(project => {
      const box  = h('input', { type: 'checkbox', checked: project.status !== 'have', disabled: project.status === 'have',
        'aria-label': `Import ${project.title}` });
      const note = h('span.hint', statusText[project.status] || '');
      const row  = h('tr',
        h('td', box),
        h('td', h('strong', project.title), ' ', note),
        h('td', project.created || ''),
        h('td', h('span.tag', project.level === 'editor' ? 'can edit' : 'can view')));
      return { project, box, note, row };
    });

    const go       = button('Import selected', () => run(rows, go), { icon: 'file-import', kind: 'primary' });
    const progress = h('p.hint', { role: 'status' });

    fill(found, h('div.card',
      h('h2', 'Your projects there'),
      h('p.hint', 'Each project is imported once. A project you could only view there, you can only view here; "Save a copy" makes one you can change.'),
      h('table.data.wrap', h('thead', h('tr', h('th', ''), h('th', 'Project'), h('th', 'Created'), h('th', 'Access'))),
        h('tbody', rows.map(r => r.row))),
      h('div.card-actions', go, progress)));

    rows.progress = progress;
  }

  /** Import one project; ask first if its counts need scaling. */
  async function importOne(project) {
    const args = { ...login, project: project.id };
    try { return await call('/api/legacy/import', args); }
    catch (err) {
      if (err.code !== 'confirm_inflate') throw err;
      const ok = await confirm(`Scale the counts of "${project.title}"?`, err.message, { ok: 'Scale and import' });
      if (!ok) return null;
      return call('/api/legacy/import', { ...args, inflate: true });
    }
  }

  /** Import the ticked projects, one after another. */
  async function run(rows, go) {

    const chosen = rows.filter(r => r.box.checked && !r.box.disabled);
    if (working || !login || chosen.length === 0) return;

    working = true;
    go.disabled = find.disabled = true;

    let done = 0;

    for (const [i, r] of chosen.entries()) {

      rows.progress.textContent = `Importing ${i + 1} of ${chosen.length}: ${r.project.title}`;
      fill(r.note, icon('spinner', 'fa-spin'), ' Importing...');

      try {
        const data = await importOne(r.project);
        if (!data) { fill(r.note, 'Skipped.'); continue; }
        done += 1;
        r.box.checked = false;
        r.box.disabled = true;
        fill(r.note, icon('circle-check'), data.status === 'imported' ? ' Imported.' : data.status === 'added' ? ' Added to your projects.' : ' Already in your projects.');
      } catch (err) {
        fill(r.note, icon('triangle-exclamation'), ' ', err.message || 'Could not be imported.');
        r.note.classList.add('problem');
        // Locked out, or the password no longer accepted: the rest would fail too.
        if (err.code === 'wrong_credentials' || err.status === 429) { complain(err.message); break; }
      }
    }

    rows.progress.textContent = '';
    working = false;
    go.disabled = find.disabled = false;

    if (done > 0) notify(`${done} project${done === 1 ? '' : 's'} added. They are under Projects.`, 'ok');
  }

  fill(container, h('div.page.narrow',
    h('h1', 'Import from an older atima'),
    h('div.card',
      h('p', 'If you had an account on an earlier version of this site, you can bring its projects into the account you are signed in with now.'),
      h('p.hint', 'Your old password is used to unlock your old projects while they are copied. It is not stored.'),
      form, problem,
      h('div.card-actions', find)),
    found));

  call('/api/legacy/sources')
    .then(data => fill(source, data.sources.map(s => h('option', { value: s.id }, s.label))))
    .catch(showError);

  return {
    // The open project changing has nothing to do with this page.
    onBiom: () => {},
    destroy: () => { login = null; password.value = ''; },
  };
}
