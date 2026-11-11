// The account control in the page header: "Sign in" for a guest, the user's
// name and "Sign out" for someone who has signed in, and nothing at all when
// the server runs without accounts (auth = "none").
//
// This is the minimum needed to sign in and out. It starts a session of its
// own to learn who the browser is; the application's state store (renovation
// step 7) should take that over and call renderAccount() with its session.

const control = document.getElementById('account-control');

async function post(path, sessionKey, body = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (sessionKey) headers['x-session-key'] = sessionKey;
  return fetch(path, { method: 'POST', headers, body: JSON.stringify(body), credentials: 'same-origin' });
}

function button(label, onClick) {
  const el = document.createElement('button');
  el.className = 'btn-sm';
  el.textContent = label;
  el.addEventListener('click', onClick);
  return el;
}

export function renderAccount(conf, sessionKey) {

  control.replaceChildren();

  // No accounts on this server: no account control.
  if (conf.auth !== 'oidc') return;

  if (conf.is_guest) {
    control.append(button('Sign in', () => {
      const here = window.location.pathname.match(/^\/[A-Za-z0-9-]{0,40}$/) ? window.location.pathname : '/';
      window.location.assign('/auth/login?return_to=' + encodeURIComponent(here));
    }));
    return;
  }

  // The name comes from the identity provider: insert it as text, never as HTML.
  const name = document.createElement('span');
  name.className = 'text-sm text-on-primary/70';
  name.textContent = conf.full_name;

  control.append(name, button('Sign out', async () => {
    await post('/api/account/sign_out', sessionKey);
    window.location.reload();
  }));
}

async function start() {

  if (!control) return;

  const key  = window.location.pathname.replace(/^\/|\/$/g, '');
  const resp = await post('/api/session/init', null, key ? { access_key: key } : {});
  if (!resp.ok) return;

  const data = await resp.json();
  renderAccount(data.CONF, resp.headers.get('x-session-key'));
}

start();
