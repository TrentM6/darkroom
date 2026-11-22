// "Update available": what the update contains, before you reload.
// changelog.json (next to index.html) is a newest-first array of {id: "yyyymmdd-hhmm", items: [...]}.
// At load the page remembers the newest id it was built with; when Baseline Darkroom.app signals an update
// (window.studio.updateAvailable), the notes newer than that id are shown with a Reload button.
import { esc } from './ui.js';
import { ICONS } from './icons.js';

const MAX_LINES = 6;
let loadedId = null;

async function fetchLog() {
  const r = await fetch('changelog.json', { cache: 'no-store' });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const j = await r.json();
  return Array.isArray(j) ? j.filter(e => e && typeof e.id === 'string' && Array.isArray(e.items)) : [];
}
const newest = log => log.reduce((m, e) => (m === null || e.id > m ? e.id : m), null);

export async function initUpdates() {
  try { loadedId = newest(await fetchLog()); } catch (_) { loadedId = null; }
  window.studio = Object.assign(window.studio || {}, { updateAvailable });
}

async function updateAvailable() {
  // Every real update adds a changelog entry; with nothing newer than what this page loaded, there is
  // nothing to reload for, so no notice.
  if (loadedId === null) { try { loadedId = newest(await fetchLog()); } catch (_) {} return; }
  let lines = [];
  try {
    lines = (await fetchLog()).filter(e => e.id > loadedId).sort((a, b) => (a.id < b.id ? 1 : -1)).flatMap(e => e.items.map(String));
  } catch (_) { return; }
  if (lines.length) show(lines);
}

function show(lines) {
  let el = document.getElementById('updatePanel');
  if (!el) {
    el = document.createElement('div');
    el.id = 'updatePanel';
    el.className = 'update-panel';
    el.setAttribute('role', 'status');
    document.body.appendChild(el);
  }
  const more = lines.length > MAX_LINES ? lines.length - MAX_LINES : 0;
  const list = lines.slice(0, more ? MAX_LINES - 1 : MAX_LINES);
  const rest = lines.length - list.length;
  el.innerHTML = `<div class="up-head"><span class="up-title">Update available</span>
      <button class="up-x" title="Later" aria-label="Later">${ICONS.close}</button></div>
    ${list.length ? `<ul class="up-list">${list.map(t => `<li>${esc(t)}</li>`).join('')}${rest ? `<li class="up-more">and ${rest} more</li>` : ''}</ul>` : ''}
    <div class="up-foot"><button class="btn primary up-reload">Reload</button></div>`;
  el.querySelector('.up-x').onclick = () => el.remove();
  el.querySelector('.up-reload').onclick = () => location.reload();
}
