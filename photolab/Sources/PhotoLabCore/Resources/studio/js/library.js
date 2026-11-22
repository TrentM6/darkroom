// Projects: every shoot from the attached folders, as cards. Attach, rename, locate, remove.
// Baseline Darkroom never copies photos: projects point at the user's own folders.
import { api, P } from './api.js';
import { store, loadLibrary, on, emit } from './store.js';
import { $, esc, setImg, toast, openMenu, dialog, plural } from './ui.js';
import { icon } from './icons.js';
import { go, current } from './router.js';

let pollTimer = null;
let ticks = 0;
let openWhenReady = null;
const progress = new Map();   // pid -> {done, total}

let lastSig = '';
const sigOf = lib => JSON.stringify([(lib?.projects || []).map(p => [p.id, p.name, p.count, p.picks, p.favorites, p.status, p.cover, p.date, p.missing]),
  (lib?.sources || []).map(s => [s.id, s.name]), lib?.engine?.paused || null, lib?.bestCount,
  lib?.engine?.problem || null, (lib?.engine?.failing || 0) >= 3]);
async function idleRefresh() {
  if (document.hidden) return;
  try {
    const j = await api.get(P.library());
    const sig = sigOf(j);
    if (sig === lastSig) return;
    await loadLibrary();
  } catch (_) { /* offline for a moment */ }
}

export function initLibrary() {
  setInterval(idleRefresh, 5000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) idleRefresh(); });
  on('library', lib => { lastSig = sigOf(lib); });
  $('#attachBtn').onclick = attachFolder;
  $('#attachBtn2').onclick = attachFolder;
  on('library', render);
  initLibraryDrag();
  // Hooks for the Mac app shell (File > Attach Folder…, drag and drop, folder events).
  window.studio = Object.assign(window.studio || {}, {
    attached: r => {
      rawOnlyNote(r);
      const ids = r?.projectIds || (r?.projects ? r.projects.map(p => p.id ?? p) : r?.projectId ? [r.projectId] : []);
      openWhenReady = ids.length === 1 ? ids[0] : null;
      refresh();
    },
    attachPath: path => attachPath(path),
    refresh,
    openProject: pid => go(`/p/${encodeURIComponent(pid)}`),
  });
}

export async function showLibrary() { await refresh(); }

export async function refresh() {
  try { await loadLibrary(); } catch (err) { toast("Couldn't load projects"); }
}

const isBusy = p => p.status && !['ready', 'missing', 'error'].includes(p.status);

function fmtDate(d) {
  if (!d) return '';
  const t = new Date(String(d).length === 10 ? d + 'T12:00:00' : d);
  return isNaN(t) ? String(d) : t.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

// Projects grouped by source folder, loose folders last. Within each, the photographer's order: the
// server sends `projects` already sorted (projectSort: newest, oldest, name or custom).
export function groupedProjects() {
  const lib = store.library || {};
  // Darkroom's own link folders (behind a collection, e.g. one rebuilt from Lightroom) aren't listed as projects.
  const projects = (lib.projects || []).filter(p => !p.linked);
  // A single attached shoot folder (kind "folder") needs no heading of its own.
  const sources = (lib.sources || []).filter(s => s.kind !== 'folder');
  const sid = p => p.sourceId ?? p.source_id ?? null;
  const groups = sources.map(s => ({ source: s, projects: projects.filter(p => sid(p) === s.id) }));
  const loose = projects.filter(p => !sources.some(s => s.id === sid(p)));
  if (loose.length) groups.push({ source: null, projects: loose });
  return groups;
}

// The library is patched in place: cards are kept per project (their cover <img> is never re-created),
// and only the text, progress and cover URL that changed are touched. Polls and refreshes therefore
// never rebuild the list, which keeps WebKit from re-decoding and flashing the covers.
const cardEls = new Map();      // project id -> card element
const extraEls = new Map();     // heading / empty-line key -> element

function render() {
  const groups = groupedProjects();
  const all = groups.flatMap(g => g.projects);
  const empty = $('#libEmpty'); if (empty.hidden !== all.length > 0) empty.hidden = all.length > 0;
  const showHeads = groups.length > 1 || (groups[0] && groups[0].source);
  const nodes = [], live = new Set();
  const extra = (key, cls, text, tag = 'div') => {
    let el = extraEls.get(key);
    if (!el) { el = document.createElement(tag); el.className = cls; extraEls.set(key, el); }
    if (el.textContent !== text) el.textContent = text;
    nodes.push(el);
    return el;
  };
  // The Sort menu sits beside the first section header (or in the top bar when there are no headers).
  const sort = sortControl();
  groups.forEach((g, i) => {
    if (showHeads) {
      const key = 'r:' + i + ':' + (g.source ? g.source.id : '');
      let row = extraEls.get(key);
      if (!row) { row = document.createElement('div'); row.className = 'lib-hrow'; row.innerHTML = '<h2 class="lib-h"></h2>'; extraEls.set(key, row); }
      const t = g.source ? g.source.name : 'Folders', h = row.firstChild;
      if (h.textContent !== t) h.textContent = t;
      if (i === 0 && sort.parentNode !== row) row.appendChild(sort);
      nodes.push(row);
    }
    for (const p of g.projects) {
      const id = String(p.id);
      let el = cardEls.get(id);
      if (!el) { el = makeCard(); cardEls.set(id, el); }
      fillCard(el, p);
      live.add(id);
      nodes.push(el);
    }
    if (g.source && !g.projects.length) extra('n:' + g.source.id, 'lib-none', 'No photos');
  });
  for (const id of [...cardEls.keys()]) if (!live.has(id)) cardEls.delete(id);
  if (!showHeads && sort.parentNode !== $('#libSortSlot')) $('#libSortSlot').appendChild(sort);
  $('#libSortSlot').hidden = !!showHeads || !all.length;
  syncSort();
  const grid = $('#libGrid'), kids = grid.children;
  const same = kids.length === nodes.length && nodes.every((n, i) => kids[i] === n);
  if (!same) grid.replaceChildren(...nodes);
  schedulePoll();
}

function makeCard() {
  const card = document.createElement('div');
  card.className = 'card';
  card.tabIndex = 0;
  card.innerHTML = `<div class="cover"><img alt="" loading="lazy"><span class="slot-progress"></span><span class="slot-missing"></span>
      <button class="more" title="More">${icon('more')}</button></div>
    <div class="meta"><div class="name"></div></div>
    <div class="sub"></div>`;
  const P_ = () => card._p;
  card.onclick = e => {
    if (e.target.closest('.more, input') || justDragged) return;
    if (e.target.closest('.locate')) return locate(P_());
    open(P_());
  };
  card.onkeydown = e => { if (e.key === 'Enter' && e.target === card) open(P_()); };
  card.oncontextmenu = e => { e.preventDefault(); menu(P_(), card, e.clientX, e.clientY); };
  card.querySelector('.more').onclick = e => { e.stopPropagation(); const r = e.currentTarget.getBoundingClientRect(); menu(P_(), card, r.left, r.bottom + 4); };
  card.querySelector('.name').ondblclick = e => { e.stopPropagation(); rename(P_(), card); };
  return card;
}

const setHTML = (el, html) => { if (el._html !== html) { el._html = html; el.innerHTML = html; } };
const setText = (el, t) => { if (el && el.textContent !== t) el.textContent = t; };

function fillCard(card, p) {
  card._p = p;
  const busy = isBusy(p), missing = p.status === 'missing';
  if (card.dataset.id !== String(p.id)) card.dataset.id = String(p.id);
  card.classList.toggle('missing', missing);
  const pr = progress.get(p.id) || { done: p.done || 0, total: p.total || p.count || 0 };
  setHTML(card.querySelector('.slot-progress'), busy ? `<div class="progress"><span class="ptext"></span><div class="pbar"><i></i></div></div>` : '');
  if (busy) {
    setText(card.querySelector('.ptext'), progressText(pr, p.status));
    const bar = card.querySelector('.pbar i'), w = pct(pr) + '%';
    if (bar.style.width !== w) bar.style.width = w;
  }
  setHTML(card.querySelector('.slot-missing'), missing ? `<div class="missing-veil"><span>Folder missing</span><button class="btn locate">Locate…</button></div>` : '');
  // A date only when it comes from the photos or the folder name, never from file times.
  const date = p.date && p.dateSource !== 'file' ? fmtDate(p.date) : '';
  setText(card.querySelector('.name'), p.name || '');
  setText(card.querySelector('.sub'), [date, plural(p.count ?? 0, 'photo'), p.picks ? plural(p.picks, 'select') : ''].filter(Boolean).join(' · '));
  setImg(card.querySelector('.cover img'), p.cover ? api.url(p.cover) : '');
}

const pct = pr => pr.total ? Math.round(pr.done / pr.total * 100) : 4;
const paused = () => !!store.library?.engine?.paused;
const progressText = (pr, status) => pr.paused || paused() ? 'Paused: disk full'
  : status === 'rendering' ? 'Rendering…'
  : status === 'updating' ? (pr.total ? `Adding ${pr.done} / ${pr.total}` : 'Adding…')
  : pr.total ? `Analyzing ${pr.done} / ${pr.total}` : 'Analyzing…';

function open(p) {
  if (p.status === 'missing') return locate(p);
  go(`/p/${encodeURIComponent(p.id)}`);
}

export function projectMenu(p, x, y, card) {
  openMenu(x, y, [
    { label: 'Open', disabled: p.status === 'missing', run: () => open(p) },
    { label: 'Rename', disabled: !card, run: () => card && rename(p, card) },
    { label: 'Show in Finder', disabled: !(p.path || p.source) || p.status === 'missing', run: () => reveal(p.path || p.source) },
    ...(p.status === 'missing' ? [{ label: 'Locate…', run: () => locate(p) }] : []),
    // Your own order: one step at a time, within the project's section (the keyboard alternative to dragging).
    ...(store.library?.projectSort === 'custom' ? (() => {
      const sec = sectionOf(p.id), i = sec.indexOf(String(p.id));
      return ['-', { label: 'Move Up', disabled: i <= 0, run: () => moveTo(p.id, sec[i - 1], false) },
        { label: 'Move Down', disabled: i < 0 || i >= sec.length - 1, run: () => moveTo(p.id, sec[i + 1], true) }];
    })() : []),
    '-',
    { label: 'Remove from Baseline Darkroom…', danger: true, run: () => remove(p) },
  ]);
}
const menu = (p, card, x, y) => projectMenu(p, x, y, card);

export function reveal(path) {
  api.post(P.reveal(), { path }).catch(() => toast("Couldn't show the folder"));
}

function rename(p, card) {
  const nameEl = card.querySelector('.name');
  const input = document.createElement('input');
  input.className = 'rename'; input.value = p.name; input.spellcheck = false;
  nameEl.replaceWith(input);
  input.focus(); input.select();
  let done = false;
  const finish = async save => {
    if (done) return; done = true;
    const v = input.value.trim();
    input.replaceWith(nameEl);
    if (save && v && v !== p.name) {
      p.name = v;
      try { await api.patch(P.project(p.id), { name: v }); } catch (_) { toast("Couldn't rename"); }
      return refresh();
    }
    render();
  };
  input.onkeydown = e => { e.stopPropagation(); if (e.key === 'Enter') finish(true); if (e.key === 'Escape') finish(false); };
  input.onblur = () => finish(true);
}

async function remove(p) {
  const ok = await dialog({ title: `Remove “${p.name}” from Baseline Darkroom?`, text: 'The photos stay on disk.', ok: 'Remove Project', danger: true });
  if (!ok) return;
  try { await api.del(P.project(p.id)); } catch (_) { toast("Couldn't remove project"); }
  refresh();
}

export async function locate(p) {
  let path = null;
  const native = window.photolab;
  try {
    if (native && typeof native.locateFolder === 'function') {
      const r = await native.locateFolder(p.id);
      if (r && typeof r === 'object' && r.ok) return refresh();   // the shell re-pointed it itself
      path = typeof r === 'string' ? r : r?.path;
      if (!path) return;
    }
  } catch (_) {}
  if (!path) {
    const v = await dialog({ title: `Locate “${p.name}”`, fields: [{ type: 'text', name: 'path', value: p.path || '', placeholder: 'Folder path' }], ok: 'Locate' });
    if (!v || !v.path) return;
    path = v.path;
  }
  try { await api.post(P.locate(p.id), { path }); toast('Folder found', { ms: 2000 }); }
  catch (err) { toast(err.message && err.message.length < 80 ? err.message : 'Choose the folder with these photos'); }
  refresh();
}

// ---------- Attach ----------
// Subfolders with only RAW files make no project: the server says which, and the photographer is told.
function rawOnlyNote(j) {
  if (j?.rawOnlyMessage) toast(j.rawOnlyMessage, { ms: 12000 });
}

export async function attachFolder() {
  try {
    const native = window.photolab;
    if (native && typeof native.attachFolder === 'function') {
      const r = await native.attachFolder();
      if (typeof r === 'string') return attachPath(r);
      if (r && r.path && !r.projectId && !r.projectIds && !r.projects && !r.source) return attachPath(r.path);
      if (r) window.studio.attached(r);
      return;
    }
    const mh = window.webkit?.messageHandlers?.photolab;
    if (mh) { mh.postMessage({ action: 'attachFolder' }); return; }
  } catch (err) { console.warn(err); }
  const v = await dialog({ title: 'Attach Folder', fields: [{ type: 'text', name: 'path', placeholder: '~/Pictures/Shoots' }], ok: 'Attach' });
  if (v && v.path) attachPath(v.path);
}

async function attachPath(path) {
  if (current().view !== 'library') go('/');
  try {
    const j = await api.post(P.sources(), { path });
    const ids = j.projectIds || (j.projects ? j.projects.map(p => p.id) : j.projectId ? [j.projectId] : []);
    openWhenReady = ids.length === 1 ? ids[0] : null;
    if (j.existing) toast('Already attached', { ms: 2000 });
    rawOnlyNote(j);
    await refresh();
  } catch (err) {
    // (a folder of only RAW files explains itself: "Test RAW: 6 RAW files and no JPEG or TIFF. …")
    toast(err.message && err.message.length < 200 ? err.message : "Couldn't attach that folder", { ms: 9000 });
  }
}

function schedulePoll() {
  clearTimeout(pollTimer);
  const busy = (store.library?.projects || []).filter(isBusy);
  if (!busy.length) return;
  pollTimer = setTimeout(async () => {
    let anyReady = false;
    for (const p of busy) {
      try {
        const s = await api.get(P.status(p.id));
        progress.set(p.id, { done: s.done || 0, total: s.total || 0, paused: !!s.paused });
        if (['ready', 'done', 'error', 'failed', 'missing'].includes(s.state)) {
          anyReady = true;
          if (openWhenReady === p.id && current().view === 'library') { openWhenReady = null; setTimeout(() => open(p), 50); }
        }
        updateCard(p.id);
      } catch (_) { /* keep polling */ }
    }
    // Photos appear progressively: refresh covers and counts every few seconds.
    if (anyReady || ++ticks % 4 === 0) refresh(); else schedulePoll();
  }, 900);
}

function updateCard(pid) {
  const card = document.querySelector(`.card[data-id="${CSS.escape(String(pid))}"]`);
  const pr = progress.get(pid);
  if (!card || !pr) return;
  const t = card.querySelector('.ptext'), bar = card.querySelector('.pbar i');
  const p = (store.library?.projects || []).find(x => String(x.id) === String(pid));
  if (t) t.textContent = progressText(pr, p?.status);
  if (bar) bar.style.width = pct(pr) + '%';
  card.querySelector('.pbar')?.classList.toggle('paused', !!pr.paused || paused());
}

export function libraryKey(e) {
  if ((e.metaKey || e.ctrlKey) && (e.key.toLowerCase() === 'o' || e.key.toLowerCase() === 'i')) { e.preventDefault(); attachFolder(); return true; }
  return false;
}

// ---------- Order: Sort menu and drag to reorder ----------
const SORTS = [['custom', 'Custom'], ['newest', 'Newest first'], ['oldest', 'Oldest first'], ['name', 'Name']];
let sortEl = null;
function sortControl() {
  if (sortEl) return sortEl;
  sortEl = document.createElement('label');
  sortEl.className = 'lib-sort';
  sortEl.innerHTML = `<select class="pfilter" aria-label="Sort projects" title="Sort projects">${SORTS.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}</select>`;
  const sel = sortEl.querySelector('select');
  sel.addEventListener('change', () => { setOrder({ projectSort: sel.value }); sel.blur(); });
  sel.addEventListener('keydown', e => e.stopPropagation());
  return sortEl;
}
function syncSort() {
  const sel = sortEl && sortEl.querySelector('select'), v = store.library?.projectSort || 'newest';
  if (sel && sel.value !== v && document.activeElement !== sel) sel.value = v;
}
// PUT /api/library/order; the answer is the library, already in the new order.
async function setOrder(body) {
  try {
    const j = await api.put(P.libraryOrder(), body);
    if (j && Array.isArray(j.projects)) await loadLibrary(); else await refresh();
  } catch (_) { toast("Couldn't change the order"); refresh(); }
}
// The ids of the section (source) a project is in, in the order shown.
function sectionOf(id) {
  const g = groupedProjects().find(g => g.projects.some(p => String(p.id) === String(id)));
  return g ? g.projects.map(p => String(p.id)) : [];
}
// Move a project next to another in its section: at once on screen, then saved (switches to Custom).
function moveTo(id, targetId, after) {
  id = String(id); targetId = String(targetId);
  const sec = sectionOf(id);
  if (!sec.includes(targetId) || id === targetId) return;
  const order = sec.filter(x => x !== id);
  order.splice(order.indexOf(targetId) + (after ? 1 : 0), 0, id);
  if (order.join() === sec.join()) return;
  // Optimistic: the section's projects take the same slots in the list, in the new order.
  const lib = store.library, inSec = new Set(order), byId = new Map(lib.projects.map(p => [String(p.id), p]));
  let k = 0;
  lib.projects = lib.projects.map(p => inSec.has(String(p.id)) ? byId.get(order[k++]) : p);
  lib.projectSort = 'custom';
  emit('library', lib);
  setOrder({ projectOrder: order });
}

// Drag a card onto another in the same section: an insertion bar shows where it lands.
let justDragged = false;
export function initLibraryDrag() {
  const grid = $('#libGrid'), scroller = $('#libScroll');
  let start = null, drag = null, target = null;
  const clear = () => { grid.querySelectorAll('.drop-before, .drop-after').forEach(c => c.classList.remove('drop-before', 'drop-after')); target = null; };
  grid.addEventListener('mousedown', e => {
    const card = e.target.closest('.card');
    if (!card || e.button !== 0 || e.shiftKey || e.metaKey || e.ctrlKey || e.target.closest('.more, input, button')) return;
    start = { x: e.clientX, y: e.clientY, card };
  });
  window.addEventListener('mousemove', e => {
    if (!start) return;
    if (!drag) {
      if (Math.hypot(e.clientX - start.x, e.clientY - start.y) < 6) return;
      const id = String(start.card._p?.id || '');
      if (sectionOf(id).length < 2) { start = null; return; }
      drag = { id, sec: sectionOf(id), card: start.card };
      drag.card.classList.add('dragging');
      document.body.classList.add('dragging-cards');
    }
    e.preventDefault();
    clear();
    // Near the top or bottom edge, the page scrolls.
    const r = scroller.getBoundingClientRect();
    if (e.clientY < r.top + 56) scroller.scrollBy(0, -12); else if (e.clientY > r.bottom - 56) scroller.scrollBy(0, 12);
    const over = document.elementFromPoint(e.clientX, e.clientY)?.closest('#libGrid .card');
    const oid = over && String(over._p?.id || '');
    if (!over || oid === drag.id || !drag.sec.includes(oid)) return;
    const cr = over.getBoundingClientRect(), after = e.clientX > cr.left + cr.width / 2;
    over.classList.add(after ? 'drop-after' : 'drop-before');
    target = { id: oid, after };
  });
  window.addEventListener('mouseup', () => {
    if (drag) {
      const t = target;
      clear();
      drag.card.classList.remove('dragging');
      document.body.classList.remove('dragging-cards');
      if (t) moveTo(drag.id, t.id, t.after);
      drag = null;
      justDragged = true; setTimeout(() => { justDragged = false; });
    }
    start = null;
  });
}
