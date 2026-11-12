// Talking to the server. Every request goes through call(), which adds the
// session key, starts a new session when the old one has expired (401), and
// puts what the server says about the session into the store.

import * as store from './store.js';

/** A failed request: `status`, the server's `message`, error `id` and `code`. */
export class ApiError extends Error {
  constructor(status, message, { id = null, code = null } = {}) {
    super(message);
    this.status = status;
    this.id     = id;
    this.code   = code;
  }
  /** Replaced by a newer request, cancelled, or stopped by the user: nothing to show. */
  get superseded() { return this.status === 409 || this.status === 0; }
}

let lastRequest = Date.now();
let starting    = null;    // the session start in progress, if any

/** The project key in the page's address: "/hmp50" -> "hmp50". */
export function urlKey() {
  const key = window.location.pathname.replace(/^\/+|\/+$/g, '');
  return /^[A-Za-z0-9-]{1,40}$/.test(key) ? key : '';
}

/** Put what a response says about the session into the store. */
function absorb(data) {
  if (!data || typeof data !== 'object') return;
  if (data.CONF) store.set('conf', data.CONF);
  if (data.tree) store.set('tree', data.tree);
  if (data.tree_node) {
    const tree = store.get('tree');
    const rest = tree.private.filter(node => node.id !== data.tree_node.id);
    store.set('tree', { public: tree.public, private: [...rest, data.tree_node] });
  }
  if (data.BIOM) store.set('biom', data.BIOM);
}

async function send(path, { body = {}, form = null, signal = null, keepalive = false } = {}) {

  const headers = {};
  const key = store.get('sessionKey');
  if (key)   headers['x-session-key'] = key;
  if (!form) headers['Content-Type']  = 'application/json';

  lastRequest = Date.now();

  let resp;
  try {
    resp = await fetch(path, {
      method: 'POST', headers, signal, keepalive, credentials: 'same-origin',
      body: form || JSON.stringify(body) });
  } catch (err) {
    if (err.name === 'AbortError') throw new ApiError(0, 'Stopped.');
    throw new ApiError(-1, 'The server could not be reached. Is it still running?');
  }

  let data = null;
  try { data = await resp.json(); } catch (err) { /* not JSON: handled below */ }

  if (!resp.ok) {
    const e = (data && data.error) || {};
    throw new ApiError(resp.status, e.message || `The server answered ${resp.status}.`, e);
  }

  const newKey = resp.headers.get('x-session-key');
  if (newKey) store.set('sessionKey', newKey);

  return data;
}

/**
 * Start this tab's session. The server decides who the browser is (by its
 * cookie) and which project to open (the key in the address, else the last
 * one viewed, else the first public one).
 */
export function startSession() {
  if (!starting) {
    store.set('sessionKey', null);
    const key = urlKey();
    starting = send('/api/session/init', { body: key ? { access_key: key } : {} })
      .then(data => { absorb(data); return data; })
      .finally(() => { starting = null; });
  }
  return starting;
}

/**
 * Call an API route.
 * @param {string} path     e.g. "/api/plot"
 * @param {object} [body]   The arguments, sent as JSON.
 * @param {object} [opts]   `form`: a FormData to send instead (uploads);
 *                          `signal`: an AbortSignal.
 * @return {Promise<object>} The response. Throws an ApiError otherwise.
 */
export async function call(path, body = {}, opts = {}) {
  if (starting) await starting.catch(() => {});
  try {
    const data = await send(path, { body, ...opts });
    absorb(data);
    return data;
  } catch (err) {
    // The session is gone (24 idle hours, or a sign-in or sign-out in
    // another tab). Start a new one and try once more.
    if (err.status !== 401 || opts.retried) throw err;
    await startSession();
    return call(path, body, { ...opts, retried: true });
  }
}

/** The schema of rbiom's functions; the same for every project. */
export async function loadSchema() {
  const schema = await send('/api/schema');
  store.set('schema', schema);
  return schema;
}

/** Cancel this tab's jobs on the server (the stop button). */
export function abortJobs() {
  return call('/api/session/abort').catch(() => {});
}

/** Tell the server the page is going away, so its jobs do not run on. */
function abortOnUnload() {
  const key = store.get('sessionKey');
  if (!key) return;
  fetch('/api/session/abort', {
    method: 'POST', keepalive: true, credentials: 'same-origin', body: '{}',
    headers: { 'Content-Type': 'application/json', 'x-session-key': key } }).catch(() => {});
}

/**
 * Keep the session alive while the tab is open but idle: the server forgets
 * a session it has not heard from for a day. Any request counts, so a
 * heartbeat is only sent after a quiet spell.
 */
export function startHeartbeat(minutes = 10) {
  const ms = minutes * 60 * 1000;
  setInterval(() => {
    if (Date.now() - lastRequest >= ms && store.get('sessionKey'))
      call('/api/session/heartbeat').catch(() => {});
  }, 60 * 1000);
  window.addEventListener('pagehide', abortOnUnload);
}
