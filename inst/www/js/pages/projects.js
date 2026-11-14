// The project tree: the user's own projects in their collections (folders),
// and the public projects. Titles and collection names are plain text;
// descriptions are HTML the server sanitized.
//
// Node ids: C<n> a collection, P<n> a project in the user's own tree,
// G<n> a project in the public tree. "#" is the top of a tree.
//
// Everyone arranges their own tree. The public tree is arranged by
// administrators, through routes of its own (/api/public/...). Nobody else
// is shown those controls, and the server refuses them anyway.

import { h, fill, icon, button, serverHtml } from '../dom.js';
import { call } from '../api.js';
import { tabs, confirm, prompt, dialog, notify } from '../widgets.js';
import { uploadProject, openProject, reopenDefault, busy } from '../actions.js';
import * as store from '../store.js';

const isCollection = node => node.id.startsWith('C');
const byName = (a, b) => (isCollection(b) - isCollection(a)) || a.text.localeCompare(b.text, undefined, { numeric: true });
const nameCheck = text => (text.length < 3 || text.length > 100 ? 'A name has 3 to 100 characters.' : null);

/** A date the server sent ("2026-11-12 21:50:13", UTC) in the reader's own form. */
function when(utc) {
  if (!utc) return 'never';
  const d = new Date(String(utc).replace(' ', 'T') + 'Z');
  return Number.isNaN(d.getTime()) ? String(utc) : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

export function show(container) {

  let selected = null;       // {kind: 'private'|'public', id}
  const closed = new Set();  // collapsed collections

  const lists   = { private: h('div.tree', { role: 'tree' }), public: h('div.tree', { role: 'tree' }) };
  const details = h('div.card.details');

  const local = store.get('conf').auth === 'none';
  const panes = tabs([
    { id: 'private', label: local ? 'My projects' : 'My projects', icon: 'user', panel: h('div.pane', lists.private) },
    { id: 'public',  label: 'Public projects', icon: 'earth-americas', panel: h('div.pane', lists.public) },
  ]);

  const nodes    = kind => store.get('tree')[kind];
  const find     = (kind, id) => nodes(kind).find(n => n.id === id) || null;
  const setNodes = (kind, list) => store.set('tree', { ...store.get('tree'), [kind]: list });

  // May the caller create, rename, move and delete collections in this tree?
  const arranges = kind => kind === 'private' || !!store.get('conf').is_admin;
  const api      = kind => (kind === 'private' ? '/api/tree' : '/api/public');

  //___________________________________________________________________________
  // Drawing a tree

  function drawTree(kind) {
    const all  = nodes(kind);
    const ids  = new Set(all.map(n => n.id));
    const kids = parent => all.filter(n => (ids.has(n.parent) ? n.parent : '#') === parent).sort(byName);
    const open = store.get('biom').node_id;

    const branch = (parent, depth) => kids(parent).map(node => {
      const folder = isCollection(node);
      const shut   = closed.has(node.id);
      const row = h('div.tree-row', {
        role: 'treeitem', tabindex: 0, draggable: arranges(kind),
        class: [selected && selected.id === node.id ? 'selected' : '', node.id === open ? 'open' : ''].join(' '),
        style: { paddingLeft: `${depth * 18 + 8}px` },
        'aria-expanded': folder ? String(!shut) : null,
        onclick: () => { if (folder && selected && selected.id === node.id) toggle(node.id); select(kind, node.id); },
        ondblclick: () => { if (!folder) openProject(node.id); },
        onkeydown: e => {
          if (e.key === 'Enter') { if (folder) toggle(node.id); else openProject(node.id); }
        },
      },
        icon(folder ? (shut ? 'folder' : 'folder-open') : 'file-lines', 'tree-icon'),
        h('span.tree-text', node.text),
        !folder && node.id === open ? h('span.tag', 'open') : null,
        !folder ? h('span.tree-meta', `${node.info.n_samples} samples`) : null);

      if (arranges(kind)) {
        row.addEventListener('dragstart', e => { e.dataTransfer.setData('text/plain', node.id); e.dataTransfer.effectAllowed = 'move'; });
        if (folder) dropTarget(row, kind, node.id);
      }
      return [row, folder && !shut ? branch(node.id, depth + 1) : null];
    });

    const rows = branch('#', 0);
    fill(lists[kind], rows.length ? rows : h('p.empty', kind === 'private'
      ? 'You have no projects yet. Upload a BIOM file, or open a public project and save a copy.'
      : 'There are no public projects.'));
  }

  function toggle(id) { if (closed.has(id)) closed.delete(id); else closed.add(id); }

  /** Let a row (or the whole list, for the top level) take a dragged node of its own tree. */
  function dropTarget(el, kind, parentId) {
    el.addEventListener('dragover', e => {
      if (!arranges(kind)) return;
      e.preventDefault(); e.stopPropagation(); el.classList.add('drop');
    });
    el.addEventListener('dragleave', () => el.classList.remove('drop'));
    el.addEventListener('drop', e => {
      if (!arranges(kind)) return;
      e.preventDefault(); e.stopPropagation();
      el.classList.remove('drop');
      move(kind, e.dataTransfer.getData('text/plain'), parentId);
    });
  }
  dropTarget(lists.private, 'private', '#');
  dropTarget(lists.public, 'public', '#');

  function drawAll() { drawTree('private'); drawTree('public'); drawDetails(); }

  function select(kind, id) { selected = { kind, id }; drawAll(); }

  //___________________________________________________________________________
  // What can be done with the selected node

  // `kind` says which tree the node is in. A node dragged over from the
  // other tree is not found in this one, and nothing happens.
  async function move(kind, id, parentId) {
    const node = find(kind, id);
    if (!node || node.parent === parentId || id === parentId) return;
    const done = await busy('Moving...', () => call(`${api(kind)}/move`, { node_id: id, parent_node_id: parentId }));
    if (done) setNodes(kind, nodes(kind).map(n => (n.id === id ? { ...n, parent: parentId } : n)));
  }

  async function moveDialog(kind, node) {
    // A collection cannot go inside itself or one of its descendants.
    const inside = new Set([node.id]);
    let grew = true;
    while (grew) {
      grew = false;
      for (const n of nodes(kind)) if (isCollection(n) && inside.has(n.parent) && !inside.has(n.id)) { inside.add(n.id); grew = true; }
    }
    const target = h('select', h('option', { value: '#' }, 'Top level'),
      nodes(kind).filter(n => isCollection(n) && !inside.has(n.id)).sort(byName)
        .map(n => h('option', { value: n.id, selected: n.id === node.parent }, n.text)));
    const to = await dialog({
      title: `Move "${node.text}"`, body: [h('label', 'Into'), target],
      buttons: [{ label: 'Cancel', value: null }, { label: 'Move', kind: 'primary', value: () => target.value }] });
    if (to) move(kind, node.id, to);
  }

  async function newCollection(kind, parentId) {
    const title = kind === 'private' ? 'New collection' : 'New public collection';
    const text  = await prompt(title, { label: 'Name', value: 'New collection', ok: 'Create', check: nameCheck });
    if (!text) return;
    const done = await busy('Creating...', async () => {
      if (kind === 'public') return (await call('/api/public/create', { parent_node_id: parentId, text })).node;
      const made = await call('/api/tree/create', { node_id: parentId });
      if (text !== made.node.text) await call('/api/tree/rename', { node_id: made.node.id, text });
      return { id: made.node.id, parent: made.parent_id };
    });
    if (!done) return;
    setNodes(kind, [...nodes(kind), { id: done.id, parent: done.parent, text: done.text || text }]);
    closed.delete(parentId);
    panes.show(kind);
    select(kind, done.id);
  }

  async function rename(kind, node) {
    const text = await prompt(`Rename "${node.text}"`, { label: 'Name', value: node.text, ok: 'Rename', check: nameCheck });
    if (!text || text === node.text) return;
    const done = await busy('Renaming...', () => call(`${api(kind)}/rename`, { node_id: node.id, text }));
    if (!done) return;
    setNodes(kind, nodes(kind).map(n => (n.id === node.id ? { ...n, text } : n)));
    if (done.title) store.set('biom', { ...store.get('biom'), title: done.title });
  }

  async function remove(kind, node, route, title, lines, ok) {
    if (!await confirm(title, lines, { ok, danger: true })) return;
    const done = await busy('Removing...', () => call(route, { node_id: node.id }));
    if (!done) return;
    const wasOpen = node.id === store.get('biom').node_id;
    selected = null;
    setNodes(kind, nodes(kind).filter(n => n.id !== node.id));
    // The open project is no longer the user's: open whatever the server offers.
    if (wasOpen) { await reopenDefault(); notify('That project was open, so another one has been opened.', 'info'); }
  }

  function drawDetails() {

    const node = selected && find(selected.kind, selected.id);

    if (!node) {
      fill(details, h('p.empty', 'Select a project to see what is in it. Double-click a project to open it.'));
      return;
    }

    const kind = selected.kind;
    const own  = kind === 'private';

    if (isCollection(node)) {
      const empty = !nodes(kind).some(n => n.parent === node.id);
      fill(details,
        h('h2', icon('folder-open'), ' ', node.text),
        h('p.hint', own ? 'A collection of your projects. Drag projects and collections onto it to move them in.'
          : arranges(kind) ? 'A collection of public projects, which everyone sees. As an administrator you arrange the public list: drag public projects and collections onto it to move them in.'
          : 'A collection of public projects.'),
        arranges(kind) ? h('div.card-actions',
          button('Rename', () => rename(kind, node), { icon: 'pen' }),
          button('New collection inside', () => newCollection(kind, node.id), { icon: 'folder-plus' }),
          button('Move', () => moveDialog(kind, node), { icon: 'arrow-right-to-bracket' }),
          button('Delete', () => remove(kind, node, `${api(kind)}/delete`, `Delete the collection "${node.text}"?`, 'Only an empty collection can be deleted.', 'Delete'),
            { icon: 'trash', kind: 'danger', disabled: !empty, title: empty ? '' : 'Move its contents out first' })) : null);
      return;
    }

    const info   = node.info || {};
    const isOpen = node.id === store.get('biom').node_id;
    const facts  = [
      ['Samples', Number(info.n_samples).toLocaleString()],
      ['Taxa', Number(info.n_taxa).toLocaleString()],
      ['Median depth', Number(info.median_depth).toLocaleString()],
      ['Phylogenetic tree', info.has_tree ? 'yes' : 'no'],
      ['Created', when(info.created_utc)],
      own ? ['Last opened', when(info.viewed_utc)] : null,
      ['Your access', node.editor ? 'editor' : 'viewer'],
      ['Metadata', (info.meta_colnames || []).filter(c => c !== '.sample').join(', ') || 'none'],
    ].filter(Boolean);

    fill(details,
      h('h2', node.text),
      serverHtml(h('div.description'), info.description),
      h('dl.facts', facts.map(([k, v]) => [h('dt', k), h('dd', v)])),
      h('div.card-actions',
        button(isOpen ? 'Go to this project' : 'Open', () => openProject(node.id), { icon: 'arrow-right', kind: 'primary' }),
        own && node.editor ? button('Rename', () => rename(kind, node), { icon: 'pen' }) : null,
        // Where a project is listed in the public tree is the administrators' to say.
        arranges(kind) ? button('Move', () => moveDialog(kind, node), { icon: 'arrow-right-to-bracket' }) : null,
        own ? button('Remove from my projects', () => remove(kind, node, '/api/tree/leave',
          `Remove "${node.text}" from your projects?`,
          ['You give up your own access to it. Others who have the project keep it.',
           'If nobody else has it, the project is deleted.'], 'Remove'), { icon: 'right-from-bracket' }) : null,
        own && node.editor ? button('Delete', () => remove(kind, node, '/api/tree/delete',
          `Delete "${node.text}"?`,
          ['The project is taken away from everyone it is shared with, and then deleted. This cannot be undone.'], 'Delete for everyone'),
          { icon: 'trash', kind: 'danger' }) : null));
  }

  //___________________________________________________________________________

  fill(container, h('div.page',
    h('div.page-head',
      h('h1', 'Projects'),
      h('div.card-actions',
        button('Upload a BIOM file', uploadProject, { icon: 'upload', kind: 'primary' }),
        button('New collection', () => newCollection('private', '#'), { icon: 'folder-plus' }),
        arranges('public') ? button('New public collection', () => newCollection('public', '#'), { icon: 'folder-plus' }) : null)),
    h('div.projects', panes, details)));

  // Start on the tab that holds the open project.
  const openNode = store.get('biom').node_id;
  if (openNode.startsWith('G') || nodes('private').length === 0) panes.show('public');
  selected = { kind: openNode.startsWith('G') ? 'public' : 'private', id: openNode };
  drawAll();

  const off = store.on('tree', drawAll);
  return { onBiom: drawAll, destroy: off };
}
