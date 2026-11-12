// Sharing the open project with other people by name. Only on a server
// with accounts, and only for people who have signed in.
//
// Names, affiliations, email addresses and ORCID iDs come from the
// identity provider: they are inserted as text.

import { h, fill, icon, button, debounce } from '../dom.js';
import { call } from '../api.js';
import { confirm, showError, spinner } from '../widgets.js';
import { newShareLink, copyText, projectUrl, signIn, busy } from '../actions.js';
import * as store from '../store.js';

/** What tells two people of the same name apart: a partly hidden email, or an ORCID iD. */
function identifier(user) {
  if (user.orcid) return h('span.user-id', 'ORCID ', user.orcid);
  if (user.email) return h('span.user-id', user.email);
  return null;
}

function person(user) {
  return h('div.person',
    h('strong', user.full_name),
    user.affiliation ? h('span', user.affiliation) : null,
    identifier(user));
}

export function show(container) {

  if (!store.hasAccounts()) {
    fill(container, h('div.page.narrow', h('h1', 'Sharing'), h('p.empty', 'This copy of atima has no accounts, so there is nobody to share with.')));
    return {};
  }

  if (!store.hasAccount()) {
    fill(container, h('div.page.narrow',
      h('h1', 'Sharing'),
      h('div.card',
        h('p', 'Sign in to share projects with other people by name, and to keep your projects for longer than a guest can.'),
        h('div.card-actions', button('Sign in', signIn, { icon: 'right-to-bracket', kind: 'primary' })))));
    return {};
  }

  let   members = new Set();     // user ids that already have the project
  const people  = h('div');
  const results = h('div.search-results');
  const search  = h('input', { type: 'search', placeholder: 'Name, affiliation or email', 'aria-label': 'Find a person',
    oninput: debounce(find, 300) });

  async function update(user, permissions, question) {
    if (question && !await confirm(question.title, question.text, { ok: question.ok, danger: true })) return;
    const done = await busy('Updating...', () => call('/api/sharing/update', { user_id: user.user_id, permissions }));
    if (done) { load(); find(); }
  }

  async function load() {
    const biom = store.get('biom');
    fill(people, spinner('Loading...'));
    try {
      const data = await call('/api/sharing/list');
      const me   = store.get('conf').user_id;
      members = new Set([me, ...data.users.map(user => user.user_id)]);
      fill(people, data.users.length === 0 ? h('p.empty', 'Nobody has been given this project by name.') :
        h('table.data.people', h('tbody', data.users.map(user => h('tr',
          h('td', person(user), user.user_id === me ? h('span.tag', 'you') : null),
          h('td', biom.is_editor
            ? h('select', { 'aria-label': `Access for ${user.full_name}`,
                onchange: e => update(user, e.target.value) },
                h('option', { value: 'view', selected: !user.is_editor, disabled: biom.is_public }, 'Can view'),
                h('option', { value: 'edit', selected: user.is_editor }, 'Can edit'))
            : (user.is_editor ? 'Can edit' : 'Can view')),
          // A viewer can only take back view access (that they gave: the
          // server checks); an editor can remove anyone but the last editor.
          h('td', !biom.is_editor && user.is_editor ? null : button('', () => update(user, 'none', {
            title: `Take away ${user.full_name}'s access?`,
            text: ['They lose the project from their own list.',
                   'If they kept the share link, it still works until you make a new link.'],
            ok: 'Remove' }), { icon: 'user-minus', title: 'Remove access' }))))))); }
    catch (err) { showError(err); fill(people, h('p.empty', 'The list could not be loaded.')); }
  }

  async function find() {
    const query = search.value.trim();
    if (!query) { fill(results); return; }
    if (!/^[A-Za-z0-9@_ .-]+$/.test(query)) { fill(results, h('p.hint', 'Search with letters, digits, spaces and @ . - _ only.')); return; }
    try {
      const biom = store.get('biom');
      const data = await call('/api/sharing/user_search', { query });
      if (search.value.trim() !== query) return;
      // The search always offers its closest matches; leave out the people
      // who already have the project.
      const found = data.users.filter(user => !members.has(user.user_id));
      fill(results, found.length === 0 ? h('p.empty', 'Nobody else found.') : found.map(user => h('div.search-result',
        person(user),
        h('div.card-actions',
          biom.is_public ? null : button('Can view', () => update(user, 'view'), { icon: 'eye' }),
          biom.is_editor ? button('Can edit', () => update(user, 'edit'), { icon: 'pen' }) : null))));
    } catch (err) { showError(err); }
  }

  function draw() {
    const biom = store.get('biom');
    fill(container, h('div.page.narrow',
      h('div.page-head', h('h1', 'Sharing'), h('div.tags', h('span.tag', biom.title))),

      h('div.card',
        h('h2', 'People with access'),
        biom.is_public ? h('p.hint', 'This project is public: everyone can view it. Listed here are the people who can edit it.') : null,
        people),

      // Everyone can view a public project already, and only an editor
      // can let someone else edit it.
      biom.is_public && !biom.is_editor ? null : h('div.card',
        h('h2', 'Add someone'),
        h('p.hint', biom.is_editor
          ? 'Find a person who has signed in to this server before.'
          : 'As a viewer you can let other people view this project, and take that back.'),
        search, results),

      biom.access_key ? h('div.card',
        h('h2', 'Share link'),
        h('p.hint', 'Anyone who has this link can open and download the saved project, without signing in.'),
        h('div.link-row', h('code', projectUrl(biom.access_key)),
          button('', () => copyText(projectUrl(biom.access_key), 'Link copied.'), { icon: 'copy', title: 'Copy' }),
          biom.is_editor ? button('New link', newShareLink, { icon: 'rotate' }) : null)) : null));
    load();
  }

  draw();
  return { onBiom: draw };
}
