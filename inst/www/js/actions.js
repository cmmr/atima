// Things the user can do to the open project or their account from more
// than one page: upload, save, publish, a new share link, sign in and out.

import { h, fill, icon, button, serverHtml, newId } from './dom.js';
import { call, startSession, ApiError } from './api.js';
import { dialog, confirm, notify, showError } from './widgets.js';
import * as store from './store.js';

/** Go to a page of the app. */
export function go(hash) { window.location.hash = hash; }

/** The address of the open project, with a key that is safe to show. */
export function projectUrl(key) { return `${window.location.origin}/${key}`; }

/** Let the user choose a file. Resolves to a File, or null. */
export function chooseFile(accept = '') {
  return new Promise(resolve => {
    const input = h('input', { type: 'file', accept, style: { display: 'none' } });
    input.addEventListener('change', () => { resolve(input.files[0] || null); input.remove(); });
    input.addEventListener('cancel', () => { resolve(null); input.remove(); });
    document.body.append(input);
    input.click();
  });
}

/** Run something slow behind a "busy" notice; report failures. Resolves to its result, or null. */
export async function busy(message, work) {
  const note = notify(message, 'info', { ms: 0 });
  note.classList.add('working');
  try { return await work(); }
  catch (err) { showError(err); return null; }
  finally { note.remove(); }
}

/**
 * Upload a BIOM file as a new project and open it.
 *
 * A file whose counts are not whole numbers is refused with the code
 * `confirm_inflate` and an explanation of what scaling them does. The user
 * is shown it; if they agree the same file is sent again with `inflate`.
 */
export async function uploadProject(file = null) {

  // Called with a file that was dropped on the page, or from a button.
  if (!(file instanceof File)) file = await chooseFile();
  if (!file) return;

  const send = inflate => {
    const form = new FormData();
    form.append('biom_file', file, file.name);
    if (inflate) form.append('inflate', 'true');
    return call('/api/project/upload', {}, { form });
  };

  const note = notify(`Uploading ${file.name}...`, 'info', { ms: 0 });
  note.classList.add('working');

  try {
    try { await send(false); }
    catch (err) {
      if (!(err instanceof ApiError) || err.code !== 'confirm_inflate') throw err;
      const agreed = await confirm('These counts are not whole numbers', err.message, { ok: 'Scale the counts and import' });
      if (!agreed) return;
      await send(true);
    }
    notify(`"${store.get('biom').title}" was imported.`, 'ok');
    go('#/summary');
  }
  catch (err) { showError(err); }
  finally { note.remove(); }
}

/** Replace the working copy's metadata, taxonomy or tree with a file. */
export async function uploadComponent(component) {
  const file = await chooseFile();
  if (!file) return;
  const form = new FormData();
  form.append('component', component);
  form.append('component_file', file, file.name);
  const done = await busy(`Reading ${file.name}...`, () => call('/api/project/upload_component', {}, { form }));
  if (done) notify(`The ${component} was replaced in your working copy. Save to keep it.`, 'ok');
}

/** A small rich-text box for descriptions. The server sanitizes what it is sent. */
function descriptionEditor(html) {
  const box = serverHtml(h('div.rich-text', { contentEditable: 'true', role: 'textbox', 'aria-multiline': 'true', 'aria-label': 'Description' }), html);
  const cmd = (name, arg) => () => { box.focus(); document.execCommand(name, false, arg); };
  const bar = h('div.rich-bar',
    button('', cmd('bold'), { icon: 'bold', title: 'Bold' }),
    button('', cmd('italic'), { icon: 'italic', title: 'Italic' }),
    button('', cmd('insertUnorderedList'), { icon: 'list-ul', title: 'List' }),
    button('', () => {
      const url = window.prompt('Link address (https://...)');
      if (url && /^(https?:\/\/|mailto:)/i.test(url)) cmd('createLink', url)();
    }, { icon: 'link', title: 'Link' }));
  return { el: h('div.rich', bar, box), html: () => box.innerHTML };
}

/**
 * Save the working copy over the project, or (with `copy`) as a new private
 * project. The same dialog is where a project's title and description are
 * changed; `details` opens it for that, worded accordingly.
 */
export async function saveProject({ copy = false, details = false } = {}) {

  const biom  = store.get('biom');
  const id    = newId('title');
  const title = h('input', { id, type: 'text', maxLength: 100, value: copy ? `Copy of ${biom.title}`.slice(0, 100) : biom.title });
  const desc  = descriptionEditor(biom.description);

  const ok = await dialog({
    title: copy ? 'Save a copy' : details ? 'Edit title and description' : 'Save project',
    wide: true,
    body: [
      h('p.hint', copy
        ? 'The copy is a new private project of yours, made from your working copy.'
        : !details ? 'This replaces the saved project with your working copy.'
        : biom.is_saved ? 'This changes the saved project\'s title and description.'
        : 'Your working copy has changes that are not saved. Saving the title and description saves those changes too.'),
      h('label', { for: id }, 'Title'), title,
      h('label', 'Description'), desc.el ],
    buttons: [
      { label: 'Cancel', value: false },
      { label: copy ? 'Save a copy' : 'Save', kind: 'primary', value: true,
        validate: () => (title.value.trim().length < 3 ? 'The title needs at least 3 characters.' : null) } ],
  });
  if (!ok) return;

  const done = await busy('Saving...', () => call(copy ? '/api/project/save_as' : '/api/project/save',
    { title: title.value.trim(), description: desc.html() }));
  if (done) {
    // The tree shows titles too.
    const b = store.get('biom'), tree = store.get('tree');
    store.set('tree', { public: tree.public, private: tree.private.map(n =>
      (n.id === b.node_id ? { ...n, text: b.title, info: { ...n.info, description: b.description } } : n)) });
    notify(copy ? 'Saved as a new project.' : 'Saved.', 'ok');
  }
}

/** Publish, change or unpublish the open project. For signed-in editors. */
export async function publishProject() {

  const biom = store.get('biom');
  const tree = store.get('tree');
  const mine = biom.access_key !== null;

  const keyId = newId('key'), colId = newId('col');
  const key = h('input', { id: keyId, type: 'text', maxLength: 20, value: biom.public_key || '', placeholder: 'e.g. gut-study-2026', autocomplete: 'off' });

  const current = (tree.public.find(n => n.id === biom.node_id || n.info && n.info.access_key === biom.public_key) || {}).parent;
  const collection = h('select', { id: colId },
    h('option', { value: '' }, 'Top of the public list'),
    tree.public.filter(n => n.id.startsWith('C')).map(n =>
      h('option', { value: n.id.slice(1), selected: n.id === current }, n.text)));

  const choice = await dialog({
    title: biom.is_public ? 'Public project' : 'Publish this project',
    body: [
      h('p', 'A public project can be opened and downloaded by anyone who visits this server. It appears in the public list as soon as you publish it.'),
      h('label', { for: keyId }, 'Public address'),
      h('div.control-pair', h('span.unit', `${window.location.origin}/`), key),
      h('p.hint', '4 to 20 lower-case letters, digits and hyphens.'),
      h('label', { for: colId }, 'List it under'), collection,
      biom.is_public && !mine ? h('p.warning', icon('triangle-exclamation'),
        ' If nobody has this project among their own projects, unpublishing leaves it with no owner and it will be deleted.') : null ],
    buttons: [
      { label: 'Cancel', value: null },
      biom.is_public ? { label: 'Unpublish', value: 'unpublish', kind: 'danger' } : null,
      { label: biom.is_public ? 'Update' : 'Publish', value: 'publish', kind: 'primary',
        validate: () => (/^[a-z0-9][a-z0-9-]{2,18}[a-z0-9]$/.test(key.value.trim()) ? null
          : 'The address needs 4 to 20 lower-case letters, digits and hyphens, starting and ending with a letter or digit.') },
    ].filter(Boolean),
  });
  if (!choice) return;

  if (choice === 'unpublish') {
    const sure = await confirm('Unpublish this project?',
      'It will no longer be in the public list, and its public address will stop working. Share links keep working.',
      { ok: 'Unpublish', danger: true });
    if (!sure) return;
  }

  const body = choice === 'unpublish' ? { is_public: false } : { is_public: true, public_key: key.value.trim() };
  if (choice === 'publish' && collection.value) body.collection_id = Number(collection.value);

  const done = await busy('Updating...', () => call('/api/project/publish', body));
  if (done) notify(choice === 'unpublish' ? 'The project is private again.' : 'The project is public.', 'ok');
}

/** Replace the project's share link. Every older link stops working. */
export async function newShareLink() {
  const sure = await confirm('Make a new share link?', [
    'Every link to this project that was handed out before will stop working, for everyone.',
    'People you shared the project with by name keep their access.' ], { ok: 'Make a new link', danger: true });
  if (!sure) return;
  const done = await busy('Making a new link...', () => call('/api/project/new_key'));
  if (!done) return;
  const biom = store.get('biom');
  store.set('biom', { ...biom, access_key: done.access_key, project_key: biom.is_public ? biom.project_key : done.access_key });
  notify('The old links no longer work.', 'ok');
}

/** Copy text to the clipboard. */
export async function copyText(text, what = 'Copied.') {
  try { await navigator.clipboard.writeText(text); notify(what, 'ok', { ms: 2500 }); }
  catch (err) { notify('Copying is not allowed here; select the text and copy it yourself.', 'error'); }
}

/** Go to the sign-in page. Unsaved changes do not survive it, so ask first. */
export async function signIn() {
  const biom = store.get('biom');
  if (biom && !biom.is_saved) {
    const sure = await confirm('Sign in now?',
      'Your working copy has changes that are not saved. They are lost when you sign in. Save a copy first to keep them.',
      { ok: 'Sign in anyway', danger: true });
    if (!sure) return;
  }
  const here = /^\/[A-Za-z0-9-]{0,40}$/.test(window.location.pathname) ? window.location.pathname : '/';
  window.location.assign('/auth/login?return_to=' + encodeURIComponent(here));
}

/** Sign out, then load the page again as a guest. */
export async function signOut() {
  const biom = store.get('biom');
  if (biom && !biom.is_saved) {
    const sure = await confirm('Sign out now?', 'Your working copy has changes that are not saved. They are lost when you sign out.',
      { ok: 'Sign out anyway', danger: true });
    if (!sure) return;
  }
  try { await call('/api/account/sign_out'); } catch (err) { /* signed out or not, start again */ }
  window.location.assign('/');
}

/** Open another project from the tree. */
export async function openProject(nodeId) {
  const done = await busy('Opening...', () => call('/api/tree/select', { node_id: nodeId }));
  if (done) go('#/summary');
  return !!done;
}

/** After the open project was removed from the user's tree: open whatever the server offers. */
export async function reopenDefault() {
  window.history.replaceState(null, '', '/' + window.location.hash);
  try { await startSession(); } catch (err) { showError(err); }
}
