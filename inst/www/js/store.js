// The application's state, in one place. Nothing else keeps a copy of what
// the server said: pages read from here and subscribe to the keys they show.
//
//   conf        who the browser is: {auth, user_id, full_name, is_guest, is_admin,
//               legacy}; on a shared server also {session_hours, guest_days}
//               and, when set, {operator, contact}
//   biom        the open project: title, keys, permissions, and the summary
//               of its data (fields, ranks, taxa, tree, depth, depth_options)
//   tree        the project tree: {public: [nodes], private: [nodes]}
//   schema      the answer of /api/schema, fetched once per page load
//   sessionKey  this tab's session key
//   shared      what the user changed in the controls, kept once for all rbiom
//               functions: {key: value}, the key naming a parameter and its
//               kind (see "Values shared between functions" in schema.js)
//   subset      which samples to keep: {cat: {field: [values]}, num: {field: [lo, hi]}}
//   save        image settings the user changed: {width, height, units, dpi, scale}
//   fit         size the figure to the window?
//   route       the page on screen: {page, arg}

import * as S from './schema.js';

const state = {
  conf: null, biom: null, tree: { public: [], private: [] }, schema: null, sessionKey: null,
  shared: {}, subset: { cat: {}, num: {} }, save: {}, fit: true, route: { page: 'home', arg: null },
};

const listeners = new Map();   // key -> Set of functions

/** Read a value. */
export function get(key) { return state[key]; }

/** Replace a value and tell whoever subscribed to it. */
export function set(key, value) {
  if (!(key in state)) throw new Error(`Unknown state key: ${key}`);
  const before = state[key];
  state[key] = value;
  for (const fn of [...(listeners.get(key) || [])]) fn(value, before);
}

/**
 * Subscribe to changes of one or more keys.
 * @return {function} Call it to unsubscribe.
 */
export function on(keys, fn) {
  keys = [].concat(keys);
  for (const key of keys) {
    if (!listeners.has(key)) listeners.set(key, new Set());
    listeners.get(key).add(fn);
  }
  return () => keys.forEach(key => listeners.get(key).delete(fn));
}

/** What the user changed, as it applies to one rbiom function (a schema entry). */
export function fnArgs(def) { return S.fnArgs(def, state.shared, state.biom); }

/**
 * Set (or with `undefined`, forget) one argument. The value is kept under
 * the parameter's shared key, so every function with that parameter has it.
 */
export function setArg(def, name, value) {
  const shared = { ...state.shared };
  const key    = S.shareKey(S.param(def, name));
  if (value === undefined) delete shared[key]; else shared[key] = value;
  set('shared', shared);
}

/** Forget what the user changed for every parameter of a function, wherever it is shared. */
export function resetArgs(def) {
  const shared = { ...state.shared };
  for (const p of def.params) delete shared[S.shareKey(p)];
  set('shared', shared);
}

/** May the caller do things only people with an account can? */
export function hasAccount() { return !!state.conf && !state.conf.is_guest; }

/** Does this server have accounts at all? */
export function hasAccounts() { return !!state.conf && state.conf.auth === 'oidc'; }
