// When a figure is drawn: after every change of its controls, or only
// when the user asks. This file decides what the plot page shows in each
// situation and remembers the choice. It is pure (no page, no imports),
// so the tests can run it; `pages/plot.js` does the drawing.

/** The name the choice is stored under in the browser. */
export const AUTO_KEY = 'atima.autoRender';

/** Read the stored choice. Drawing automatically is the default. */
export function readAuto(storage) {
  try { return storage.getItem(AUTO_KEY) !== 'off'; } catch { return true; }
}

/** Store the choice. A browser without storage does not remember it. */
export function writeAuto(storage, auto) {
  try { storage.setItem(AUTO_KEY, auto ? 'on' : 'off'); } catch { /* not remembered */ }
}

/** What a change of a control leads to: a new figure, or a figure marked as older than its settings. */
export function onChange(auto) { return auto ? 'draw' : 'mark'; }

/**
 * Is the figure on screen older than the settings? `drawn` and `current`
 * are the requests, as text, of the figure shown and of the controls now.
 * Putting a control back makes the figure current again.
 */
export function isStale(drawn, current) { return drawn !== null && drawn !== current; }

/** While a figure is on its way the server is asked where it stands, this often. */
export const ASK_SECONDS = 2;

/** After this many seconds a figure is slow, and the render box says what the user can do meanwhile. */
export const SLOW_SECONDS = 8;

const LEAVE = 'The address of this page keeps these settings. You can leave, or bookmark it, and come back: the figure is then drawn again.';

/**
 * What the render box says while a figure is on its way: that it is being
 * drawn or, when every worker of the server is busy, its place in the queue.
 *
 * @param {string} label         the figure's name
 * @param {object|null} status   the server's word on the request (/api/plot/status):
 *                               {state: 'queued', place, waiting}, {state: 'running'}
 *                               or {state: 'none'}; null before it was asked
 * @param {number} seconds       how long the figure has been waited for
 * @return {{heading, hint}}
 */
export function progress(label, status, seconds) {
  const queued = !!status && status.state === 'queued' && Number.isInteger(status.place) && status.place >= 1;
  if (queued) {
    const of = Math.max(status.place, Number.isInteger(status.waiting) ? status.waiting : 0);
    return {
      heading: `Waiting: place ${status.place} of ${of} in the queue`,
      hint: `The server is drawing other figures first. ${LEAVE}` };
  }
  return { heading: `Drawing: ${label}`, hint: seconds >= SLOW_SECONDS ? LEAVE : '' };
}

/**
 * What the plot page shows.
 *
 * @param {boolean} auto      draw after every change?
 * @param {boolean} busy      is a figure being drawn?
 * @param {boolean} drawn     is there a figure on screen?
 * @param {boolean} stale     is it older than the settings?
 * @param {boolean} complete  can the settings be drawn (nothing required is missing)?
 * @param {boolean} message   is a message shown in place of the figure?
 * @param {boolean} held      is the mouse over the render box, or the keyboard in it?
 * @return {{box, heading, hint, button, canRender, dim, download, note}}
 *   box       the render box, over the middle of the figure: 'center' while
 *             there is something to say; 'held' when there no longer is but
 *             the user is at the box, which then stays, without the veil
 *             over the figure, until they leave it; else 'hidden'
 *   heading   its first line, or '' for none
 *   hint      a second line, or ''
 *   button    'stop' while a figure is drawn, else 'render': the box
 *             always has the one or the other
 *   canRender is the Render button enabled? Not while there is nothing
 *             to render: the figure is up to date
 *   dim       is the figure greyed out?
 *   download  is the Download button enabled?
 *   note      is "settings changed" shown above the statistics and the code?
 */
export function view({ held = false, ...now }) {
  const v = rest(now);
  if (v.box === 'hidden' && held) { v.box = 'held'; if (drawnNow(now)) v.heading = 'The figure is up to date'; }
  return v;
}

/** Is the figure on screen the one the settings ask for? */
function drawnNow({ drawn, stale, message = false }) { return drawn && !stale && !message; }

function rest({ auto, busy, drawn, stale, complete, message = false }) {

  if (busy) return {
    box: 'center', heading: '', hint: '', button: 'stop', canRender: false,
    dim: true, download: auto, note: !auto && drawn };

  // Nothing is in progress, and every change draws: as it always was.
  // Render is of use only after Stop, when the figure is not the
  // settings'.
  if (auto) return {
    box: 'hidden', heading: '', hint: '', button: 'render', canRender: complete && (!drawn || stale),
    dim: false, download: complete, note: false };

  // The middle of the figure holds a message (settings to complete, or
  // an error): the box leaves it readable.
  if (message || !complete) return {
    box: 'hidden', heading: '', hint: '', button: 'render', canRender: complete,
    dim: drawn, download: false, note: drawn };

  if (!drawn) return {
    box: 'center', heading: 'Not drawn yet', button: 'render', canRender: complete,
    hint: complete ? 'Press Render to draw this figure.' : '',
    dim: false, download: false, note: false };

  if (stale) return {
    box: 'center', heading: 'Settings changed', button: 'render', canRender: complete,
    hint: complete ? 'The figure shown is older than its settings. Press Render to update it.' : '',
    dim: true, download: false, note: true };

  // The figure matches its settings: nothing to say, and nothing to
  // render. The box comes back with the next change of a control.
  return {
    box: 'hidden', heading: '', hint: '', button: 'render', canRender: false,
    dim: false, download: complete, note: false };
}
