// Export a collection or Best Work: a sheet (same look as Settings) to choose all or the selected photos,
// frame or no frame, and a new folder (on the Desktop by default, named after the collection).
import { esc } from './ui.js';
import { frameSettings } from './store.js';
import { runExport } from './exporter.js';

let root = null;
const st = { name: '', all: [], sel: [], which: 'all', frame: true, parent: '~/Desktop', folder: '', job: null };

const CHECK = '<svg class="tick" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>';
function choice(attrs, on, title, detail) {
  return `<div class="g-row choice${on ? ' on' : ''}" ${attrs} role="radio" tabindex="0" aria-checked="${on}"><span class="rc radio${on ? ' on' : ''}" aria-hidden="true"></span>
    <div class="g-main"><div class="g-t">${title}</div>${detail ? `<div class="g-d">${detail}</div>` : ''}</div></div>`;
}
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const safe = s => String(s || '').replace(/[/:]/g, '-').trim();

/** job: {name, all: [photos], sel: [photos], run: ({items|null, dest, frame}) => job for runExport} */
export function openExportSheet(job) {
  Object.assign(st, { name: job.name, all: job.all, sel: job.sel.length > 1 ? job.sel : [], which: 'all', frame: !!frameSettings().enabled,
    parent: '~/Desktop', folder: safe(job.name) || 'Darkroom export', job });
  if (!root) {
    root = document.createElement('div');
    root.className = 'onb';
    root.innerHTML = '<div class="onb-scrim"></div><div class="onb-card exp-card" role="dialog" aria-modal="true" aria-labelledby="expTitle"></div>';
    document.body.appendChild(root);
    root.querySelector('.onb-scrim').onclick = close;
    root.addEventListener('click', onClick);
    root.addEventListener('input', e => { if (e.target.matches('[data-folder]')) { st.folder = e.target.value; syncPath(); } });
    root.addEventListener('keydown', e => {
      e.stopPropagation();
      if (e.key === 'Escape') { e.preventDefault(); close(); }
      else if (e.key === 'Enter') { e.preventDefault(); go(); }
      else if ((e.key === ' ') && e.target.matches('[role=radio]')) { e.preventDefault(); e.target.click(); }
    });
  }
  root.hidden = false;
  paint();
  requestAnimationFrame(() => root.querySelector('[data-act="export"]')?.focus());
}
export const exportSheetOpen = () => !!root && !root.hidden;
function close() { if (root) root.hidden = true; }

const count = () => (st.which === 'sel' ? st.sel : st.all).length;
const pathText = () => `${st.parent.replace(/\/$/, '')}/${safe(st.folder) || '…'}`;
function syncPath() {
  const p = root.querySelector('.exp-path'); if (p) p.textContent = pathText();
  const b = root.querySelector('[data-act="export"]'); if (b) b.disabled = !safe(st.folder) || !count();
}

function paint() {
  const card = root.querySelector('.onb-card');
  const which = st.sel.length
    ? `<h2 class="g-h">Photos</h2><div class="g" role="radiogroup" aria-label="Photos">${choice('data-which="all"', st.which === 'all', `All ${plural(st.all.length, 'photo')}`, '')}${choice('data-which="sel"', st.which === 'sel', `The ${st.sel.length} selected`, '')}</div>`
    : '';
  card.innerHTML = `<div class="onb-page settings exp">
      <div class="onb-shead"><h1 id="expTitle">Export “${esc(st.name)}”</h1><p class="exp-sub">${plural(count(), 'photo')}, finished in their edits, as full-size JPEGs.</p></div>
      <div class="onb-body">
        ${which}
        <h2 class="g-h">Frame</h2>
        <div class="g" role="radiogroup" aria-label="Frame">
          ${choice('data-frame="1"', st.frame, 'With a frame', 'A border around each photo, as set in the editor')}
          ${choice('data-frame="0"', !st.frame, 'No frame', 'The photo edge to edge')}
        </div>
        <h2 class="g-h">Save to a new folder</h2>
        <div class="g"><div class="g-row exp-dest">
          <div class="g-main"><input type="text" data-folder value="${esc(st.folder)}" aria-label="Folder name" spellcheck="false" autocomplete="off"><div class="g-d exp-path">${esc(pathText())}</div></div>
          ${window.photolab?.chooseFolder ? '<button class="btn quiet" data-act="choose">Choose…</button>' : ''}
        </div></div>
      </div>
    </div>
    <div class="onb-foot"><span class="grow"></span><button class="btn plain" data-act="cancel">Cancel</button><button class="btn primary" data-act="export"${safe(st.folder) && count() ? '' : ' disabled'}>Export</button></div>`;
}

async function onClick(e) {
  const t = e.target.closest('[data-which], [data-frame], [data-act]');
  if (!t) return;
  if (t.dataset.which) { st.which = t.dataset.which; paint(); return; }
  if (t.dataset.frame) { st.frame = t.dataset.frame === '1'; paint(); return; }
  const a = t.dataset.act;
  if (a === 'cancel') close();
  else if (a === 'export') go();
  else if (a === 'choose') {
    try {
      const r = await window.photolab.chooseFolder();
      const p = typeof r === 'string' ? r : r?.path;
      if (p) { st.parent = p; paint(); }
    } catch (_) { /* cancelled */ }
  }
}

function go() {
  if (!safe(st.folder) || !count()) return;
  const photos = st.which === 'sel' ? st.sel : st.all;
  const items = st.which === 'sel' ? photos.map(p => ({ projectId: p.pid, id: p.id })) : null;
  close();
  runExport(st.job.run({ items, dest: pathText(), frame: st.frame, count: photos.length }));
}
