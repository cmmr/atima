// "Connected apps": the AI apps that use ATIMA for this person, and what
// they changed.
//
// On a server with accounts a person approves each app when it first
// connects (the approval page is the server's own, /oauth/authorize), and
// this page lists those connections with a control to end each. On a copy
// without accounts there is nothing to approve: any app that is given the
// address is let in, so the page only says so.
//
// Either way the page shows the record of every change an app made through
// a tool: when, which app, which tool, which project, and what changed.
//
// App names come from the apps themselves, and project titles from users:
// everything is inserted as text.

import { h, fill, icon, button } from '../dom.js';
import { call } from '../api.js';
import { confirm, showError, spinner, notify } from '../widgets.js';
import { copyText, signIn, busy } from '../actions.js';
import * as store from '../store.js';

const DOCS_URL = 'https://cmmr.github.io/atima/articles/ai-apps.html';

/** A time the server sent ("2026-11-12 21:50:13", UTC) in the reader's own form. */
function when(utc, { time = false } = {}) {
  if (!utc) return 'never';
  const d = new Date(String(utc).replace(' ', 'T') + 'Z');
  if (Number.isNaN(d.getTime())) return String(utc);
  const date = d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  return time ? `${date}, ${d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}` : date;
}

export function show(container) {

  const conf   = store.get('conf');
  const shared = conf.auth === 'oidc';
  const title  = shared ? 'Connected apps' : 'AI apps';

  if (shared && conf.is_guest) {
    fill(container, h('div.page.narrow',
      h('h1', title),
      h('div.card',
        h('p', 'Sign in to connect an AI app to your projects. An app works for one person, with what that person may do.'),
        h('div.card-actions', button('Sign in', signIn, { icon: 'right-to-bracket', kind: 'primary' })))));
    return {};
  }

  const apps    = h('div');
  const changes = h('div');

  async function disconnect(app) {
    const sure = await confirm(
      app ? `Disconnect ${app.name}?` : 'Disconnect every app?',
      [app ? 'The app can no longer use ATIMA for you. To use it again, connect it again from the app.'
           : 'No app can use ATIMA for you any more. To use one again, connect it again from the app.',
       'What it has changed stays as it is.'],
      { ok: 'Disconnect', danger: true });
    if (!sure) return;
    const done = await busy('Disconnecting...', () => call('/api/apps/disconnect', app ? { grant_id: app.grant_id } : {}));
    if (done) { notify(done.disconnected === 1 ? 'The app is disconnected.' : `${done.disconnected} apps are disconnected.`, 'ok'); load(); }
  }

  function drawApps(list) {
    if (!shared) { fill(apps); return; }
    fill(apps, h('div.card',
      h('div.card-head', h('h2', 'Apps that can use ATIMA as you'),
        list.length > 1 ? button('Disconnect all', () => disconnect(null), { icon: 'plug-circle-xmark', kind: 'danger' }) : null),
      list.length === 0 ? h('p.empty', 'No app is connected.') :
        h('div.table-scroll', h('table.data.apps',
          h('thead', h('tr', h('th', 'App'), h('th', 'It may'), h('th', 'Connected'), h('th', 'Last used'), h('th', ''))),
          h('tbody', list.map(app => h('tr',
            h('td', h('strong', app.name), ' ', h('span.hint', app.host)),
            h('td', app.writes ? h('span.tag.warn', 'read and change') : h('span.tag', 'read')),
            h('td', when(app.created_utc)),
            h('td', { title: `If it is not used, the connection ends on ${when(app.expires_utc)}.` }, when(app.used_utc)),
            h('td', button('Disconnect', () => disconnect(app), { icon: 'plug-circle-xmark', title: `Disconnect ${app.name}` })))))))));
  }

  function drawChanges(list) {
    fill(changes, h('div.card',
      h('h2', 'What apps changed'),
      h('p.hint', 'Every change an app made through ATIMA: uploads, edits, copies, sharing, publishing and deleting. Reading and analysing are not listed. ',
        'A deleted project can be restored from "Deleted" on the Projects page.'),
      list.length === 0 ? h('p.empty', 'No app has changed anything.') :
        h('div.table-scroll', h('table.data.wrap.changes',
          h('thead', h('tr', h('th', 'When'), h('th', 'What changed'), h('th', 'Project'), h('th', 'App'), h('th', 'Tool'))),
          h('tbody', list.map(c => h('tr',
            h('td', when(c.made_utc, { time: true })),
            h('td', c.summary),
            h('td', c.project || ''),
            h('td', c.app),
            h('td', h('code', c.tool)))))))));
  }

  async function load() {
    fill(changes, spinner('Loading...'));
    try {
      const data = await call('/api/apps/list');
      drawApps(data.apps);
      drawChanges(data.changes);
    } catch (err) { showError(err); fill(changes, h('p.empty', 'The list could not be loaded.')); }
  }

  const may = conf.mcp_writes
    ? 'see your projects, run analyses and, if you let it, upload, change, share, publish and delete projects'
    : 'see your projects and run analyses. It cannot change anything: that is switched off on this server';

  fill(container, h('div.page.narrow',

    h('h1', title),

    h('div.card',
      h('h2', 'Connect an app'),
      shared
        ? h('p', `In the AI app, add a connector (an MCP server) with the address below. The app sends you here to sign in and to approve it, and you choose what it may do. An app can ${may}.`)
        : h('p', `Give an AI app on this computer the address below, as an MCP server. There is nothing to approve: any app that has the address can ${conf.mcp_writes
            ? 'see, change and delete your projects' : 'see your projects and run analyses, and cannot change anything'}.`),
      h('div.link-row', h('code', conf.mcp_url),
        button('', () => copyText(conf.mcp_url, 'Address copied.'), { icon: 'copy', title: 'Copy' })),
      h('p.hint', 'What an app reads from your projects is passed to the company that provides the app, under that company\'s terms. ',
        h('a', { href: DOCS_URL, target: '_blank', rel: 'noopener noreferrer' }, 'How to connect an app, and what it can do'), '.')),

    apps, changes));

  load();
  return {};
}
