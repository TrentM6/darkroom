// Grid: cull with the keyboard. Used for a project (moments, bursts; or a 35mm contact sheet),
// All Selects (grouped by project) and Best Work (manual order, drag to reorder). Includes the loupe.
import { api, P } from './api.js';
import { store, on, visible, setFilter, setPFilter, rate, loadContext, detail, ls, invalidate, viewMode, setViewMode, takeMarked, frameSettings } from './store.js';
import { $, $$, esc, preload, openMenu, toast, prettyDir, setImg, swapImg } from './ui.js';
import { ICONS } from './icons.js';
import { go, editPath, sameCtx } from './router.js';
import { runExport } from './exporter.js';
import { openExportSheet } from './exportsheet.js';
import { addToTarget, addMenuItems, addTo, removeFrom, collections, renameCollection, deleteCollection } from './collections.js';
import { locate } from './library.js';
import { marksSVG, marksFor, glyph } from './marks.js';
import { setAnalysis, toggleCritique, hideCritique } from './critique.js';
import { mountRateBar, paintRateBar } from './ratebar.js';

let loupeOpen = false;
const GAP = 10;                 // gutter between frames in a row
const LABEL_W = 36, MOMENT_GAP = 16;   // inline time label, and the extra space before a new moment
let cells = new Map();          // key -> element, reused across layouts so images never reload
let cellsCtx = '';
// The contact sheet is dark only. The old paper preference is dropped.
try { localStorage.removeItem('photolab.paper'); localStorage.removeItem('photolab.paperV2'); } catch (_) {}

export function initGrid() {
  wireSegs();
  const size = $('#thumbSize');
  size.value = store.size;
  size.oninput = () => { store.size = +size.value; ls.set('size', store.size); layout(); };
  size.onkeydown = e => { if (e.key.startsWith('Arrow')) e.stopPropagation(); };
  size.addEventListener('pointerup', () => size.blur());
  $('#gridExport').onclick = e => exportClick(e.currentTarget);
  $('#missingLocate').onclick = () => { const p = projectEntry(); if (p) locate(p); };
  on('library', () => { if (isActive()) paintMissing(); });

  const body = $('#gridBody');
  body.addEventListener('mousedown', onCellMouse);
  body.addEventListener('dblclick', e => { const c = e.target.closest('.cell'); if (c && !e.target.closest('button')) openEdit(c.dataset.key); });
  body.addEventListener('click', onBadgeClick);
  body.addEventListener('contextmenu', onCellMenu);
  $('#gridScroll').addEventListener('mousedown', e => {
    if (!e.target.closest('.cell') && !e.target.closest('button')) { store.sel = new Set(store.focus ? [store.focus] : []); paintSel(); }
  });
  initDrag(body);
  let raf = 0, lastW = 0;
  new ResizeObserver(() => {
    const w = $('#gridScroll').clientWidth;
    if (!isActive() || w === lastW) return;
    lastW = w;
    cancelAnimationFrame(raf); raf = requestAnimationFrame(() => layout());
  }).observe($('#gridScroll'));

  on('view', () => { if (isActive()) { paintBar(); render(); } });
  on('photo', p => { if (isActive()) updateCell(p); });
  on('rated', keys => { if (isActive()) afterRated(keys); });
  $('#loupe').addEventListener('mousedown', e => { if (e.target === $('#loupe') && !lz.on) closeLoupe(); });
  initLoupeZoom();
  mountRateBar($('#loupeRate'), () => store.focus);
}

const isActive = () => !$('#v-grid').hidden;
const kind = () => store.ctx?.kind;
// A project is always the contact sheet (film strips). All Selects and Best Work can switch to the grid,
// remembered per collection.
const viewKey = () => '@' + kind();
const isSheet = () => !!store.ctx && (kind() === 'project' || viewMode(viewKey()) === 'sheet');

function wireSegs() {
  $$('#filterSeg button').forEach(b => { b.setAttribute('role', 'radio'); b.onclick = () => { setFilter(b.dataset.v); syncSegs(); }; });
  $$('#viewSeg button').forEach(b => { b.setAttribute('role', 'radio'); b.onclick = () => setView(b.dataset.v); });
  const pf = $('#pfilterSel');
  pf.addEventListener('change', () => { setPFilter(pf.value); pf.blur(); });
  pf.addEventListener('keydown', e => e.stopPropagation());
}
function syncSegs() {
  $$('#filterSeg button').forEach(b => b.setAttribute('aria-checked', String(b.dataset.v === store.filter)));
  const v = isSheet() ? 'sheet' : 'grid';
  $$('#viewSeg button').forEach(b => b.setAttribute('aria-checked', String(b.dataset.v === v)));
}

function setView(v) {
  if (!store.ctx || kind() === 'project') return;
  setViewMode(viewKey(), v);   // emits 'view' -> paintBar + render
}

const projectEntry = () => kind() === 'project' ? store.library?.projects?.find(x => String(x.id) === store.ctx.pid) : null;
function paintMissing() {
  const p = projectEntry();
  $('#missingBanner').hidden = !(p && (p.status === 'missing' || p.missing === true));
}

function paintBar() {
  paintMissing();
  const k = kind();
  $('#gridTitle').textContent = store.ctx.name || '';
  $('#filterSeg').hidden = k !== 'project';
  $('#viewSeg').hidden = k === 'project';
  // Projects export photo by photo (from the editor); collections and Best Work export as a whole.
  $('#gridExport').hidden = k === 'project';
  // All Selects and Best Work: one continuous flow, narrowed by a project picker.
  const pf = $('#pfilterSel');
  pf.hidden = k === 'project';
  if (k !== 'project') {
    const projects = projectsHere();
    const html = `<option value="all">All projects</option>` + projects.map(x => `<option value="${esc(x.pid)}">${esc(x.name)}</option>`).join('');
    if (pf._html !== html) { pf._html = html; pf.innerHTML = html; }
    pf.value = store.pfilter;
  }
  syncSegs();
}

export async function showGrid(ctx) {
  if (!sameCtx(store.ctx, ctx)) { $('#gridBody').innerHTML = ''; cells = new Map(); }
  try {
    await loadContext(ctx);
  } catch (err) {
    toast("Couldn't open");
    go('/', { replace: true });
    return;
  }
  document.title = store.ctx.name || 'Darkroom';
  paintBar();
  render();
  if (!store.focus) { const v = visible(); if (v.length) { store.focus = v[0].key; store.sel = new Set([v[0].key]); store.anchor = v[0].key; paintSel(); } }
  requestAnimationFrame(() => scrollToFocus('center'));
  $('#gridScroll').focus({ preventScroll: true });
  if (ctx.kind === 'project') pollProgress(ctx);
}

// Still importing? Pick up new photos as they arrive.
let progTimer = null;
function pollProgress(ctx) {
  clearTimeout(progTimer);
  const p = store.library?.projects?.find(x => String(x.id) === ctx.pid);
  if (!p || !p.status || p.status === 'ready') return;
  progTimer = setTimeout(async () => {
    if (!isActive() || !sameCtx(store.ctx, ctx)) return;
    const n = store.photos.length;
    try {
      const s = await api.get(P.status(ctx.pid));
      await loadContext(ctx);
      if (store.photos.length !== n) render();
      if (s.state === 'ready' || s.state === 'done') { p.status = 'ready'; return; }
    } catch (_) {}
    pollProgress(ctx);
  }, 1500);
}

// ---------- Rendering ----------
function emptyText() {
  if (!store.photos.length && kind() === 'project') return 'No photos';
  if (kind() === 'selects') return 'No selects. Press P to pick a photo.';
  if (kind() === 'best') return 'No favorites. Press F to add a photo.';
  if (kind() === 'col') return 'Empty. Select photos in any project and press B, or drag them onto this collection in the sidebar.';
  return { selects: 'No selects', favorites: 'No favorites', rejected: 'No rejected photos', unflagged: 'No unflagged photos' }[store.filter] || 'No photos';
}

// The grid badge is only for problems that end a frame: closed eyes, focus that missed the subject.
// Everything else (motion blur, highlights...) is an Edit hint only. Nothing is derived here.
const GRID_PROBLEMS = new Set(['Eyes closed', 'Focus missed the subject']);
const GRID_CODES = new Set(['eyes-closed', 'missed-focus', 'focus-missed']);
function gridProblem(p) {
  if (p.hintCode && GRID_CODES.has(p.hintCode)) return p.hint || 'Eyes closed';
  return p.hint && GRID_PROBLEMS.has(p.hint) ? p.hint : null;
}

const aspectOf = p => (p.aspect > 0 ? p.aspect : (p.w && p.h ? p.w / p.h : 1.5));

// One element per photo, created once per context and moved between layouts.
function cellFor(p) {
  let c = cells.get(p.key);
  if (!c) {
    c = document.createElement('div');
    c.className = 'cell';
    c.dataset.key = p.key;
    c.innerHTML = `<div class="ph"><img alt="" decoding="async" draggable="false"></div>
      <div class="hb">
        <button class="hbb" data-flag="pick" tabindex="-1" title="Pick (P)"><span class="ic">${glyph('pick', 16)}</span></button>
        <button class="hbb" data-fav="1" tabindex="-1" title="Favorite (F)"><span class="ic">${glyph('favorite', 16)}</span></button>
        <button class="hbb" data-flag="reject" tabindex="-1" title="Reject (X)"><span class="ic">${glyph('reject', 16)}</span></button>
      </div>
      <span class="warn" hidden><span class="ic">${ICONS.warn}</span></span>
      <span class="colb" hidden></span>
      <span class="mk"></span>`;
    cells.set(p.key, c);
    // A new cell shows its state as-is: no transitions until it has been painted once.
    c.classList.add('fresh');
    requestAnimationFrame(() => requestAnimationFrame(() => c.classList.remove('fresh')));
  }
  const img = c.querySelector('img');
  const src = api.url(p.thumb);
  setImg(img, src);
  return c;
}

// Which collections a photo is in: on Best Work and All Selects (so you see what's still unplaced), and inside a
// collection only when it's in others too. One name, or "2 collections"; all names on hover.
function paintColBadge(c, p) {
  const b = c.querySelector('.colb');
  if (!b) return;
  const k = kind();
  let cs = Array.isArray(p.collections) ? p.collections : [];
  if (k === 'col') cs = cs.filter(x => x.id !== store.ctx.cid);
  const show = (k === 'best' || k === 'selects' || k === 'col') && cs.length > 0;
  b.hidden = !show;
  if (!show) return;
  const label = cs.length === 1 ? cs[0].name : `${cs.length} collections`;
  const html = `${ICONS.stack}<span>${esc(label)}</span>`;
  if (b._html !== html) { b._html = html; b.innerHTML = html; }
  b.title = (k === 'col' ? 'Also in ' : 'In ') + cs.map(x => x.name).join(', ');
}

function paintCellState(c, p, animate) {
  paintColBadge(c, p);
  c.classList.toggle('rejected', p.flag === 'reject');
  c.querySelector('[data-flag=pick]').classList.toggle('on', p.flag === 'pick');
  c.querySelector('[data-fav]').classList.toggle('on', p.favorite);
  c.querySelector('[data-flag=reject]').classList.toggle('on', p.flag === 'reject');
  const w = c.querySelector('.warn');
  const bad = gridProblem(p);
  w.hidden = !bad; if (bad) { w.title = bad; w.setAttribute('aria-label', bad); }
  const ph = c.querySelector('.ph');
  const W = ph.offsetWidth || parseFloat(ph.style.width) || 0, H = ph.offsetHeight || parseFloat(ph.style.height) || 0;
  // The marks a photo carries, the same in every view (marks.js marksFor).
  const mo = marksFor(kind());
  // Rebuilt only when the drawing changes (same marks, same size: the element is left alone).
  const mk = c.querySelector('.mk'), svg = W && mo ? marksSVG(p, W, H, { ...mo, animate, pad: isSheet() ? sheetGap : undefined }) : '';
  if (mk._svg !== svg) { mk.innerHTML = svg; mk._svg = svg; }
}

function render() {
  const ctxKey = store.ctx ? `${store.ctx.kind}/${store.ctx.pid || store.ctx.cid || ''}` : '';
  if (ctxKey !== cellsCtx) { cells = new Map(); cellsCtx = ctxKey; }
  const v = visible();
  const empty = $('#gridEmpty');
  empty.hidden = v.length > 0;
  if (!v.length) empty.textContent = emptyText();
  $('#gridBody').className = isSheet() ? 'sheet' : 'grid';
  layout();
  if (store.focus && !v.some(p => p.key === store.focus)) store.focus = v[0]?.key || null;
  for (const key of [...store.sel]) if (!v.some(p => p.key === key)) store.sel.delete(key);
  if (store.focus && !store.sel.size) store.sel.add(store.focus);
  paintSel();
}

function layout() {
  if (!store.ctx) return;
  const body = $('#gridBody');
  const top = $('#gridScroll').scrollTop;
  if (isSheet()) layoutSheet(body); else layoutGrid(body);
  $('#gridScroll').scrollTop = top;
  paintSel();
}

// One continuous flow, the same in every view.
//  - Project: capture order; a moment gets a small inline time label and a little extra space, only
//    after a gap of 15 minutes or more (labels in the same minute merge).
//  - All Selects (newest project first) and Best Work (the saved order): no labels at all.
function flowItems(photos) {
  const out = [];
  if (kind() !== 'project') return photos.slice();
  let lastT = null, lastLabel = '';
  for (const p of photos) {
    if (p.timeLabel && (lastT === null || p.t - lastT >= 15 * 60 * 1000) && p.timeLabel !== lastLabel) {
      out.push({ label: p.timeLabel, w: LABEL_W }); lastLabel = p.timeLabel;
    }
    out.push(p); lastT = p.t;
  }
  return out;
}
// Projects with photos in this collection, newest first (the project picker).
function projectsHere() {
  const lib = store.library?.projects || [];
  const seen = new Map();
  store.photos.forEach((p, i) => { if (!seen.has(p.pid)) seen.set(p.pid, { pid: p.pid, name: p.projectName || p.pid, i, date: String(lib.find(x => String(x.id) === p.pid)?.date || p.projectDate || '') }); });
  return [...seen.values()].sort((a, b) => b.date.localeCompare(a.date) || a.i - b.i);
}

// Justified rows: every full row fills the width exactly; thumbnails keep their aspect ratio.
function rowGeometry(items, W) {
  let sumA = 0, fixed = 0;
  items.forEach((it, i) => {
    if (it.label) fixed += (it.w || LABEL_W) + (i > 0 ? MOMENT_GAP : 0);
    else sumA += aspectOf(it);
  });
  const gaps = GAP * (items.length - 1);
  return { sumA, h: sumA ? (W - fixed - gaps) / sumA : 0 };
}
function justify(items, W, H) {
  const rows = [];
  let row = [];
  for (const it of items) {
    row.push(it);
    if (it.label) continue;               // a label never ends a row
    const { sumA, h } = rowGeometry(row, W);
    if (sumA && h <= H) { rows.push({ items: row, h, full: true }); row = []; }
  }
  if (row.some(it => !it.label)) {
    const photos = row.filter(it => !it.label).length;
    if (photos === 1 && rows.length) {
      // Never a lone photo on the last row: it joins the row above.
      const prev = rows.pop();
      const merged = prev.items.concat(row);
      rows.push({ items: merged, h: rowGeometry(merged, W).h, full: true });
    } else rows.push({ items: row, h: Math.min(H, rowGeometry(row, W).h), full: false });
  }
  return rows;
}

function layoutGrid(body) {
  const W = Math.max(200, $('#gridScroll').clientWidth - 72);
  const H = Math.round(store.size * 0.72);
  const frag = document.createDocumentFragment();
  {
    const sec = document.createElement('section');
    sec.className = 'moment';
    for (const row of justify(flowItems(visible()), W, H)) {
      const r = document.createElement('div');
      r.className = 'row';
      const h = Math.round(row.h);
      let used = 0;
      const photos = row.items.filter(it => !it.label);
      row.items.forEach((it, i) => {
        if (it.label) {
          const l = document.createElement('div');
          l.className = 'tlabel';
          l.textContent = it.label;
          const lw = it.w || LABEL_W;
          l.style.width = lw + 'px'; l.style.height = h + 'px';
          if (i > 0) l.style.marginLeft = MOMENT_GAP + 'px';
          used += lw + (i > 0 ? MOMENT_GAP : 0) + GAP;
          r.appendChild(l);
          return;
        }
        const p = it;
        const c = cellFor(p);
        c.className = 'cell gc';
        const last = i === row.items.length - 1;
        const w = row.full && last ? Math.max(1, W - used) : Math.floor(aspectOf(p) * row.h);
        used += w + GAP;
        const ph = c.querySelector('.ph');
        ph.style.width = w + 'px'; ph.style.height = h + 'px';
        const im = ph.querySelector('img');
        im.className = ''; im.style.width = ''; im.style.height = '';
        // Bursts: a hairline joins the frames of one burst.
        const j = photos.indexOf(p), prev = photos[j - 1], next = photos[j + 1];
        const inBurst = p.burst != null && kind() === 'project';
        c.classList.toggle('bu', inBurst && ((prev && prev.burst === p.burst) || (next && next.burst === p.burst)));
        c.classList.toggle('bu-end', !(next && next.burst === p.burst) || (row.items[i + 1]?.label));
        r.appendChild(c);
      });
      sec.appendChild(r);
    }
    frag.appendChild(sec);
  }
  body.replaceChildren(frag);
  for (const p of visible()) { const c = cells.get(p.key); if (c) paintCellState(c, p, takeMarked(p.key)); }
}

// ---------- Contact sheet ----------
// Edge print: each frame's own camera (and Fuji film simulation) from its EXIF, sent by the server as
// `edge`; else the project's most common one. Nothing when the photos carry no camera.
function stockText(p) {
  const pr = store.project || {};
  return String(p.edge || pr.stock || pr.edgePrint || '').toUpperCase();
}

let holeId = 0, sheetGap = 6;     // the gap between frames on a strip: the room a loop may use
function holes(width, s, top) {
  const id = 'sp' + (++holeId);
  const pitch = 4.75 * s, hw = 2.79 * s, hh = 1.98 * s, y = top ? 0.9 * s : 5.5 * s - 0.9 * s - hh;
  return `<svg class="holes" width="${width}" height="${5.5 * s}" aria-hidden="true"><defs><pattern id="${id}" width="${pitch}" height="${5.5 * s}" patternUnits="userSpaceOnUse" x="${-pitch / 2}"><rect x="${(pitch - hw) / 2}" y="${y}" width="${hw}" height="${hh}" rx="${0.45 * s}"/></pattern></defs><rect width="100%" height="100%" fill="url(#${id})"/></svg>`;
}

function layoutSheet(body) {
  const v = visible();
  const inner = Math.max(320, $('#gridScroll').clientWidth - 72 - 80);
  const fw = Math.floor(Math.min(store.size * 1.3, 320, inner / (6 + 5 * (2 / 36) + 2 * (1.5 / 36))));
  const s = fw / 36, fh = Math.round(24 * s), gap = Math.round(2 * s), end = Math.round(1.5 * s), reb = 5.5 * s;
  sheetGap = gap;
  const frameNo = new Map(store.photos.map((p, i) => [p.key, i + 1]));
  const sheet = document.createElement('div');
  sheet.className = 'paper';
  sheet.style.setProperty('--fw', fw + 'px');
  sheet.style.setProperty('--fs', Math.max(6, 1.2 * s).toFixed(1) + 'px');   // in proportion to the frame, as on film
  sheet.style.setProperty('--clear', (0.6 * s).toFixed(1) + 'px');   // gap between the edge print and the photo
  for (let i = 0; i < v.length; i += 6) {
    const strip = v.slice(i, i + 6);
    const width = end * 2 + strip.length * fw + (strip.length - 1) * gap;
    const el = document.createElement('div');
    el.className = 'strip35';
    el.style.width = width + 'px';
    let topText = '', botText = '';
    strip.forEach((p, j) => {
      const x = end + j * (fw + gap), n = frameNo.get(p.key);
      const stock = stockText(p);
      if (stock) topText += `<span class="ep" style="left:${x + fw * 0.08}px">${esc(stock)}</span>`;
      botText += `<span class="fn" data-key="${esc(p.key)}" style="left:${x}px;width:${fw}px"><span class="no">${n}</span><span class="na">▸ ${n}A</span></span>`;
    });
    el.innerHTML = `<div class="reb top" style="height:${reb}px">${holes(width, s, true)}${topText}</div><div class="frames" style="height:${fh}px;gap:${gap}px;padding:0 ${end}px"></div><div class="reb bot" style="height:${reb}px">${holes(width, s, false)}${botText}</div>`;
    const frames = el.querySelector('.frames');
    for (const p of strip) {
      const c = cellFor(p);
      c.className = 'cell fr';
      c.classList.remove('bu', 'bu-end');
      const ph = c.querySelector('.ph');
      ph.style.width = fw + 'px'; ph.style.height = fh + 'px';
      // Frames are always landscape on film: portrait pictures sit rotated, as on a real roll.
      const a = aspectOf(p), img = ph.querySelector('img');
      img.className = a < 1 ? 'rot' : '';
      if (a < 1) { const h0 = Math.min(fw, fh / a); img.style.height = h0 + 'px'; img.style.width = h0 * a + 'px'; }
      else { img.style.width = Math.min(fw, fh * a) + 'px'; img.style.height = Math.min(fh, fw / a) + 'px'; }
      frames.appendChild(c);
    }
    sheet.appendChild(el);
  }
  body.replaceChildren(sheet);
  for (const p of v) { const c = cells.get(p.key); if (c) paintCellState(c, p, takeMarked(p.key)); }
}

function cellEl(key) { return cells.get(key)?.isConnected ? cells.get(key) : null; }

function updateCell(p) {
  const c = cellEl(p.key);
  if (c) {
    const img = c.querySelector('img'), src = api.url(p.thumb);
    // Swap only once the new render is decoded: no flash.
    if (src) setImg(img, src);
    paintCellState(c, p, takeMarked(p.key));
  }
  if (loupeOpen && store.focus === p.key) paintLoupe();
}

// A mark can take a photo out of the current view: keep the place, move focus forward.
function afterRated() {
  const order = $$('#gridBody .cell').map(c => c.dataset.key);
  const v = visible();
  if (v.length === order.length && v.every((p, i) => p.key === order[i])) return;
  const idx = order.indexOf(store.focus);
  const keep = new Set(v.map(p => p.key));
  let next = null;
  for (let i = Math.max(0, idx); i < order.length; i++) if (keep.has(order[i])) { next = order[i]; break; }
  if (!next) for (let i = idx; i >= 0; i--) if (keep.has(order[i])) { next = order[i]; break; }
  if (kind() === 'selects') paintBar();
  render();
  if (next) { store.focus = next; store.sel = new Set([next]); store.anchor = next; paintSel(); scrollToFocus(); }
  if (loupeOpen) { if (!store.focus) closeLoupe(); else paintLoupe(); }
}

// ---------- Selection ----------
function paintSel() {
  for (const [k, c] of cells) {
    c.classList.toggle('sel', store.sel.has(k) && k !== store.focus);
    c.classList.toggle('focus', k === store.focus);
  }
}
function scrollToFocus(block = 'nearest') {
  const c = store.focus && cellEl(store.focus);
  if (c) c.scrollIntoView({ block, inline: 'nearest' });
}

// Right-click: the same marks as the keyboard.
function onCellMenu(e) {
  const c = e.target.closest('.cell');
  if (!c) return;
  e.preventDefault();
  const key = c.dataset.key;
  if (!store.sel.has(key)) { store.sel = new Set([key]); store.focus = key; store.anchor = key; paintSel(); }
  const keys = [...store.sel], p = store.byKey.get(key);
  const n = keys.length > 1 ? ` (${keys.length})` : '';
  openMenu(e.clientX, e.clientY, [
    { label: 'Edit', key: 'E', run: () => openEdit(key) },
    '-',
    { label: 'Pick' + n, key: 'P', icon: glyph('pick', 16), on: p.flag === 'pick' && keys.length === 1, check: p.flag === 'pick' && keys.length === 1, run: () => rate(keys, { flag: 'pick' }) },
    { label: 'Favorite' + n, key: 'F', icon: glyph('favorite', 16), on: p.favorite && keys.length === 1, check: p.favorite && keys.length === 1, run: () => rate(keys, { favorite: !(p.favorite && keys.length === 1) }) },
    { label: 'Reject' + n, key: 'X', icon: glyph('reject', 16), on: p.flag === 'reject' && keys.length === 1, check: p.flag === 'reject' && keys.length === 1, run: () => rate(keys, { flag: 'reject' }) },
    { label: 'Unflag' + n, key: 'U', run: () => rate(keys, { flag: null }) },
    '-',
    ...(kind() === 'col' ? [{ label: 'Remove from Collection' + n, key: '⌫', run: () => removeHere(keys) }, '-'] : []),
    ...addMenuItems(keys, kind() === 'col' ? store.ctx.cid : null),
    '-',
    { label: 'Show in Finder', run: () => api.post(P.reveal(), { projectId: p.pid, id: p.id }).catch(() => toast("Couldn't show the file")) },
  ]);
}

function onCellMouse(e) {
  const c = e.target.closest('.cell');
  if (!c || e.button !== 0 || e.target.closest('button')) return;
  const key = c.dataset.key;
  const order = visible().map(p => p.key);
  if (e.shiftKey && store.anchor) {
    const a = order.indexOf(store.anchor), b = order.indexOf(key);
    const [lo, hi] = a < b ? [a, b] : [b, a];
    if (!(e.metaKey || e.ctrlKey)) store.sel = new Set();
    order.slice(lo, hi + 1).forEach(x => store.sel.add(x));
    store.focus = key;
  } else if (e.metaKey || e.ctrlKey) {
    if (store.sel.has(key) && store.sel.size > 1) { store.sel.delete(key); if (store.focus === key) store.focus = [...store.sel][0]; }
    else { store.sel.add(key); store.focus = key; }
    store.anchor = key;
  } else {
    if (!store.sel.has(key)) store.sel = new Set([key]);
    store.focus = key; store.anchor = key;
    // A plain click on a selected photo narrows the selection on release (unless it starts a drag).
    const sel = store.sel;
    c.addEventListener('mouseup', () => { if (store.sel === sel && sel.size > 1 && !dragging) { store.sel = new Set([key]); paintSel(); } }, { once: true });
  }
  paintSel();
}

function onBadgeClick(e) {
  const b = e.target.closest('button');
  const c = e.target.closest('.cell');
  if (!b || !c) return;
  e.stopPropagation();
  const p = store.byKey.get(c.dataset.key);
  const keys = store.sel.has(p.key) ? [...store.sel] : [p.key];
  if (b.dataset.flag) rate(keys, { flag: p.flag === b.dataset.flag ? null : b.dataset.flag });
  else if (b.dataset.fav) rate(keys, { favorite: !p.favorite });
}

function move(dir) {
  const cells = $$('#gridBody .cell');
  if (!cells.length) return null;
  let i = cells.findIndex(c => c.dataset.key === store.focus);
  if (i < 0) return cells[0].dataset.key;
  let j = i;
  if (dir === 'left') j = Math.max(0, i - 1);
  else if (dir === 'right') j = Math.min(cells.length - 1, i + 1);
  else {
    const r0 = cells[i].getBoundingClientRect(), cx = r0.left + r0.width / 2;
    const cand = cells.map((c, k) => ({ r: c.getBoundingClientRect(), k }))
      .filter(({ r }) => dir === 'up' ? r.bottom <= r0.top + 2 : r.top >= r0.bottom - 2);
    if (cand.length) {
      const rowTop = dir === 'up' ? Math.max(...cand.map(c => c.r.top)) : Math.min(...cand.map(c => c.r.top));
      const row = cand.filter(c => Math.abs(c.r.top - rowTop) < 4);
      row.sort((a, b) => Math.abs(a.r.left + a.r.width / 2 - cx) - Math.abs(b.r.left + b.r.width / 2 - cx));
      j = row[0].k;
    }
  }
  return cells[j].dataset.key;
}

function focusTo(key, extend = false) {
  if (!key) return;
  if (extend) {
    const order = visible().map(p => p.key);
    const a = order.indexOf(store.anchor ?? store.focus), b = order.indexOf(key);
    const [lo, hi] = a < b ? [a, b] : [b, a];
    store.sel = new Set(order.slice(lo, hi + 1));
  } else { store.sel = new Set([key]); store.anchor = key; }
  store.focus = key;
  paintSel();
  scrollToFocus();
  if (loupeOpen) paintLoupe();
}

const targets = () => store.sel.size ? [...store.sel] : (store.focus ? [store.focus] : []);

// Shared marking keys (grid, loupe, edit). Shift = mark and move on. Returns true if handled.
export function ratingKey(e, keys, advance) {
  if (e.metaKey || e.ctrlKey || e.altKey || !keys.length) return false;
  const k = e.key.toLowerCase();
  let change = null;
  if (k === 'p') change = { flag: 'pick' };
  else if (k === 'x') change = { flag: 'reject' };
  else if (k === 'u') change = { flag: null };
  else if (k === 'f') {
    const all = keys.every(x => store.byKey.get(x)?.favorite);
    change = { favorite: !all };
  } else if (k === 'b' && !e.shiftKey) { e.preventDefault(); addToTarget(keys); return true; }
  if (!change) return false;
  e.preventDefault();
  rate(keys, change);
  if (e.shiftKey && advance) advance();
  return true;
}

export function gridKey(e) {
  if (loupeOpen) return loupeKey(e);
  const k = e.key;
  if ((e.metaKey || e.ctrlKey) && k.toLowerCase() === 'a') {
    e.preventDefault(); store.sel = new Set(visible().map(p => p.key)); paintSel(); return true;
  }
  if (k.startsWith('Arrow')) { e.preventDefault(); focusTo(move(k.slice(5).toLowerCase()), e.shiftKey); return true; }
  if (k === 'Home' || k === 'End') { e.preventDefault(); const v = visible(); focusTo((k === 'Home' ? v[0] : v[v.length - 1])?.key); return true; }
  if (k === ' ') { e.preventDefault(); if (store.focus) openLoupe(); return true; }
  if (k.toLowerCase() === 'c' && !e.metaKey && !e.ctrlKey && !e.altKey && store.ctx && kind() !== 'project') {
    e.preventDefault(); setView(isSheet() ? 'grid' : 'sheet'); return true;
  }
  if ((k === 'Enter' || k.toLowerCase() === 'e') && !e.metaKey && !e.ctrlKey) { e.preventDefault(); if (store.focus) openEdit(store.focus); return true; }
  if ((k === 'Backspace' || k === 'Delete') && kind() === 'col' && store.sel.size) { e.preventDefault(); removeHere([...store.sel]); return true; }
  if (k === 'Escape') {
    if (store.sel.size > 1) { store.sel = new Set([store.focus]); paintSel(); return true; }
    if (kind() === 'project') go('/');
    return true;
  }
  return ratingKey(e, targets(), () => focusTo(move('right')));
}

function openEdit(key) {
  if (loupeOpen) closeLoupe();
  const p = store.byKey.get(key);
  if (!p) return;
  store.focus = key;
  if (!store.sel.has(key)) store.sel = new Set([key]);
  go(editPath(store.ctx, p));
}

// Take photos out of the open collection (the photos themselves stay where they are).
function removeHere(keys) {
  const ctx = store.ctx;
  if (!ctx || ctx.kind !== 'col') return;
  return removeFrom(ctx.cid, keys, async () => { if (store.ctx?.kind === 'col' && store.ctx.cid === ctx.cid) { await loadContext(store.ctx); render(); } });
}

// ---------- Best Work and collections: drag to reorder; anywhere: drag onto a collection in the sidebar ----------
// Pointer-based (works the same in WKWebView and browsers): press, move a few pixels, drop
// between two photos.
let dragging = null;
function initDrag(body) {
  let start = null;
  const clear = () => $$('#gridBody .drop-before, #gridBody .drop-after').forEach(c => c.classList.remove('drop-before', 'drop-after'));
  body.addEventListener('mousedown', e => {
    const c = e.target.closest('.cell');
    if (!c || e.button !== 0 || e.shiftKey || e.metaKey || e.ctrlKey || e.target.closest('button')) return;
    if (!canReorder() && !collections().length) return;
    start = { x: e.clientX, y: e.clientY, key: c.dataset.key };
  });
  window.addEventListener('mousemove', e => {
    if (!start) return;
    if (!dragging) {
      if (Math.hypot(e.clientX - start.x, e.clientY - start.y) < 6) return;
      dragging = store.sel.has(start.key) ? [...store.sel] : [start.key];
      dragging.forEach(k => cellEl(k)?.classList.add('dragging'));
      document.body.style.cursor = 'grabbing';
    }
    clear();
    const over = document.elementFromPoint(e.clientX, e.clientY);
    $$('#sideCols .drop-into').forEach(x => x.classList.toggle('drop-into', false));
    const col = over?.closest('#sideCols [data-cid]');
    if (col) { col.classList.add('drop-into'); return; }
    if (!canReorder()) return;
    const c = over?.closest('#gridBody .cell');
    if (!c || dragging.includes(c.dataset.key)) return;
    const r = c.getBoundingClientRect();
    c.classList.add(e.clientX > r.left + r.width / 2 ? 'drop-after' : 'drop-before');
  });
  window.addEventListener('mouseup', () => {
    if (dragging) {
      const col = $('#sideCols .drop-into');
      if (col) { col.classList.toggle('drop-into', false); addTo(col.dataset.cid, dragging); }
      const c = $('#gridBody .drop-before, #gridBody .drop-after');
      if (c) reorder(dragging, c.dataset.key, c.classList.contains('drop-after'));
      clear();
      $$('#gridBody .dragging').forEach(x => x.classList.remove('dragging'));
      document.body.style.cursor = '';
      setTimeout(() => { dragging = null; });
    }
    start = null;
  });
}

const canReorder = () => (kind() === 'best' || kind() === 'col') && store.pfilter === 'all';

async function reorder(keys, targetKey, after) {
  if (keys.includes(targetKey)) return;
  const moving = store.photos.filter(p => keys.includes(p.key));
  const rest = store.photos.filter(p => !keys.includes(p.key));
  let i = rest.findIndex(p => p.key === targetKey);
  if (after) i++;
  rest.splice(i, 0, ...moving);
  store.photos = rest;
  invalidate();
  const top = $('#gridScroll').scrollTop;
  render();
  $('#gridScroll').scrollTop = top;
  try {
    if (kind() === 'col') await api.put(P.colOrder(store.ctx.cid), { items: store.photos.map(p => ({ projectId: p.pid, id: p.id })) });
    else await api.put(P.bestOrder(), { items: store.photos.filter(p => p.favorite).map(p => ({ projectId: p.pid, id: p.id })) });
  } catch (_) { toast("Couldn't save order"); }
}

// ---------- Loupe ----------
function openLoupe() { loupeOpen = true; lz.on = false; $('#loupe').hidden = false; paintLoupe(); }
function closeLoupe() { hideCritique(); loupeOpen = false; lz.on = false; $('#loupe').classList.remove('zoom'); $('#loupe').hidden = true; scrollToFocus(); }

// The review spread in the loupe: the column on the right, the photo centred in what is left.
let lpHost = null;
const loupeHost = () => lpHost || (lpHost = { el: $('#loupe'), photo: () => $('#loupeImg'), relayout: () => placeLoupe(), btn: null });
const reviewW = () => { const c = $('#loupe').classList.contains('reviewing') && $('#loupe > .review'); return c ? c.offsetWidth : 0; };

// Loupe 1:1: Z or a click toggles 100% at that point; drag pans; the full-size render swaps in.
const lz = { on: false, cx: 0.5, cy: 0.5, iw: 0, ih: 0 };
function placeLoupe() {
  const p = store.byKey.get(store.focus), img = $('#loupeImg');
  if (!p) return;
  const a = aspectOf(p), dpr = devicePixelRatio || 1, aw = innerWidth - reviewW();
  if (lz.on) {
    lz.ih = p.h / dpr; lz.iw = lz.ih * a;
    if (a < p.w / p.h) { lz.iw = p.w / dpr * (a / (p.w / p.h)); lz.ih = lz.iw / a; }
    const W = aw, H = innerHeight;
    const hx = lz.iw > W ? W / (2 * lz.iw) : 0.5, hy = lz.ih > H ? H / (2 * lz.ih) : 0.5;
    lz.cx = Math.min(1 - hx, Math.max(hx, lz.cx)); lz.cy = Math.min(1 - hy, Math.max(hy, lz.cy));
    Object.assign(img.style, { width: lz.iw + 'px', height: lz.ih + 'px', left: (W / 2 - lz.cx * lz.iw) + 'px', top: (H / 2 - lz.cy * lz.ih) + 'px' });
  } else {
    const k = Math.min((aw - (aw < innerWidth ? 64 : 80)) / a, innerHeight - 90);
    Object.assign(img.style, { width: Math.round(a * k) + 'px', height: Math.round(k) + 'px', left: '', top: '' });
  }
  $('#loupe').classList.toggle('zoom', lz.on);
}
async function loupeZoom(on, at) {
  const img = $('#loupeImg'), p = store.byKey.get(store.focus);
  if (!p) return;
  if (on && at) {
    const r = img.getBoundingClientRect();
    lz.cx = (at.x - r.left) / r.width; lz.cy = (at.y - r.top) / r.height;
  } else if (on) { lz.cx = 0.5; lz.cy = 0.5; }
  lz.on = on;
  placeLoupe();
  if (on && at) { lz.cx += ((innerWidth - reviewW()) / 2 - at.x) / lz.iw; lz.cy += (innerHeight / 2 - at.y) / lz.ih; placeLoupe(); }
  if (!on) return;
  try {
    const d = await detail(p.key);
    const url = d.full ? api.url(d.full) : null;
    if (!url) return;
    const im = await preload(url);
    if (lz.on && store.focus === p.key && im?.naturalWidth) swapImg(img, url);
  } catch (_) {}
}
function initLoupeZoom() {
  const lp = $('#loupe');
  let drag = null;
  lp.addEventListener('pointerdown', e => {
    if (e.button !== 0 || e.target !== $('#loupeImg')) return;
    drag = { x: e.clientX, y: e.clientY, cx: lz.cx, cy: lz.cy, moved: false };
    lp.setPointerCapture(e.pointerId);
  });
  lp.addEventListener('pointermove', e => {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!drag.moved && Math.hypot(dx, dy) < 4) return;
    drag.moved = true;
    if (!lz.on) return;
    lz.cx = drag.cx - dx / lz.iw; lz.cy = drag.cy - dy / lz.ih;
    placeLoupe();
  });
  lp.addEventListener('pointerup', e => {
    if (!drag) return;
    const d = drag; drag = null;
    if (!d.moved) loupeZoom(!lz.on, { x: e.clientX, y: e.clientY });
  });
}
export const isLoupeOpen = () => loupeOpen;

let loupeSeq = 0;
async function paintLoupe() {
  const p = store.byKey.get(store.focus);
  if (!p) return;
  const img = $('#loupeImg');
  const seq = ++loupeSeq;
  if (img.dataset.key !== p.key) {
    lz.on = false; img.dataset.key = p.key;
    // The previous photo stays until this one's thumbnail is decoded (at most 150 ms).
    const src = api.url(p.thumb);
    await Promise.race([swapImg(img, src, { onFail: 'set', commit: placeLoupe }), new Promise(r => setTimeout(r, 150))]);
    if (seq !== loupeSeq) return;
    if (img.getAttribute('src') !== src) { delete img.dataset.want; img.src = src; }
  }
  placeLoupe();
  // Marks, small, in the corner: the same pencil marks as the grid, on a tiny frame.
  const mo = marksFor(kind());
  const mini = mo && (p.flag || p.favorite) ? marksSVG(p, 30, 20, { ...mo, pad: 3, animate: takeMarked(p.key) }) : '';
  paintRateBar($('#loupeRate'), p);
  const vis = visible(), at = vis.findIndex(x => x.key === p.key);
  $('#loupeInfo').innerHTML = `${mini ? `<span class="lm">${mini}</span>` : ''}<span class="fname">${esc(p.file || p.id)}</span><span class="count">${at + 1} / ${vis.length}</span>`;
  setAnalysis(null, null, loupeHost());
  try {
    const d = await detail(p.key);
    if (seq === loupeSeq) setAnalysis(p, d, loupeHost(), () => detail(p.key, { fresh: true }));
    const src = api.url(d.preview);
    await preload(src);
    if (seq === loupeSeq && loupeOpen && !lz.on) swapImg(img, src);
  } catch (_) {}
  const v = visible(), i = v.findIndex(x => x.key === p.key);
  for (const q of [v[i + 1], v[i - 1]]) if (q) detail(q.key).then(d => preload(api.url(d.preview))).catch(() => {});
}

function loupeKey(e) {
  const k = e.key;
  if (k === 'Escape' && lz.on) { e.preventDefault(); loupeZoom(false); return true; }
  if (k === 'Escape' || k === ' ') { e.preventDefault(); closeLoupe(); return true; }
  if (k.toLowerCase() === 'z' && !e.metaKey && !e.ctrlKey) { e.preventDefault(); loupeZoom(!lz.on); return true; }
  if (k.toLowerCase() === 'a' && !e.metaKey && !e.ctrlKey) { e.preventDefault(); toggleCritique(loupeHost()); return true; }
  const v = visible(), i = v.findIndex(x => x.key === store.focus);
  const next = () => focusTo(v[Math.min(v.length - 1, i + 1)]?.key);
  if (k.startsWith('Arrow')) {
    e.preventDefault();
    if (k === 'ArrowLeft' || k === 'ArrowUp') focusTo(v[Math.max(0, i - 1)]?.key); else next();
    return true;
  }
  if (k === 'Enter' || k.toLowerCase() === 'e') { e.preventDefault(); openEdit(store.focus); return true; }
  return ratingKey(e, store.focus ? [store.focus] : [], () => { const w = visible(), j = w.findIndex(x => x.key === store.focus); focusTo(w[Math.min(w.length - 1, j + 1)]?.key); });
}

// ---------- Export ----------
// A collection or Best Work: the export sheet (all or selected, frame or not, a new folder). All Selects: the menu.
function exportClick(btn) {
  const k = kind();
  if (k !== 'col' && k !== 'best') return exportMenu(btn);
  const sel = [...store.sel].map(x => store.byKey.get(x)).filter(Boolean);
  const all = visible(), whole = store.pfilter === 'all';
  const cid = store.ctx.cid;
  openExportSheet({
    name: store.ctx.name || (k === 'best' ? 'Best Work' : 'Collection'), all, sel,
    run: ({ items, dest, frame, count }) => {
      const list = items || (whole ? null : all.map(p => ({ projectId: p.pid, id: p.id })));
      return k === 'col' ? { col: cid, items: list, dest, frame, count } : { best: true, items: list, dest, frame, count };
    },
  });
}

function exportMenu(btn) {
  const sel = [...store.sel].map(k => store.byKey.get(k)).filter(Boolean);
  const r = btn.getBoundingClientRect();
  const lib = store.library || {};
  const items = [{ caption: `To ${prettyDir(lib.exportDir || lib.exportRoot || '~/Desktop')} · Frame ${frameSettings().enabled ? 'on' : 'off'}` }];
  if (sel.length === 1) items.push({ label: 'Export Photo', run: () => runExport({ pid: sel[0].pid, ids: [sel[0].id] }) }, '-');
  if (kind() === 'project') {
    const picks = store.photos.filter(p => p.flag === 'pick').length;
    items.push({ label: `Export Selects${picks ? ` (${picks})` : ''}`, disabled: !picks, run: () => runExport({ pid: store.ctx.pid, ids: 'picks', count: picks }) });
    if (sel.length > 1) items.push({ label: `Export Selected (${sel.length})`, run: () => runExport({ pid: store.ctx.pid, ids: sel.map(p => p.id) }) });
    items.push({ label: `Export All (${store.photos.length})`, run: () => runExport({ pid: store.ctx.pid, ids: 'all', count: store.photos.length }) });
  } else if (kind() === 'col') {
    const all = visible(), cid = store.ctx.cid, whole = store.pfilter === 'all';
    items.push({ label: `Export ${store.ctx.name} (${all.length})`, disabled: !all.length, run: () => runExport(whole ? { col: cid, count: all.length } : { col: cid, items: all.map(p => ({ projectId: p.pid, id: p.id })) }) });
    if (sel.length > 1) items.push({ label: `Export Selected (${sel.length})`, run: () => runExport({ col: cid, items: sel.map(p => ({ projectId: p.pid, id: p.id })) }) });
    const c = collections().find(x => x.id === cid);
    if (c) items.push('-', { label: 'Rename Collection…', run: () => renameCollection(c) }, { label: 'Delete Collection…', run: () => deleteCollection(c, true) });
  } else if (kind() === 'best') {
    const all = visible();
    const whole = store.pfilter === 'all';
    items.push({ label: `Export Best Work (${all.length})`, disabled: !all.length, run: () => runExport(whole ? { best: true, count: all.length } : { best: true, items: all.map(p => ({ projectId: p.pid, id: p.id })) }) });
    if (sel.length > 1) items.push({ label: `Export Selected (${sel.length})`, run: () => runExport({ best: true, items: sel.map(p => ({ projectId: p.pid, id: p.id })) }) });
  } else {
    const all = visible();
    items.push({ label: `Export Selects (${all.length})`, disabled: !all.length, run: () => runExport({ photos: all }) });
    if (sel.length > 1) items.push({ label: `Export Selected (${sel.length})`, run: () => runExport({ photos: sel }) });
  }
  const own = !!store.library?.projectFolders;
  items.push('-', { label: 'Folder per Project', check: own, run: () => setProjectFolders(!own) });
  openMenu(r.right - 230, r.bottom + 6, items);
}

async function setProjectFolders(on) {
  store.library = { ...(store.library || {}), projectFolders: on };
  try { await api.put(P.settings(), { projectFolders: on }); } catch (_) { toast("Couldn't save setting"); }
}

// Photos added to or taken out of a collection: reload the open collection-like view so badges and contents follow.
on('collections', async () => {
  if (!isActive() || !store.ctx || kind() === 'project') return;
  const top = $('#gridScroll').scrollTop;
  try { await loadContext(store.ctx); } catch (_) { return; }
  render();
  $('#gridScroll').scrollTop = top;
});

export function refreshGrid() { invalidate(); if (isActive()) { paintBar(); render(); } }
