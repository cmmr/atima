// Draft — not yet reviewed. The text below was drafted for Daniel to read
// and change; remove these two lines once he has.
//
// "Privacy and terms": what a shared server keeps about the people who use
// it, who can see what, and the terms of use. Only shown on a server with
// accounts (auth = "oidc"); a local install has nobody to tell.
//
// The text ships with the package, and other labs run it, so it describes
// what the software does and names nobody. Who runs this server and how to
// reach them come from the server's settings (`operator` and `contact` of
// run()), as do the two retention periods. Everything is inserted as text.
//
// Each statement was checked against the code when it was written. When the
// behaviour changes, change the sentence: R/cleanup.R (what is deleted and
// when), R/access.R (who can see what), R/permissions.r (what other users
// are shown), R/auth-oidc.R (what comes from the provider), R/router.R
// `request_done()` and R/errors.R `error_report()` (what is logged).

import { h, fill } from '../dom.js';
import * as store from '../store.js';

const count = (n, unit) => `${n} ${unit}${n === 1 ? '' : 's'}`;

/** The contact setting: a link if it is plainly a web address or an email address, else text. */
function contactLink(contact) {
  if (/^https?:\/\/[^\s<>"']+$/i.test(contact))
    return h('a', { href: contact, target: '_blank', rel: 'noopener noreferrer' }, contact);
  if (/^[^\s@<>"':/]+@[^\s@<>"':/]+\.[^\s@<>"':/]+$/.test(contact))
    return h('a', { href: 'mailto:' + contact }, contact);
  return contact;
}

const section = (title, ...body) => h('section.card', h('h2', title), body);
const list    = (...items) => h('ul', items.map(item => h('li', item)));

export function show(container) {

  const conf = store.get('conf');

  if (conf.auth !== 'oidc') {
    fill(container, h('div.page.narrow', h('h1', 'Privacy and terms'),
      h('p.empty', 'This copy of ATIMA runs on your own computer. Your data stays on it, and there is nobody else to share it with.')));
    return {};
  }

  const guestTime   = count(conf.guest_days, 'day');
  const sessionTime = count(conf.session_hours, 'hour');

  fill(container, h('div.page.narrow.terms',

    h('h1', 'Privacy and terms'),

    h('p', 'This page says what this server keeps about you and your data, who can see it, and on what terms you may use the server. ',
      'It describes what the ATIMA software does.'),

    conf.operator ? h('p', 'This server is run by ', conf.operator, '.') : null,
    conf.contact  ? h('p', 'For questions, or to have your account or your data removed, contact: ', contactLink(conf.contact)) : null,

    section('What is stored',
      list(
        ['Your data. The files you upload, and what ATIMA makes from them: the saved project (its title, description and a rarefied copy of the counts), ',
         'your working copy while you have changes that are not saved, results kept so that they need not be computed twice, and the figures and exports you ask for.'],
        ['Who you are, if you sign in. Your name, your email address and your affiliation if the sign-in provider sends them, and the provider\'s identifier for you. ',
         'They are received from the sign-in provider each time you sign in. ATIMA keeps no passwords, and never sees the one you use with the provider.'],
        'What you can open. Which projects you have access to, who gave you that access, and when you last opened each project.',
        'Your open browser tabs. For each one, the network address the server saw it come from and the time it was last heard from.'),
      h('p', 'One cookie identifies your browser, so that the server knows which projects are yours. A second cookie exists only while you are signing in, for ten minutes at most. ',
        'There are no advertising or tracking cookies, and the pages of this server load nothing from other sites. ',
        'Signing in takes your browser to the sign-in provider, which has terms of its own.')),

    section('If you do not sign in',
      h('p', 'You can use this server without signing in. What you upload is then tied to the cookie in your browser. ',
        `It is deleted ${guestTime} after your last visit, unless somebody else has been given the project. `,
        'If you sign in from the same browser, it becomes yours and is kept.')),

    section('How long things are kept',
      list(
        `Changes you have not saved are deleted when their browser tab has been closed, or not heard from, for ${sessionTime}. Signing in or out also discards them.`,
        `Figures and exports are temporary files. They are deleted ${sessionTime} after they were made.`,
        'Saved projects of people who have signed in are kept until they are deleted. A project is deleted once nobody has it among their own projects and it is not public.',
        'What is deleted here can remain for longer in copies of the database that are made before an upgrade, and in backups made by whoever runs the server.')),

    section('Who can see a project',
      list(
        'A project is private until you share it or publish it.',
        ['Share link. Every project has a link with a random key in it. Anyone who has the link can open the project and download its data, without signing in, ',
         'and the project is added to their own list. "New link" on the Sharing page replaces the key, so that every link handed out before stops working.'],
        ['Sharing by name. If you have signed in, you can give other people who have signed in view or edit access to a project. ',
         'People who can edit a project can change it, share it and publish it. People who can view it can let others view it.'],
        ['Being found. Anyone who has signed in can search for other people who have signed in, in order to share with them. ',
         'They see your name, your affiliation, and your email address with most of it hidden; for someone who signs in with ORCID, the ORCID iD in place of an email address.'],
        ['The administrators of this server cannot open your private projects in the app. ',
         'Whoever runs the server can reach everything that is stored on it.'])),

    section('Public projects',
      list(
        'Anyone who has signed in and can edit a project can publish it.',
        ['A public project can be opened and downloaded by everyone, signed in or not. ',
         'It is listed with its title, its description, the names of its metadata columns and the name of the person who created it.'],
        'Public projects are not reviewed or moderated before they appear.',
        'The administrators of this server may edit or unpublish any public project, and arrange the public list.'),
      h('p', h('strong', 'Do not upload or publish data that you are not allowed to share. Do not upload anything that identifies people: data from human subjects must be de-identified before it is uploaded.'))),

    section('The server log',
      h('p', 'The server writes a line to its log for every request: what kind of request it was, whether it succeeded, how long it took, and the number that stands for the user. ',
        'It does not log what requests contain: not your files, your settings or your results. ',
        'When a request fails, technical details of the error are logged too, and these can include values from that request. ',
        'Signing in and signing out are logged.')
      // Step 12 (usage monitoring) adds its paragraph HERE: what use of the
      // server is recorded, in what form, and for how long.
    ),

    // Step 11 (the MCP server on shared servers) adds a section HERE, "AI
    // apps", once shared servers offer it: that the results of tool calls
    // are handed to the AI app, and so go to that app's provider. Today the
    // /mcp route exists only on local installs, so there is nothing to say.

    conf.legacy ? section('Importing from an older ATIMA',
      h('p', 'If you import your projects from an older ATIMA, the email address and password you type are used to find your old projects and to decrypt them. ',
        'The password is held in memory only while your import runs. It is never stored and never written to the log.')) : null,

    section('Terms of use',
      list(
        'This service is provided as it is, without warranty of any kind.',
        'It may be interrupted, changed or shut down, and data may be lost. Keep your own copies of your data and of the results you rely on.',
        'It is for research. Do not use its results to diagnose or treat patients, or for any other clinical decision.',
        'You are responsible for what you upload, share and publish.',
        'By using this server you accept these terms.'))));

  return {};
}
