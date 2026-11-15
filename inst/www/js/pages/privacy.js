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
// `request_done()` and R/errors.R `error_report()` (what is logged),
// R/usage.R and inst/sql/008_usage.sql (what use is recorded), and for AI
// apps the files named above that section.

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
        'Saved projects of people who have signed in are kept until they are deleted. A project is erased once nobody has it among their own projects and it is not public.',
        `A project that somebody deletes is kept for ${count(conf.trash_days, 'day')}, during which the people who could edit it can restore it, and is then erased.`,
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
        'Signing in and signing out are logged, and so are connecting and disconnecting an AI app and each change an app makes.')),

    // Checked against R/usage.R: `usage_write()` (what is written),
    // `usage_visitor_hash()` (the daily hash), `usage_expire()` (how long),
    // and R/usage-report.R (what administrators are shown).
    conf.usage ? section('How use of this server is counted',
      h('p', 'This server counts how it is used, so that the people who run it can say how many researchers it serves, for example when they apply for funding, and can tell when it needs more capacity. ',
        'No cookie is set for this, and nothing is sent to another company or site.'),
      list(
        ['What you do. For each action, such as opening the site, drawing a figure, running a statistic, uploading or exporting: the time, the number that stands for you, ',
         'whether you used the browser or an AI app (and the app\'s name), the kind of action, the name of the analysis function, whether it succeeded and how long it took. ',
         'Not recorded: which project, your files, your settings, field names, titles, or anything else from your data.'],
        ['Where you came from. When you open the site: the country and the organisation that owns the network you connected from (such as a university or an internet provider), ',
         'looked up from your network address in a file on this server, and the address of the page that linked you here if you followed a link from another site. ',
         'The network address itself is not kept with these counts.'],
        ['If you have signed in, the organisation your sign-in provider names for you is counted with the number that stands for you.'],
        ['Requests without a cookie, such as a download by link from a script, are counted by a code made from the network address, the name of the program and a secret that is replaced every day and never stored. ',
         'The code cannot be turned back into an address, and is deleted after two days.'],
        [`How long. The record of single actions and visits is deleted after ${count(conf.usage_months, 'month')}. Daily counts made from it are kept: `,
         'how many people were active, from which countries and organisations, which analyses were run, and for each number that stands for a person, the days on which it was active.'],
        ['Who sees it. Only the administrators of this server, as counts and charts. They are not shown names, email addresses or what any one person did.'])) : null,

    // Checked against R/oauth.R (what a connection is and how long it
    // lasts), R/mcp-tools.R and R/mcp-write.R (what an app can do),
    // R/apps.R (the record of changes) and R/mcp-upload.R.
    section('AI apps',
      h('p', 'You can connect an AI app, such as a chat assistant, to this server, so that it works with your projects when you ask it to. ',
        'Nothing is connected unless you do it: the app sends you to this server, you sign in, and you approve that app.'),
      list(
        ['What an app can do. An app acts as you, with what you may do and no more. When you approve it you choose whether it may only see your projects and run analyses, ',
         conf.mcp_writes
           ? 'or may also upload files and change, copy, share, publish and delete your projects.'
           : 'which is all an app can do on this server: changing data through an app is switched off here.'],
        ['Where your data goes. What an app reads is handed to the app: titles and descriptions, the names and values of metadata, taxon names, statistics, figures and exported files. ',
         "Most apps send all of it to the company that provides them, where that company's terms decide what happens to it. ",
         'Do not connect an app to data that may not leave this server that way.'],
        ['What is stored. For each app you connect: its name, the address it gave for itself, what you let it do, and when it was connected and last used. ',
         'The keys the app uses are stored in a form from which they cannot be read back.'],
        ["The record of changes. Every change an app makes is recorded with the time, the app, the kind of change, the project's title and one sentence saying what changed. ",
         'You can read it under "Connected apps" in your account menu. A row is kept for a year.'],
        [`How long. An app stays connected until it has not been used for ${count(conf.app_days, 'day')}, or until you disconnect it under "Connected apps". `,
         'Signing out of this site in your browser does not disconnect your apps.'],
        ['Links in what an app is given. Figures, tables and exports are given to an app as links. Whoever has such a link can fetch the file, without signing in, ',
         `until it is deleted ${sessionTime} after it was made. Treat a conversation that contains such links as you would the files.`],
        ['Text in a project can be written to mislead an app, for example a description that tells it to share or delete something. ',
         'ATIMA hands such text to the app as data and tells it to treat it as data, but an app can still be misled. ',
         'With projects from other people, including public ones, let an app change things only if it asks you first.'])),

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
