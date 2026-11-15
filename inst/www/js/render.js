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

/**
 * What the plot page shows.
 *
 * @param {boolean} auto      draw after every change?
 * @param {boolean} busy      is a figure being drawn?
 * @param {boolean} drawn     is there a figure on screen?
 * @param {boolean} stale     is it older than the settings?
 * @param {boolean} complete  can the settings be drawn (nothing required is missing)?
 * @param {boolean} message   is a message shown in place of the figure?
 * @return {{box, heading, hint, button, canRender, dim, download, note}}
 *   box       where the render box is: 'hidden', 'center' (over the figure)
 *             or 'corner' (out of the figure's way)
 *   heading   its first line, or '' for none
 *   hint      a second line, or ''
 *   button    'stop', 'render' or null
 *   canRender is the Render button enabled?
 *   dim       is the figure greyed out?
 *   download  is the Download button enabled?
 *   note      is "settings changed" shown above the statistics and the code?
 */
export function view({ auto, busy, drawn, stale, complete, message = false }) {

  if (busy) return {
    box: 'center', heading: '', hint: '', button: 'stop', canRender: false,
    dim: true, download: auto, note: !auto && drawn };

  // Nothing is in progress, and every change draws: as it always was.
  if (auto) return {
    box: 'hidden', heading: '', hint: '', button: null, canRender: false,
    dim: false, download: complete, note: false };

  // The middle of the figure holds a message (settings to complete, or
  // an error): the box leaves it readable.
  if (message || !complete) return {
    box: 'corner', heading: '', hint: '', button: 'render', canRender: complete,
    dim: drawn, download: false, note: drawn };

  if (!drawn) return {
    box: 'center', heading: 'Not drawn yet', button: 'render', canRender: complete,
    hint: complete ? 'Press Render to draw this figure.' : '',
    dim: false, download: false, note: false };

  if (stale) return {
    box: 'center', heading: 'Settings changed', button: 'render', canRender: complete,
    hint: complete ? 'The figure shown is older than its settings. Press Render to update it.' : '',
    dim: true, download: false, note: true };

  // The figure matches its settings: the box steps aside.
  return {
    box: 'corner', heading: '', hint: '', button: 'render', canRender: complete,
    dim: false, download: complete, note: false };
}
