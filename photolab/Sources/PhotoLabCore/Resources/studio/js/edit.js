// Edit: big image, live white frame, right panel, filmstrip. Instant CSS approximation while
// dragging; the real render swaps in when it arrives (latest request wins).
import { api, P, nextSeq } from './api.js';
import { store, on, visible, loadContext, detail, setThumb, frameSettings, saveFrame, ls, films, loadLibrary, takeMarked } from './store.js';
import { marksSVG, marksFor } from './marks.js';
import { $, $$, esc, setImg, swapImg, preload, toast, dialog, debounce, hideTip, openMenu, isApp } from './ui.js';
import { look, fetchLook, setPinned, watchLook } from './look.js';
import { pushUndo } from './undo.js';
import { mountRateBar, paintRateBar } from './ratebar.js';
import { createGPU, pipelineFor } from './gpu.js';
import { setAnalysis, toggleCritique, hideCritique, hasAnalysis } from './critique.js';
import { icon, ICONS } from './icons.js';
import { go, ctxPath, editPath, sameCtx } from './router.js';
import { runExport } from './exporter.js';
import { ratingKey } from './grid.js';
import { SECTIONS, LOOK_AMOUNT, FRAME_CTLS, CTL, LOOK_KEYS, norm, sameParams, approx, ASPECTS, aspectRatio, fitCrop, round4, FILMS_FALLBACK, GRAIN_SIZES } from './params.js';

let ed = null;            // {id, p, cur, auto, shown, seq, inflight, preview, original, clip, hints, notes}
let cropMode = false, before = false, clipOn = false;
// 1:1 zoom: cx, cy = the point of the photo (0..1 of what is shown) at the centre of the stage.
const zoom = { on: false, cx: 0.5, cy: 0.5, fullUrl: null };
let clipboard = null;
let stripKey = '';
const els = {};           // k -> {row, input, out, tick}
const dismissed = new Set(ls.get('dismissedHints', []));
const closedSecs = new Set(ls.get('closedSections', ['geometry', 'frame']));
let busyCount = 0;

export function initEdit() {
  buildPanel();
  $('#editBack').onclick = backToGrid;
  $('#editExport').onclick = async () => { if (!ed) return; const e = ed; await flushSave(); runExport({ pid: e.p.pid, ids: [e.p.id] }); };
  $('#frameBtn').onclick = toggleFrame;
  $('#critBtn').onclick = () => toggleCritique(reviewHost());
  // Analysis switched on or off in Settings: the button follows at once.
  on('setup', () => { if (ed) paintAnalysis(ed); });
  $('#cropBtn').onclick = () => setCropMode(!cropMode);
  $('#beforeBtn').onclick = () => setSplit(!split.on);
  initSplit();
  $('#resetBtn').onclick = reset;
  $('#copyBtn').onclick = copy;
  $('#pasteBtn').onclick = paste;
  new ResizeObserver(() => layout()).observe($('#stage'));
  initCropDrag();
  initZoom();
  initCropBar();
  mountRateBar($('#editRate'), () => ed?.key);
  initGPU();
  initImageState();

  const strip = $('#strip');
  // Act on press, not on 'click': WebKit drops the click when the press turns into a drag or text
  // selection (trackpad micro-moves) or when the cell under the pointer is repainted before release.
  strip.addEventListener('pointerdown', onStripDown);
  strip.addEventListener('dragstart', e => e.preventDefault());
  strip.addEventListener('wheel', e => { if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) { strip.scrollLeft += e.deltaY; e.preventDefault(); } }, { passive: false });

  on('photo', p => { if (isActive()) { updateStripCell(p); if (p.key === ed?.key) paintRateBar($('#editRate'), p); } });
  on('rated', () => { if (isActive()) renderStrip(); });
  on('view', () => { if (isActive()) renderStrip(true); });
  on('frame', () => { if (isActive()) { syncFrame(); layout(); } });
  on('library', () => { if (isActive()) syncFilms(); });
  // Unedited photos re-render after My Look changes: show the new look on the photo being viewed,
  // unless there are changes on it that haven't been saved yet.
  on('rerendered', async keys => {
    if (!isActive() || !ed || !keys.includes(ed.key) || ed.p.edited || !ed.cur || !sameParams(ed.cur, ed.base)) return;
    const e = ed;
    try { const d = await detail(e.key, { fresh: true }); if (ed === e && sameParams(ed.cur, ed.base)) applyDetail(d); } catch (_) {}
  });
  window.addEventListener('blur', () => { clearTimeout(bsHold.t); bsHold.down = bsHold.held = false; setBefore(false); });
}

const isActive = () => !$('#v-edit').hidden;

// ---------- Panel ----------
function ctlRow(c, { onInput, onAuto, frame = false }) {
  const commitOnRelease = !frame;
  const row = document.createElement('div');
  row.className = 'ctl';
  row.innerHTML = `<label>${esc(c.label)}</label><div class="track"><input type="range" min="${c.min}" max="${c.max}" step="${c.step}" aria-label="${esc(c.label)}"><i class="tick"></i></div><output></output>`;
  const input = row.querySelector('input'), out = row.querySelector('output'), tick = row.querySelector('.tick');
  if (frame) tick.remove();
  input.addEventListener('input', () => { fillTrack(input); onInput(parseFloat(input.value)); });
  input.addEventListener('change', () => { flush(); if (commitOnRelease) commit(); });
  const auto = () => onAuto();
  input.addEventListener('dblclick', auto);
  row.querySelector('label').addEventListener('dblclick', auto);
  row.querySelector('label').addEventListener('click', () => input.focus());   // then arrow keys nudge
  input.addEventListener('keydown', e => {
    if (e.key.startsWith('Arrow') || e.key === 'Home' || e.key === 'End' || e.key === 'PageUp' || e.key === 'PageDown') e.stopPropagation();
    if (e.key === 'Escape') { input.blur(); e.stopPropagation(); }
  });
  input.addEventListener('pointerup', () => input.blur());
  els[c.k] = { row, input, out, tick: frame ? null : tick, c };
  return row;
}

const isClosed = id => closedSecs.has(id);
function section(id, title, bodyEl, headExtra) {
  const sec = document.createElement('section');
  sec.className = 'sec' + (isClosed(id) ? ' closed' : '');
  sec.dataset.sec = id;
  sec.innerHTML = `<div class="sec-h"><button class="sec-t" aria-expanded="${!isClosed(id)}" aria-controls="sb-${id}"><span>${esc(title)}</span><span class="chev">${ICONS.chev}</span></button></div><div class="sec-b" id="sb-${id}"></div>`;
  sec.querySelector('.sec-b').appendChild(bodyEl);
  if (headExtra) sec.querySelector('.sec-h').appendChild(headExtra);
  const t = sec.querySelector('.sec-t');
  t.addEventListener('click', () => {
    sec.classList.toggle('closed');
    const closed = sec.classList.contains('closed');
    t.setAttribute('aria-expanded', String(!closed));
    if (closed) closedSecs.add(id); else closedSecs.delete(id);
    ls.set('closedSections', [...closedSecs]);
  });
  return sec;
}

function paramRow(c) {
  return ctlRow(c, {
    onInput: v => { if (!ed?.cur) return; ed.cur[c.k] = c.invert ? -v || 0 : v; syncCtl(c.k); changed(); },
    onAuto: () => { if (!ed?.cur) return; ed.cur[c.k] = ed.auto[c.k]; syncCtl(c.k); changed(true); },
  });
}

// Overlay scroll indicator for the panel (it has no native scrollbar: see styles.css .panel-scroll).
let pthumbHide = null;
function initPanelThumb() {
  const sc = $('#panelScroll'), panel = $('#panel');
  if (!sc || !panel || panel.querySelector('.pthumb')) return;
  const t = document.createElement('div'); t.className = 'pthumb'; panel.appendChild(t);
  const place = show => {
    const h = sc.clientHeight, H = sc.scrollHeight, can = H > h + 1;
    t.classList.toggle('can', can);
    if (!can) { t.classList.remove('on'); return; }
    const th = Math.max(28, h * h / H), top = sc.offsetTop + (h - th) * (sc.scrollTop / (H - h));
    t.style.height = th + 'px'; t.style.top = top + 'px';
    if (show) { t.classList.add('on'); clearTimeout(pthumbHide); pthumbHide = setTimeout(() => t.classList.remove('on'), 700); }
  };
  sc.addEventListener('scroll', () => place(true), { passive: true });
  new ResizeObserver(() => place(false)).observe(sc);
  new MutationObserver(() => place(false)).observe(sc, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
  place(false);
}

function buildPanel() {
  initPanelThumb();
  const root = $('#panelScroll');
  root.innerHTML = '';
  for (const s of SECTIONS) {
    const body = document.createElement('div');
    if (s.id === 'look') {
      body.appendChild(paramRow(LOOK_AMOUNT));
      // Head: ⋯ at the far right (Update My Look from This Photo, Pin My Look).
      const extra = document.createElement('span');
      extra.className = 'sec-x';
      extra.innerHTML = `<button class="sec-more" id="lookMore" title="More" aria-label="My Look actions" aria-haspopup="menu">${icon('more')}</button>`;
      extra.querySelector('#lookMore').onclick = e => {
        e.stopPropagation();
        const r = e.currentTarget.getBoundingClientRect();
        const pinned = look.data?.source === 'pinned';
        openMenu(r.left, r.bottom + 4, [
          { label: 'Update My Look from This Photo', disabled: !ed?.cur, run: updateLookFromPhoto },
          ...(look.data ? [{ label: 'Pin My Look', check: pinned, run: () => setPinned(!pinned) }] : []),
        ]);
      };
      root.appendChild(section(s.id, s.title, body, extra));
      continue;
    } else if (s.id === 'balance') {
      let group = null;
      s.ctls.forEach(c => {
        if (c.group !== group) { group = c.group; const h = document.createElement('div'); h.className = 'sub-h'; h.textContent = group; body.appendChild(h); }
        body.appendChild(paramRow(c));
      });
      const extra = document.createElement('span');
      extra.className = 'sec-x';
      extra.innerHTML = '<button class="sec-btn" id="neutralBtn" title="Measure the cast in the shadows and highlights and cancel it">Neutralize</button>';
      extra.querySelector('#neutralBtn').onclick = e => { e.stopPropagation(); neutralize(); };
      root.appendChild(section(s.id, s.title, body, extra));
      continue;
    } else if (s.id === 'film') {
      const sel = document.createElement('select');
      sel.className = 'stock'; sel.id = 'filmSel'; sel.setAttribute('aria-label', 'Film stock');
      sel.addEventListener('change', () => {
        if (!ed?.cur) return;
        ed.cur.film = sel.value;
        if (sel.value && !ed.cur.filmStrength) ed.cur.filmStrength = ed.auto.filmStrength || 72;
        syncAll(); changed(true); sel.blur();
      });
      body.appendChild(sel);
      s.ctls.forEach(c => body.appendChild(paramRow(c)));
    } else if (s.id === 'effects') {
      s.ctls.forEach(c => body.appendChild(paramRow(c)));
      const gs = document.createElement('div');
      gs.className = 'aspects grain-size'; gs.id = 'grainSize';
      gs.innerHTML = GRAIN_SIZES.map(([v, l]) => `<button data-g="${v}" title="${l} grain">${l}</button>`).join('');
      gs.addEventListener('click', e => {
        const b = e.target.closest('button');
        if (!b || !ed?.cur || ed.cur.grainSize === b.dataset.g) return;
        ed.cur.grainSize = b.dataset.g; syncGrain(); changed(true);
      });
      gs.addEventListener('dblclick', () => { if (ed?.cur) { ed.cur.grainSize = ed.auto.grainSize; syncGrain(); changed(true); } });
      body.appendChild(gs);
    } else if (s.id === 'geometry') {
      s.ctls.forEach(c => body.appendChild(paramRow(c)));
      const asp = document.createElement('div');
      asp.className = 'aspects'; asp.id = 'aspects';
      asp.innerHTML = ASPECTS.map(([v, l]) => `<button data-a="${v}" title="${v === 'original' ? 'Original crop' : 'Crop ' + l}">${l}</button>`).join('')
        + `<button class="orient" data-a="orient" title="Swap orientation">${icon('orient')}</button>`;
      asp.addEventListener('click', e => { const b = e.target.closest('button'); if (b) chooseAspect(b.dataset.a); });
      body.appendChild(asp);
    } else if (s.id === 'frame') {
      FRAME_CTLS.forEach(c => body.appendChild(ctlRow(c, {
        frame: true,
        onInput: v => { saveFrame({ [c.k]: v }); syncFrame(); },
        onAuto: () => { saveFrame({ [c.k]: c.k === 'side' ? 1 : 0.5 }); syncFrame(); },
      })));
      const extra = document.createElement('span');
      extra.className = 'sec-x';
      extra.innerHTML = '<span class="muted-label">All exports</span>';
      const sw = document.createElement('button');
      sw.className = 'switch'; sw.id = 'frameSwitch'; sw.setAttribute('role', 'switch'); sw.title = 'White frame (B)';
      sw.onclick = e => { e.stopPropagation(); toggleFrame(); };
      extra.appendChild(sw);
      root.appendChild(section(s.id, s.title, body, extra));
      continue;
    } else {
      s.ctls.forEach(c => body.appendChild(paramRow(c)));
    }
    root.appendChild(section(s.id, s.title, body));
  }
  syncFilms();
}

// Neutralize: the server measures the cast still left in the shadows and the highlights of the current render
// (near-neutral pixels only) and returns the balance that cancels it; applied like any edit (one undo step).
async function neutralize() {
  if (!ed?.cur) return;
  const e0 = ed, btn = $('#neutralBtn');
  btn.disabled = true;
  try {
    const j = await api.post(P.neutralize(e0.p.pid, e0.p.id));
    if (ed !== e0) return;
    const keys = ['shadowWarmth', 'shadowTint', 'highlightWarmth', 'highlightTint'];
    const same = keys.every(k => Math.round(Number(j[k]) || 0) === Math.round(Number(ed.cur[k]) || 0));
    if (same) { toast('Already neutral', { ms: 1800 }); return; }
    for (const k of keys) ed.cur[k] = Math.max(-50, Math.min(50, Math.round(Number(j[k]) || 0)));
    syncAll(); changed(true);
  } catch (err) {
    toast(err.message && err.message.length < 80 ? err.message : "Couldn't measure this photo");
  } finally { btn.disabled = false; }
}

// The Analysis button and popover for the photo on screen (editor). Hidden when there is nothing to show.
function paintAnalysis(e) {
  const d = { aiCritique: e.aiCritique, aiAvailable: e.aiAvailable, aiState: e.aiState, aiError: e.aiError, critique: e.critique };
  $('#critBtn').hidden = !hasAnalysis(d);
  const k = e.key;
  setAnalysis(e.p, d, reviewHost(), () => detail(k, { fresh: true }).then(x => {
    if (ed?.key === k) { ed.critique = x.critique || ed.critique; ed.aiCritique = x.aiCritique ?? ed.aiCritique; ed.aiAvailable = x.aiAvailable; ed.aiState = x.aiState; ed.aiError = x.aiError; }
    return x;
  }), applyCritiqueFix);
}
// The review spread in the editor: the column joins the canvas, the photo (its frame) glides left.
let rvHost = null;
const reviewHost = () => rvHost || (rvHost = { el: $('#editMain'), photo: () => $('#frame'), relayout: () => layout(), btn: $('#critBtn') });

// A fix from the critique, through the normal params path: one undo step, a new render, and the
// critique turns stale on the server. Crop opens the crop tool on the suggested rect (Apply / Cancel).
function applyCritiqueFix(fix) {
  if (!ed?.cur || !fix) return false;
  if (fix.type === 'params') {
    let any = false;
    for (const c of fix.changes || []) {
      const k = c.param, raw = c.to !== undefined ? c.to : c.change;
      if ((k === 'film' || k === 'grainSize') && typeof raw === 'string' && c.to !== undefined) { ed.cur[k] = raw; any = true; continue; }
      const ctl = CTL[k];
      if (!ctl) continue;
      let v;
      if (c.to !== undefined) v = Number(c.to);
      else { const d = Number(String(raw).replace('−', '-')); if (!Number.isFinite(d)) continue; v = (Number(ed.cur[k]) || 0) + d; }
      if (!Number.isFinite(v)) continue;
      v = Math.max(ctl.min, Math.min(ctl.max, Math.round(v / ctl.step) * ctl.step));
      ed.cur[k] = round4(v); any = true;
    }
    if (!any) return false;
    syncAll(); layout(); changed(true);
    return true;
  }
  if (fix.type === 'straighten') {
    // `to` is the resulting rotate (documented); `degrees` alone is taken as the new angle.
    const d = Number(fix.to !== undefined ? fix.to : fix.degrees);
    if (!Number.isFinite(d)) return false;
    ed.cur.rotate = Math.max(-10, Math.min(10, Math.round(d * 10) / 10));
    syncAll(); layout(); changed(true);
    return true;
  }
  if (fix.type === 'crop') return suggestCrop(fix);
  return false;
}
// Show the suggested crop in the crop tool; the crop bar offers Apply and Cancel.
function suggestCrop(fix) {
  const r = Array.isArray(fix.rect) ? { x: fix.rect[0], y: fix.rect[1], w: fix.rect[2], h: fix.rect[3] } : (fix.rect || {});
  if (!(r.w > 0 && r.h > 0)) return false;
  const prev = ed.cur.crop ? clone(ed.cur.crop) : null;
  const portrait = r.h * ed.p.h > r.w * ed.p.w;
  ed.cur.crop = { aspect: fix.aspect || 'original', portrait, x: round4(r.x || 0), y: round4(r.y || 0), w: round4(r.w), h: round4(r.h) };
  ed.cropTrial = { prev };
  setCropMode(true);
  trialBar(true);
  layout();
  return true;
}
function trialBar(on) {
  const done = $('#cbDone'), cancel = $('#cbCancel');
  if (!done || !cancel) return;
  done.textContent = on ? 'Apply' : 'Done';
  cancel.hidden = !on;
}

function syncFilms() {
  const sel = $('#filmSel');
  if (!sel) return;
  const list = films() || FILMS_FALLBACK;
  const cur = sel.value;
  const html = '<option value="">None</option>' + list.map(f => `<option value="${esc(f.path ?? f.id ?? f.name)}">${esc(f.name)}</option>`).join('');
  if (sel._html !== html) { sel._html = html; sel.innerHTML = html; sel.value = cur; }   // library polls don't rebuild it
  if (ed?.cur) syncCtl('film');
}

function fillTrack(input) {
  const min = +input.min, max = +input.max, v = +input.value;
  const z = min < 0 && max > 0 ? -min / (max - min) : 0, p = (v - min) / (max - min);
  input.style.setProperty('--a', (Math.min(z, p) * 100).toFixed(2) + '%');
  input.style.setProperty('--b', (Math.max(z, p) * 100).toFixed(2) + '%');
}

function syncCtl(k) {
  if (!ed?.cur) return;
  if (k === 'film') {
    const sel = $('#filmSel'), v = ed.cur.film || '';
    if (![...sel.options].some(o => o.value === v)) sel.insertAdjacentHTML('beforeend', `<option value="${esc(v)}">${esc(v.split('/').pop().replace(/\.(png|cube)$/i, '').replace(/^(Kodak|Fuji) /, ''))}</option>`);
    sel.value = v;
    return;
  }
  if (k === 'rotate') syncCropBar();
  const e = els[k];
  if (!e) return;
  const v = ed.cur[k], c = e.c;
  const shown = c.invert ? -v || 0 : v;            // slider space (Highlights: Lightroom sign)
  if (parseFloat(e.input.value) !== shown) e.input.value = shown;
  fillTrack(e.input);
  e.out.textContent = c.fmt(shown);
  const a = ed.auto[k], aShown = c.invert ? -a || 0 : a;
  const frac = Math.min(1, Math.max(0, (aShown - c.min) / (c.max - c.min)));
  e.tick.style.left = `calc(5.5px + (100% - 11px) * ${frac})`;
  e.row.classList.toggle('changed', Math.abs(v - a) > 1e-6);
}

function syncAll() {
  if (!ed?.cur) return;
  Object.keys(CTL).forEach(syncCtl);
  syncCtl('film');
  $('#filmSel').disabled = false;
  els.filmStrength.row.classList.toggle('disabled', !ed.cur.film);
  syncGrain();
  syncAspects();
  syncFrame();
}

function syncGrain() {
  if (!ed?.cur) return;
  $$('#grainSize button').forEach(b => b.classList.toggle('on', b.dataset.g === ed.cur.grainSize));
  $('#grainSize').classList.toggle('disabled', !ed.cur.grain);
}

function syncAspects() {
  syncCropBar();
  const crop = ed?.cur?.crop;
  const a = crop ? crop.aspect || 'original' : 'original';
  $$('#aspects button[data-a]').forEach(b => b.classList.toggle('on', b.dataset.a === a && (b.dataset.a !== 'original' || !crop || cropMode)));
  $('#aspects .orient').disabled = !crop || a === 'original' || a === '1:1';
}

function syncFrame() {
  const f = frameSettings();
  $('#frameSwitch').setAttribute('aria-checked', String(f.enabled));
  $('#frameBtn').classList.toggle('on', f.enabled);
  for (const c of FRAME_CTLS) {
    const e = els[c.k];
    e.input.value = f[c.k]; e.out.textContent = c.fmt(f[c.k]); fillTrack(e.input);
    e.row.classList.toggle('disabled', !f.enabled);
  }
}

function toggleFrame() {
  const f = frameSettings();
  saveFrame({ enabled: !f.enabled });
  syncFrame(); layout();
}

// ---------- Opening a photo ----------
export async function showEdit(ctx, pid, id) {
  if (!sameCtx(store.ctx, ctx)) {
    try { await loadContext(ctx); }
    catch (_) { toast("Couldn't open"); go('/', { replace: true }); return; }
  }
  const key = pid + '/' + id;
  const p = store.byKey.get(key);
  if (!p) { go(ctxPath(store.ctx), { replace: true }); return; }
  if (ed && ed.key !== key) flush();
  if (ed?.key === key && ed.cur) { renderStrip(); layout(); return; }
  setCropMode(false, { silent: true });
  setZoom(false, null, { silent: true });
  store.focus = key;
  if (!store.sel.has(key)) { store.sel = new Set([key]); store.anchor = key; }
  ed = { key, id: p.id, p, cur: null, auto: null, shown: null, seq: 0, inflight: 0, preview: null, original: null, clip: null, hints: [], notes: [] };
  $('#editBackName').textContent = store.ctx.name || 'Back';
  $('#editName').textContent = p.file || p.id;
  paintRateBar($('#editRate'), p);
  document.title = `${p.file || p.id} · ${store.ctx.name || 'Darkroom'}`;
  $('#panel').classList.add('loading');
  $('#critBtn').hidden = true;
  setAnalysis(null, null, reviewHost());
  const img = $('#eimg');
  img.style.filter = ''; img.style.transform = '';
  delete img.dataset.failed;
  const first = { src: api.url(p.thumb), region: FULL, base: null };
  gpuShow(false, true);
  $('#clipImg').hidden = true;
  clipOn = false;
  renderStrip();
  // The previous photo stays until this one's thumbnail is decoded (at most 150 ms), never a blank frame.
  const opening = ed;
  await Promise.race([setView(first), new Promise(r => setTimeout(r, 150))]);
  if (ed !== opening) return;
  if (view.src !== first.src) forceView(first);
  paintHints();
  fetchLook();
  // A thin busy line if the details take a while (a proxy being rebuilt, iCloud).
  let slow = setTimeout(() => { slow = 0; busy(1); }, 300);
  const done = () => { if (slow) clearTimeout(slow); else busy(-1); slow = -1; };
  try {
    const d = await detail(key);
    done();
    if (ed?.key !== key) return;
    applyDetail(d);
  } catch (err) {
    done();
    if (ed?.key === key) toast("Couldn't load this photo");
  }
  preloadNeighbours();
}

let retryTimer = null;
function applyDetail(d) {
  clearTimeout(retryTimer);
  ed.cur = norm(d.params);
  ed.base = clone(ed.cur);
  ed.full = d.full || null;
  ed.version = d.version;
  ed.auto = norm(d.auto || d.params);
  ed.shown = norm(d.previewParams || d.params);
  ed.preview = d.preview;
  ed.original = d.original || d.originalPreview || null;
  if (split.on) loadOrig();
  ed.clip = d.clip || d.clipOverlay || null;
  ed.hints = (d.hints || []).map(h => typeof h === 'string' ? h : h.text || h.message).filter(Boolean).slice(0, 2);
  ed.notes = (d.notes || []).filter(Boolean);
  ed.url = null; ed.fullUrl = null; ed.fullParams = null;
  if (d.previewFull) { ed.fullUrl = api.url(d.previewFull); ed.fullParams = { ...ed.shown, crop: null }; }
  $('#panel').classList.remove('loading');
  ed.lookBase = ed.cur.lookAmount;
  ed.critique = d.critique || null;
  ed.aiCritique = d.aiCritique ?? null;
  ed.aiAvailable = d.aiAvailable;
  ed.aiState = d.aiState;
  ed.aiError = d.aiError ?? null;
  paintAnalysis(ed);
  ed.pipeline = d.pipeline || null;
  ed.pipeParams = norm(d.params);
  gpuPrepare(ed);
  syncAll();
  if (d.preview && d.rendered !== false) {
    showPreview(api.url(d.preview)).then(() => ed?.original && preload(api.url(ed.original)));
  } else {
    // Still rendering: keep what's on screen (the thumbnail), no approximation, and ask again.
    ed.shown = ed.cur;
    busy(1);
    const e = ed, key = ed.key;
    retryTimer = setTimeout(async () => {
      busy(-1);
      if (ed !== e) return;
      try { const d2 = await detail(key, { fresh: true }); if (ed === e) applyDetail(d2); } catch (_) {}
    }, 1200);
  }
  paintHints();
  layout();
}

async function showPreview(src) {
  const e = ed;
  await preload(src);
  if (ed !== e) return;
  e.url = src;
  if (!e.shown.crop) { e.fullUrl = src; e.fullParams = e.shown; }
  paintSource();
}

// Which image is on screen, which region of the photo it covers, and what it was rendered with.
// Renders come back already cropped (and straightened); crop mode needs the whole frame, so it uses
// the last uncropped render, else the original proxy (no approximation on that one).
const FULL = { x: 0, y: 0, w: 1, h: 1 };
let view = { src: '', region: FULL, base: null };
function paintSource() {
  if (!ed) return;
  const shownCrop = ed.shown?.crop || null;
  let next;
  if (before) next = { src: api.url(ed.original || ed.preview || ed.p.thumb), region: FULL, base: null };
  else if (!ed.url) next = { src: api.url(ed.p.thumb), region: FULL, base: null };
  else if (cropMode && shownCrop) {
    next = ed.fullUrl ? { src: ed.fullUrl, region: FULL, base: ed.fullParams }
      : { src: api.url(ed.original || ed.preview), region: FULL, base: null };
  } else next = { src: ed.url, region: shownCrop || FULL, base: ed.shown };
  setView(next);
  if (zoom.on && !before) loadFull();
}
// The <img>, `view` (which part it shows, for layout) and the layout change together, once the new
// picture is decoded. Until then the old picture stays, laid out as before.
function setView(next) {
  return swapImg($('#eimg'), next.src, { onFail: 'set', commit: () => { view = next; layout(); } });
}
function forceView(next) {
  const img = $('#eimg');
  delete img.dataset.want; img._swap = null;
  if (img.getAttribute('src') !== next.src) img.src = next.src;
  view = next; layout();
}

function preloadNeighbours() {
  const list = navList(), i = list.findIndex(p => p.key === ed?.key);
  for (const q of [list[i + 1], list[i - 1], list[i + 2]]) {
    if (!q) continue;
    preload(api.url(q.thumb));
    detail(q.key).then(d => preload(api.url(d.preview))).catch(() => {});
  }
}

// ---------- Layout: image, crop, frame ----------
function layout() {
  if (!ed) return;
  const st = $('#stage'), W = st.clientWidth, H = st.clientHeight;
  if (!W || !H) return;
  const pad = Math.round(Math.max(28, Math.min(W, H) * 0.05));
  const aw = W - 2 * pad, ah = H - 2 * pad;
  const A = ed.p.w / ed.p.h;
  const frame = $('#frame'), box = $('#cropBox'), img = $('#eimg'), clip = $('#clipImg');
  const crop = ed.cur?.crop;
  const r = !cropMode && crop ? crop : FULL;          // the part of the photo to show
  const R = view.region;                              // the part the <img> covers
  const cw = A * r.w, ch = r.h;                       // content size, image height = 1
  const f = frameSettings();
  const showFrame = f.enabled && !cropMode && !zoom.on;
  const L = Math.max(cw, ch);
  const s = showFrame ? f.side / 100 * L : 0, t = showFrame ? f.topBottom / 100 * L : 0;
  // Fit, or 100%: one pixel of the full-size photo per device pixel.
  const k = zoom.on ? ed.p.h / (devicePixelRatio || 1) : Math.min(aw / (cw + 2 * s), ah / (ch + 2 * t));
  const fw = (cw + 2 * s) * k, fh = (ch + 2 * t) * k;
  const px = v => Math.round(v * 100) / 100 + 'px';
  frame.classList.toggle('off', !showFrame);
  let fx = (W - fw) / 2, fy = (H - fh) / 2;
  if (zoom.on) {
    // Keep the photo covering the stage where it can; pan within its edges.
    const hx = fw > W ? W / (2 * fw) : 0.5, hy = fh > H ? H / (2 * fh) : 0.5;
    zoom.cx = clamp(zoom.cx, hx, 1 - hx); zoom.cy = clamp(zoom.cy, hy, 1 - hy);
    fx = W / 2 - zoom.cx * fw; fy = H / 2 - zoom.cy * fh;
  }
  // Whole device pixels for the frame and the photo box, so the <img> and the GPU canvas line up exactly.
  const dpr = devicePixelRatio || 1, sn = v => Math.round(v * dpr) / dpr;
  fx = sn(fx); fy = sn(fy);
  zoom.k = k; zoom.fw = fw; zoom.fh = fh; zoom.fx = fx; zoom.fy = fy;
  const bx = sn(s * k), by = sn(t * k), bw = sn(cw * k), bh = sn(ch * k);
  Object.assign(frame.style, { left: px(fx), top: px(fy), width: px(sn(fw)), height: px(sn(fh)) });
  Object.assign(box.style, { left: px(bx), top: px(by), width: px(bw), height: px(bh) });
  geo = { x: fx + bx, y: fy + by, w: bw, h: bh, region: r, W, H };
  const iw = R.w / r.w * bw, ih = R.h / r.h * bh;
  for (const el of [img, clip]) Object.assign(el.style, { width: px(iw), height: px(ih), left: px((R.x - r.x) / r.w * bw), top: px((R.y - r.y) / r.h * bh) });
  if (cropMode) {
    const ui = $('#cropUI');
    Object.assign(ui.style, { left: px(fx), top: px(fy), width: px(sn(fw)), height: px(sn(fh)) });
    paintCropRect();
  }
  applyApprox();
  gpuDraw();
  paintSplit();
}

function applyApprox() {
  const img = $('#eimg'), vig = $('#vig'), clip = $('#clipImg');
  if (!ed?.cur || before || !view.base) { img.style.filter = ''; img.style.transform = ''; clip.style.transform = ''; vig.style.opacity = 0; clip.hidden = true; return; }
  const a = approx(ed.cur, view.base);
  if (a.filter.includes('#wbx')) $('#wbm').setAttribute('values', a.matrix);
  img.style.filter = a.filter;
  let tr = '';
  if (Math.abs(a.rotate) > 1e-6) {
    const th = Math.abs(a.rotate) * Math.PI / 180, W = ed.p.w, H = ed.p.h;
    const sc = Math.max((W * Math.cos(th) + H * Math.sin(th)) / W, (W * Math.sin(th) + H * Math.cos(th)) / H);
    tr = `rotate(${a.rotate.toFixed(2)}deg) scale(${sc.toFixed(4)})`;
  }
  img.style.transform = tr; clip.style.transform = tr;
  vig.style.opacity = a.vignette;
  clip.hidden = !(clipOn && ed.clip);
}

// ---------- Rendering ----------
const renderSoon = debounce(e => sendRender(e), 260);

function changed(now = false) {
  if (!ed?.cur) return;
  applyApprox();
  gpuInteract();
  if (!ed.p.edited) { ed.p.edited = true; }
  syncAspects();
  if (now) { renderSoon.cancel(); sendRender(ed); commit(); } else renderSoon(ed);
}

// ---------- Undo ----------
const clone = o => JSON.parse(JSON.stringify(o));
// Record the change since the last commit as one undo step.
function commit() {
  if (!ed?.cur || !ed.base) return;
  const after = clone(ed.cur);
  if (sameParams(after, ed.base)) return;
  const before = ed.base, key = ed.key;
  ed.base = after;
  pushUndo({ label: 'edit', undo: () => applyParams(key, before), redo: () => applyParams(key, after) });
}
async function applyParams(key, params) {
  if (ed?.key === key && ed.cur) {
    renderSoon.cancel();
    ed.cur = norm(clone(params)); ed.base = clone(ed.cur);
    syncAll(); layout();
    return sendRender(ed);
  }
  const p = store.byKey.get(key);
  if (!p) return;
  store.details.delete(key);
  const j = await api.post(P.params(p.pid, p.id), { params, seq: nextSeq() });
  if (j.thumb) setThumb(key, bust(j.thumb, Date.now() % 1000));
}
function flush() { renderSoon.flush(); }
// Send any pending change now and wait until the server has it (Export, Make This My Look).
async function flushSave() {
  renderSoon.flush();
  const e = ed;
  if (e?.saving) { try { await e.saving; } catch (_) {} }
}

function bust(u, seq) {
  if (!u) return u;
  return u.includes('?') ? u : `${u}?r=${Date.now().toString(36)}${seq}`;
}

function sendRender(e) {
  if (!e?.cur) return Promise.resolve();
  const pr = doRender(e);
  e.saving = pr;
  return pr;
}
async function doRender(e) {
  const seq = ++e.seq;
  const params = { ...e.cur };
  busy(1);
  try {
    const j = await api.post(P.params(e.p.pid, e.p.id), { params, w: shownLong(), seq: nextSeq() });
    if (j.full) e.full = j.full;
    if (j.version != null) e.version = j.version;
    zoom.fullUrl = null;
    if (j.thumb) setThumb(e.key, bust(j.thumb, seq));
    const rendered = norm(j.previewParams || j.params || params);
    // Keep the cached detail in step so coming back to this photo is instant and right.
    store.details.set(e.key, Promise.resolve({ params, auto: e.auto, preview: j.preview || e.preview, previewParams: rendered, original: e.original, clip: e.clip, hints: e.hints, notes: e.notes, pipeline: j.pipeline || e.pipeline, critique: j.critique || e.critique, aiCritique: j.aiCritique !== undefined ? j.aiCritique : e.aiCritique, aiAvailable: j.aiAvailable !== undefined ? j.aiAvailable : e.aiAvailable }));
    if (seq !== e.seq || ed !== e || j.stale) return;
    if (j.pipeline) { e.pipeline = j.pipeline; e.pipeParams = norm(j.params || params); }
    // An edit can make Claude's critique stale: the response says so.
    if (j.aiCritique !== undefined) { e.aiCritique = j.aiCritique; if (j.aiState) e.aiState = j.aiState; if (j.critique) e.critique = j.critique; paintAnalysis(e); }
    if (j.renderError) { renderErrorOnce(j.renderError); return; }
    // The server's resolved values (clamped; Look Amount rescales the look sliders) become the
    // slider state, unless the user has moved on since.
    if (j.params && !renderSoon.pending()) { e.cur = norm(j.params); e.base = clone(e.cur); syncAll(); }
    if (j.preview) {
      const url = api.url(bust(j.preview, seq));
      await preload(url);
      if (seq !== e.seq || ed !== e) return;
      e.preview = j.preview;
      e.shown = rendered;
      e.url = url;
      if (!rendered.crop) { e.fullUrl = url; e.fullParams = rendered; }
      e.lookBase = e.cur.lookAmount;
      paintSource();
      if (!renderSoon.pending()) gpuSettle(url);
    } else { e.shown = rendered; applyApprox(); }
  } catch (err) {
    if (ed === e && seq === e.seq) toast("Couldn't render");
  } finally { busy(-1); }
}

let renderErrorShown = false;
function renderErrorOnce(msg) {
  if (renderErrorShown) return;
  renderErrorShown = true;
  toast(msg.length < 90 ? `Preview unavailable: ${msg}` : 'Preview unavailable', { ms: 6000 });
}

function busy(d) {
  busyCount = Math.max(0, busyCount + d);
  $('#busy').classList.toggle('on', busyCount > 0);
}

async function reset(fromRedo = false) {
  if (!ed?.cur) return;
  const e = ed;
  const prev = clone(e.cur), key = e.key;
  if (!fromRedo) pushUndo({ label: 'reset', undo: () => applyParams(key, prev), redo: async () => { if (ed?.key === key) return reset(true); const p = store.byKey.get(key); if (p) await api.post(P.reset(p.pid, p.id), {}); } });
  renderSoon.cancel();
  e.seq++;
  e.cur = { ...e.auto };
  syncAll(); applyApprox(); layout();
  busy(1);
  try {
    const j = await api.post(P.reset(e.p.pid, e.p.id), { w: shownLong() });
    e.p.edited = false;
    if (j.thumb) setThumb(e.key, bust(j.thumb, e.seq));
    store.details.delete(e.key);
    const d = await detail(e.key, { fresh: true });
    if (ed !== e) return;
    e.auto = norm(d.auto || d.params);
    e.cur = norm(d.params);
    e.base = clone(e.cur);
    e.lookBase = e.cur.lookAmount;
    if (d.pipeline) { e.pipeline = d.pipeline; e.pipeParams = norm(d.params); }
    e.shown = norm(d.previewParams || j.previewParams || d.params);
    syncAll();
    await showPreview(api.url(bust(d.preview, e.seq)));
    layout();
  } catch (_) { toast("Couldn't reset"); }
  finally { busy(-1); }
}

// ---------- Copy / paste ----------
function copy() {
  if (!ed?.cur) return;
  const { crop, rotate, ...rest } = ed.cur;   // geometry stays with each photo
  clipboard = rest;
  toast('Settings copied', { ms: 1600 });
}
async function paste() {
  if (!clipboard || !ed?.cur) { if (!clipboard) toast('Nothing to paste', { ms: 1800 }); return; }
  const keys = store.sel.size > 1 ? [...store.sel] : [ed.key];
  const params = { ...clipboard };
  const by = new Map();
  for (const k of keys) { const p = store.byKey.get(k); if (!p) continue; if (!by.has(p.pid)) by.set(p.pid, []); by.get(p.pid).push(p.id); }
  const befores = new Map();
  await Promise.all(keys.map(async k => {
    if (k === ed.key) { befores.set(k, clone(ed.cur)); return; }
    try { const d = await detail(k); befores.set(k, clone(norm(d.params))); } catch (_) {}
  }));
  try {
    const res = await Promise.all([...by].map(([pid, ids]) => api.post(P.paste(pid), { ids, params, geometry: false }).then(j => ({ pid, j }))));
    for (const k of keys) { store.details.delete(k); const p = store.byKey.get(k); if (p) p.edited = true; }
    let gotThumbs = true;
    for (const { pid, j } of res) {
      if (!j.photos) { gotThumbs = false; continue; }
      j.photos.forEach(x => x.thumb && setThumb(pid + '/' + x.id, x.thumb));
    }
    if (!gotThumbs) refreshThumbs();
    if (keys.includes(ed.key)) {
      Object.assign(ed.cur, params);
      ed.base = clone(ed.cur);
      syncAll(); applyApprox();
      sendRender(ed);
    }
    pushUndo({
      label: 'paste',
      undo: () => Promise.all([...befores].map(([k, prm]) => applyParams(k, prm))),
      redo: () => Promise.all([...befores].map(([k, prm]) => applyParams(k, { ...prm, ...params }))),
    });
    toast(keys.length === 1 ? 'Settings pasted' : `Pasted to ${keys.length} photos`, { ms: 2200 });
  } catch (_) { toast("Couldn't paste settings"); }
}

async function refreshThumbs() {
  if (!store.ctx) return;
  try {
    const focus = store.focus, sel = store.sel;
    await loadContext(store.ctx);
    store.focus = focus; store.sel = sel;
    // Thumbnail URLs may not change after a re-render: always refetch.
    for (const p of store.photos) setThumb(p.key, bust(p.thumb, Date.now() % 1000));
    if (ed) { const np = store.byKey.get(ed.key); if (np) ed.p = np; }
    renderStrip(true);
  } catch (_) {}
}

// ---------- My Look ----------
// Advanced override: this photo's look becomes My Look and learning from Best Work is pinned.
async function updateLookFromPhoto() {
  if (!ed?.cur) return;
  await flushSave();
  const e = ed;
  const fromPhoto = { projectId: e.p.pid, id: e.p.id };
  const params = Object.fromEntries(LOOK_KEYS.map(k => [k, e.cur[k]]));
  // How many photos change: ask the server (dry run); estimate locally if it can't say.
  let impact = null;
  try { impact = await api.post(P.look(), { fromPhoto, params, dryRun: true }); } catch (_) {}
  const projects = store.library?.projects || [];
  const estimate = all => projects.reduce((n, pr) => n + (all ? (pr.count || 0) : Math.max(0, (pr.count || 0) - (pr.edited || 0))), 0);
  const count = all => (impact && typeof impact.unedited === 'number') ? (all ? impact.all : impact.unedited) : estimate(all);
  const label = v => { const n = count(v.all); return n === 1 ? 'Update 1 photo' : `Update ${n} photos`; };
  const n0 = count(false);
  const v = await dialog({
    title: 'Update My Look from This Photo?',
    text: n0 === 0 ? 'All other photos are edited.' : n0 === 1 ? '1 unedited photo will change.' : `${n0} unedited photos will change.`,
    fields: [{ type: 'check', name: 'all', label: 'Include edited photos' }],
    ok: label({ all: false }), okLabel: label, okEnabled: v => count(v.all) > 0,
  });
  if (!v) return;
  const t = toast('Updating My Look…', { spin: true });
  watchLook();
  try {
    await api.post(P.look(), { fromPhoto, params });
    if (v.all) await api.post(P.lookApply(), { scope: 'all' });
    const s = await fetchLook();
    if (s && s.source !== 'pinned') await setPinned(true, { quiet: true });
    store.details = new Map();
    await refreshThumbs();
    loadLibrary().catch(() => {});
    const d = ed && await detail(ed.key, { fresh: true });
    if (ed && d) applyDetail(d);
    t.update('My Look updated', { ms: 3000 });
  } catch (_) { t.update("Couldn't update My Look", { ms: 4000 }); }
}

// ---------- Before / clipping / hints / notes ----------
function setBefore(on) {
  if (before === on || !ed) return;
  before = on;
  gpuSync();
  $('#stageLabel').hidden = !on;
  paintSource();
  paintSplit();
}

// ---------- Before / after split ----------
// \ (tap) or the Before button splits the photo: before (the original) left of a divider, after (the
// edit) right, in the same framing: the original gets the edit's straighten and crop, so the two line
// up, and the white frame stays on the after side. Drag anywhere on the photo (at 1:1: the grip, as a
// drag there pans), click to put the divider there, or use the arrow keys on the grip. Holding \ shows
// the whole original, as before. The divider stays where it was left, between photos and for the session.
// Plain images and clip-path only: no WebGL, so it works the same in the app's safe mode.
const split = { on: false, s: (() => { try { const v = parseFloat(sessionStorage.getItem('photolab.split')); return v >= 0 && v <= 1 ? v : 0.5; } catch (_) { return 0.5; } })(), dragging: false };
function setSplit(on) {
  if (!ed && on) return;
  split.on = !!on;
  const b = $('#beforeBtn');
  b.classList.toggle('on', split.on); b.setAttribute('aria-pressed', String(split.on));
  if (split.on) loadOrig();
  paintSplit();
}
let splitRaf = 0;
function setSplitAt(s, save = true) {
  split.s = Math.max(0, Math.min(1, s));
  if (save) { try { sessionStorage.setItem('photolab.split', String(Math.round(split.s * 1000) / 1000)); } catch (_) {} }
  // One paint per frame, however fast the pointer moves.
  if (!splitRaf) splitRaf = requestAnimationFrame(() => { splitRaf = 0; paintSplit(); });
}
// The original proxy, swapped in once decoded (no flash when moving between photos).
function loadOrig() {
  const img = $('#origImg'), e = ed, url = e?.original ? api.url(e.original) : null;
  if (!url) { paintSplit(); return; }
  if (img.getAttribute('src') === url) { img.dataset.key = e.key; paintSplit(); return; }
  if (img.dataset.want !== url) swapImg(img, url, { onFail: 'set', commit: () => { img.dataset.key = e.key; paintSplit(); } });
}
// The part of the photo that is on screen (all of it, or the visible part at 1:1).
function visibleBox() {
  if (!geo) return null;
  const x0 = Math.max(0, geo.x), y0 = Math.max(0, geo.y), x1 = Math.min(geo.W, geo.x + geo.w), y1 = Math.min(geo.H, geo.y + geo.h);
  return x1 > x0 && y1 > y0 ? { x: x0, y: y0, w: x1 - x0, h: y1 - y0 } : null;
}
function paintSplit() {
  const el = $('#split');
  // Only once this photo's original is decoded: never the previous photo's, never a stand-in.
  const show = split.on && !!ed?.cur && !before && !cropMode && !!geo && $('#origImg').dataset.key === ed.key;
  if (el.hidden === show) el.hidden = !show;
  if (!show) return;
  const vb = visibleBox();
  if (!vb) return;
  const px = v => Math.round(v * 100) / 100 + 'px';
  const xd = vb.x + split.s * vb.w;
  // The original, laid out as the whole photo behind the crop window, turned by the edit's straighten.
  const r = geo.region, wrap = $('#splitOrig'), img = $('#origImg');
  Object.assign(wrap.style, { left: px(geo.x), top: px(geo.y), width: px(geo.w), height: px(geo.h), clipPath: `inset(0 ${px(Math.max(0, geo.x + geo.w - xd))} 0 0)` });
  const iw = geo.w / r.w, ih = geo.h / r.h;
  Object.assign(img.style, { width: px(iw), height: px(ih), left: px(-r.x / r.w * geo.w), top: px(-r.y / r.h * geo.h) });
  const rot = Number(ed.cur.rotate) || 0;
  let tr = '';
  if (Math.abs(rot) > 1e-6) {
    const th = Math.abs(rot) * Math.PI / 180, W = ed.p.w, H = ed.p.h;
    const sc = Math.max((W * Math.cos(th) + H * Math.sin(th)) / W, (W * Math.sin(th) + H * Math.cos(th)) / H);
    // The server turns positive angles counter-clockwise (pipeline.geometry.rotateDirection); CSS turns
    // them clockwise.
    tr = `rotate(${(-rot).toFixed(2)}deg) scale(${sc.toFixed(4)})`;
  }
  if (img.style.transform !== tr) img.style.transform = tr;
  // The white frame shows on the after side only: the stage covers it left of the divider.
  const mask = $('#splitMask'), framed = !$('#frame').classList.contains('off');
  mask.hidden = !framed;
  if (framed) {
    const m = 48, mx0 = zoom.fx - m, mw = zoom.fw + 2 * m;
    Object.assign(mask.style, { left: px(mx0), top: px(zoom.fy - m), width: px(mw), height: px(zoom.fh + 2 * m), clipPath: `inset(0 ${px(Math.max(0, mx0 + mw - xd))} 0 0)` });
  }
  Object.assign($('#splitBar').style, { left: px(xd), top: px(vb.y), height: px(vb.h) });
  $('#splitGrip').setAttribute('aria-valuenow', String(Math.round(split.s * 100)));
  Object.assign($('#splitL').style, { left: px(vb.x + 12), top: px(vb.y + 12) });
  Object.assign($('#splitR').style, { left: px(vb.x + vb.w - 12), top: px(vb.y + 12) });
  el.classList.toggle('dragging', split.dragging);
}
function splitFromX(clientX) {
  const vb = visibleBox(), st = $('#stage').getBoundingClientRect();
  return vb ? (clientX - st.left - vb.x) / vb.w : split.s;
}
function initSplit() {
  const grip = $('#splitGrip'), bar = $('#splitBar');
  // The grip, or the line itself (a 16 px wide hit area), drags the divider.
  bar.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    e.preventDefault(); e.stopPropagation();
    grip.focus({ preventScroll: true });
    split.dragging = true; bar.setPointerCapture(e.pointerId); paintSplit();
  });
  bar.addEventListener('pointermove', e => { if (split.dragging) setSplitAt(splitFromX(e.clientX), false); });
  const end = () => { if (!split.dragging) return; split.dragging = false; setSplitAt(split.s); };
  bar.addEventListener('pointerup', end);
  bar.addEventListener('pointercancel', end);
  grip.addEventListener('keydown', e => {
    const step = e.shiftKey ? 0.1 : 0.02;
    const to = { ArrowLeft: split.s - step, ArrowRight: split.s + step, ArrowDown: split.s - step, ArrowUp: split.s + step, Home: 0, End: 1, PageDown: split.s - 0.1, PageUp: split.s + 0.1 }[e.key];
    if (to === undefined) return;
    e.preventDefault(); e.stopPropagation();
    setSplitAt(to);
  });
}

function toggleClip() {
  if (!ed?.clip) { toast('No clipping', { ms: 1400 }); return; }
  clipOn = !clipOn;
  const c = $('#clipImg');
  if (clipOn) c.src = api.url(ed.clip);
  applyApprox();
  gpuSync();
}

function paintHints() {
  const box = $('#hints');
  const list = (ed?.hints || []).filter(h => !dismissed.has(ed.key + '|' + h));
  box.innerHTML = list.map(h => `<span class="hint">${icon('warn')}<span>${esc(h)}</span><button title="Dismiss" data-h="${esc(h)}">${ICONS.close}</button></span>`).join('');
  box.querySelectorAll('button').forEach(b => b.onclick = () => {
    dismissed.add(ed.key + '|' + b.dataset.h);
    ls.set('dismissedHints', [...dismissed].slice(-500));
    paintHints();
  });
}
// ---------- Crop ----------
function setCropMode(on, { silent = false } = {}) {
  if (on && !ed?.cur) return;
  if (!on && ed?.cropTrial) {
    const t = ed.cropTrial;
    ed.cropTrial = null;
    trialBar(false);
    if (!t.apply && ed.cur) { ed.cur.crop = t.prev; renderSoon.cancel(); sendRender(ed); }
  }
  if (on && zoom.on) setZoom(false, null, { silent: true });
  cropMode = on;
  $('#cropBtn').classList.toggle('on', on);
  $('#cropUI').hidden = !on;
  $('#cropBar').hidden = !on;
  if (on && gpu && gpuReady()) gpuShow(true);
  if (!silent) { syncAspects(); paintSource(); }
}

function chooseAspect(a) {
  if (!ed?.cur) return;
  const A = ed.p.w / ed.p.h;
  const crop = ed.cur.crop;
  if (a === 'orient') {
    if (!crop || !crop.aspect || crop.aspect === 'original') return;
    const portrait = !crop.portrait;
    const cx = crop.x + crop.w / 2, cy = crop.y + crop.h / 2;
    ed.cur.crop = { aspect: crop.aspect, portrait, ...fitCrop(aspectRatio(crop.aspect, portrait), A, cx, cy) };
  } else if (a === 'original') {
    ed.cur.crop = null;
  } else {
    const portrait = crop && crop.aspect === a ? !!crop.portrait : ed.p.h > ed.p.w;
    const cx = crop ? crop.x + crop.w / 2 : 0.5, cy = crop ? crop.y + crop.h / 2 : 0.5;
    ed.cur.crop = { aspect: a, portrait, ...fitCrop(aspectRatio(a, portrait), A, cx, cy) };
    if (!cropMode) setCropMode(true, { silent: true });
  }
  syncAspects(); layout(); changed(true);
}

function paintCropRect() {
  const ui = $('#cropUI'), rect = $('#cropRect');
  const c = ed.cur?.crop || { x: 0, y: 0, w: 1, h: 1 };
  const W = ui.clientWidth || parseFloat(ui.style.width), H = ui.clientHeight || parseFloat(ui.style.height);
  Object.assign(rect.style, { left: c.x * W + 'px', top: c.y * H + 'px', width: c.w * W + 'px', height: c.h * H + 'px' });
}

function initCropDrag() {
  const ui = $('#cropUI'), rect = $('#cropRect');
  let drag = null;
  rect.addEventListener('pointerdown', e => {
    if (!ed?.cur || e.button !== 0) return;
    e.preventDefault();
    const A = ed.p.w / ed.p.h;
    const c0 = ed.cur.crop ? { ...ed.cur.crop } : { aspect: 'original', portrait: false, x: 0, y: 0, w: 1, h: 1 };
    drag = { h: e.target.dataset.h || null, sx: e.clientX, sy: e.clientY, c0, A, W: ui.clientWidth, H: ui.clientHeight };
    rect.setPointerCapture(e.pointerId);
  });
  rect.addEventListener('pointermove', e => {
    if (!drag) return;
    const { c0, W, H, A } = drag;
    const dx = (e.clientX - drag.sx) / W, dy = (e.clientY - drag.sy) / H;
    let c;
    if (!drag.h) {
      c = { ...c0, x: clamp(c0.x + dx, 0, 1 - c0.w), y: clamp(c0.y + dy, 0, 1 - c0.h) };
    } else {
      const R = aspectRatio(c0.aspect, c0.portrait) || (c0.w * A / c0.h);   // pixel w/h
      const sx = drag.h.includes('e') ? 1 : -1, sy = drag.h.includes('s') ? 1 : -1;
      const ax = sx > 0 ? c0.x : c0.x + c0.w, ay = sy > 0 ? c0.y : c0.y + c0.h;
      const r = ui.getBoundingClientRect();
      const px = (e.clientX - r.left) / W, py = (e.clientY - r.top) / H;
      let wpx = Math.max(sx * (px - ax) * W, sy * (py - ay) * H * R);
      const maxW = Math.min(sx > 0 ? (1 - ax) * W : ax * W, (sy > 0 ? (1 - ay) * H : ay * H) * R);
      wpx = clamp(wpx, Math.min(40, maxW), maxW);
      const w = wpx / W, h = wpx / R / H;
      c = { ...c0, w, h, x: sx > 0 ? ax : ax - w, y: sy > 0 ? ay : ay - h };
    }
    ed.cur.crop = { ...c, x: round4(c.x), y: round4(c.y), w: round4(c.w), h: round4(c.h) };
    paintCropRect();
  });
  const end = () => {
    if (!drag) return;
    drag = null;
    const c = ed.cur.crop;
    if (c && c.aspect === 'original' && c.w > 0.999 && c.h > 0.999) ed.cur.crop = null;
    changed(true);
  };
  rect.addEventListener('pointerup', end);
  rect.addEventListener('pointercancel', end);
  rect.addEventListener('dblclick', () => {
    if (!ed?.cur) return;
    const c = ed.cur.crop;
    if (!c || !c.aspect || c.aspect === 'original') ed.cur.crop = null;
    else ed.cur.crop = { aspect: c.aspect, portrait: c.portrait, ...fitCrop(aspectRatio(c.aspect, c.portrait), ed.p.w / ed.p.h) };
    paintCropRect(); changed(true);
  });
}
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

// ---------- Filmstrip ----------
function navList() {
  const v = visible();
  if (!ed || v.some(p => p.key === ed.key)) return v;
  // The current photo just left the view (e.g. rejected in Selects): keep it until we move on.
  const all = store.ctx?.kind === 'project' && store.sort === 'street' ? v : store.photos;
  const out = all.filter(p => p === ed.p || v.includes(p));
  if (!out.includes(ed.p)) out.push(ed.p);
  return out;
}

const STRIP_H = 56;
const stripW = p => Math.round(STRIP_H * (p.aspect > 0 ? p.aspect : p.w / p.h));
function stripCellInner(p) {
  return `<img alt="" loading="lazy" decoding="async" draggable="false" style="width:${stripW(p)}px;height:${STRIP_H}px"><span class="mk">${stripMarks(p)}</span>`;
}
function stripMarks(p, animate) {
  const mo = marksFor(store.ctx?.kind);
  return mo ? marksSVG(p, stripW(p), STRIP_H, { ...mo, pad: 2, animate }) : '';
}
function renderStrip(force = false) {
  const list = navList();
  const key = (store.ctx ? ctxPath(store.ctx) : '') + '|' + list.map(p => p.key).join(',');
  const strip = $('#strip');
  if (force || key !== stripKey) {
    stripKey = key;
    strip.innerHTML = list.map(p => `<div class="fcell${p.flag === 'reject' ? ' rejected' : ''}" data-key="${esc(p.key)}" title="${esc(p.file || p.id)}">${stripCellInner(p)}</div>`).join('');
    $$('.fcell', strip).forEach(c => setImg(c.querySelector('img'), api.url(store.byKey.get(c.dataset.key).thumb)));
  }
  paintStripSel();
}
function paintStripSel(scroll = true) {
  $$('#strip .fcell').forEach(c => {
    c.classList.toggle('cur', c.dataset.key === ed?.key);
    c.classList.toggle('sel', store.sel.has(c.dataset.key) && c.dataset.key !== ed?.key);
  });
  const cur = scroll && ed && $(`#strip .fcell[data-key="${CSS.escape(ed.key)}"]`);
  if (cur) {
    const s = $('#strip'), l = cur.offsetLeft, w = cur.offsetWidth;
    if (l < s.scrollLeft + 40 || l + w > s.scrollLeft + s.clientWidth - 40) s.scrollTo({ left: l - s.clientWidth / 2 + w / 2, behavior: 'smooth' });
  }
}
function updateStripCell(p) {
  const c = $(`#strip .fcell[data-key="${CSS.escape(p.key)}"]`);
  if (!c) return;
  c.classList.toggle('rejected', p.flag === 'reject');
  c.querySelector('.mk').innerHTML = stripMarks(p, takeMarked(p.key));
  setImg(c.querySelector('img'), api.url(p.thumb));
}
// The cell under the pointer: the cell itself, or the nearest one when the press lands in a gap or the padding.
function stripCellAt(e) {
  const strip = $('#strip');
  const c = e.target.closest?.('.fcell');
  if (c) return c;
  const r = strip.getBoundingClientRect();
  if (e.clientY > r.top + strip.clientHeight) return null;    // the scrollbar
  let best = null, bd = 12;
  for (const x of strip.children) {
    const b = x.getBoundingClientRect();
    const d = e.clientX < b.left ? b.left - e.clientX : e.clientX > b.right ? e.clientX - b.right : 0;
    if (d < bd) { bd = d; best = x; }
  }
  return best;
}
function onStripDown(e) {
  if (e.button !== 0 || !ed) return;
  const c = stripCellAt(e);
  if (!c) return;
  e.preventDefault();            // no native image drag, no text selection, no focus jump
  hideTip();
  const key = c.dataset.key;
  const order = navList().map(p => p.key);
  if (e.metaKey || e.ctrlKey) {
    // Add to / remove from the selection (for Paste); the photo on screen stays put.
    if (key === ed.key) return;
    if (store.sel.has(key)) store.sel.delete(key); else store.sel.add(key);
    store.sel.add(ed.key);
    store.anchor = key;
    paintStripSel(false); return;
  }
  if (e.shiftKey) {
    const from = store.anchor && order.includes(store.anchor) ? store.anchor : ed.key;
    const a = order.indexOf(from), b = order.indexOf(key);
    const [lo, hi] = a < b ? [a, b] : [b, a];
    store.sel = new Set(order.slice(lo, hi + 1));
    store.sel.add(ed.key);
    paintStripSel(false); return;
  }
  store.sel = new Set([key]); store.anchor = key;
  if (key === ed.key) { paintStripSel(false); return; }
  openPhoto(key);
}
function openPhoto(key) {
  const p = store.byKey.get(key);
  if (!p || key === ed?.key) return;
  go(editPath(store.ctx, p), { replace: true });
}
function step(d) {
  const list = navList(), i = list.findIndex(p => p.key === ed?.key);
  const q = list[i + d];
  if (q) { store.sel = new Set([q.key]); store.anchor = q.key; openPhoto(q.key); }
}

function backToGrid() {
  flush();
  setCropMode(false, { silent: true });
  go(ctxPath(store.ctx));
}

export function leaveEdit() {
  hideCritique();
  flush();
  setBefore(false);
  setCropMode(false, { silent: true });
  ed = null;
}

// ---------- Keyboard ----------
export function editKey(e) {
  const k = e.key, lower = k.toLowerCase(), mod = e.metaKey || e.ctrlKey;
  if (mod && lower === 'c') { if (String(getSelection())) return false; e.preventDefault(); copy(); return true; }
  if (mod && lower === 'v') { e.preventDefault(); paste(); return true; }
  if (mod && lower === 'a') { e.preventDefault(); store.sel = new Set(navList().map(p => p.key)); paintStripSel(); return true; }
  if (mod) return false;
  // \ tapped toggles the split; held (or Shift-\) shows the whole original until it is let go.
  if (e.code === 'Backslash' || k === '\\' || k === '|') {
    e.preventDefault();
    if (e.repeat) return true;
    clearTimeout(bsHold.t);
    bsHold.down = true; bsHold.held = !!e.shiftKey;
    if (e.shiftKey) setBefore(true);
    else bsHold.t = setTimeout(() => { if (bsHold.down) { bsHold.held = true; setBefore(true); } }, 280);
    return true;
  }
  if (k === 'ArrowLeft' || k === 'ArrowUp') { e.preventDefault(); step(-1); return true; }
  if (k === 'ArrowRight' || k === 'ArrowDown') { e.preventDefault(); step(1); return true; }
  if (lower === 'b') { e.preventDefault(); toggleFrame(); return true; }
  if (lower === 'a') { e.preventDefault(); if (!$('#critBtn').hidden) toggleCritique(reviewHost()); return true; }
  if (lower === 'r') { e.preventDefault(); setCropMode(!cropMode); return true; }
  if (lower === 'j') { e.preventDefault(); toggleClip(); return true; }
  if (lower === 'z') { e.preventDefault(); setZoom(!zoom.on); return true; }
  if (k === 'Enter' && cropMode) { e.preventDefault(); setCropMode(false); return true; }
  if (k === 'Escape') {
    e.preventDefault();
    if (cropMode) setCropMode(false);
    else if (zoom.on) setZoom(false);
    else backToGrid();
    return true;
  }
  if (lower === 'g') { e.preventDefault(); backToGrid(); return true; }
  return ratingKey(e, ed ? [ed.key] : [], () => step(1));
}
const bsHold = { down: false, held: false, t: 0 };
export function editKeyUp(e) {
  if (e.code === 'Backslash' || e.key === '\\' || e.key === '|') {
    clearTimeout(bsHold.t);
    const wasHeld = bsHold.held, wasDown = bsHold.down;
    bsHold.down = false; bsHold.held = false;
    if (wasHeld) setBefore(false); else if (wasDown) setSplit(!split.on);
    return true;
  }
  return false;
}


// ---------- 1:1 zoom ----------
// Z or a click toggles 100% at the clicked point; drag pans. The full-size render swaps in when ready.
function setZoom(on, at = null, { silent = false } = {}) {
  if (on && (!ed?.cur || cropMode)) return;
  if (on) gpuShow(false);
  if (on && at && zoom.k) {
    // Keep the clicked point under the pointer.
    const st = $('#stage').getBoundingClientRect();
    const u = (at.x - st.left - zoom.fx) / zoom.fw, v = (at.y - st.top - zoom.fy) / zoom.fh;
    const k1 = ed.p.h / (devicePixelRatio || 1), r = ed.cur.crop || FULL;
    const fw1 = ed.p.w / ed.p.h * r.w * k1, fh1 = r.h * k1;
    zoom.cx = u + (st.width / 2 - (at.x - st.left)) / fw1;
    zoom.cy = v + (st.height / 2 - (at.y - st.top)) / fh1;
  } else if (on) { zoom.cx = 0.5; zoom.cy = 0.5; }
  zoom.on = on;
  $('#stage').classList.toggle('zoomed', on);
  if (silent) return;
  if (on) loadFull(); else paintSource();
  layout();
}
// The full-size edited render (rendered on demand by the server); none in the mock.
const fullUrlOf = e => (e.full ? api.url(e.full) : null);
async function loadFull() {
  const e = ed, url = e && fullUrlOf(e);
  if (!url || before) return;
  if (zoom.fullUrl === url) { setView({ ...view, src: url }); return; }
  busy(1);
  const img = await preload(url);
  busy(-1);
  if (ed !== e || !zoom.on || !img?.naturalWidth) return;
  // Same shape as the preview: same region; whole frame: the full photo.
  const ar = img.naturalWidth / img.naturalHeight;
  const shownCrop = e.shown?.crop || null;
  const prevAr = shownCrop ? (e.p.w * shownCrop.w) / (e.p.h * shownCrop.h) : e.p.w / e.p.h;
  const next = Math.abs(ar - prevAr) > 0.02 && Math.abs(ar - e.p.w / e.p.h) <= 0.02 ? { ...view, src: url, region: FULL } : { ...view, src: url };
  zoom.fullUrl = url;
  setView(next);
}
function initZoom() {
  const stage = $('#stage');
  let drag = null;
  stage.addEventListener('pointerdown', e => {
    if (e.button !== 0 || cropMode || !ed?.cur || e.target.closest('.cropbar, .crop-ui, button')) return;
    drag = { x: e.clientX, y: e.clientY, cx: zoom.cx, cy: zoom.cy, moved: false };
    stage.setPointerCapture(e.pointerId);
  });
  stage.addEventListener('pointermove', e => {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!drag.moved && Math.hypot(dx, dy) < 4) return;
    drag.moved = true;
    // Split, not at 1:1: a drag anywhere on the photo moves the divider.
    if (split.on && !zoom.on && !$('#split').hidden) { if (!split.dragging) { split.dragging = true; paintSplit(); } setSplitAt(splitFromX(e.clientX), false); return; }
    if (!zoom.on) return;
    stage.classList.add('panning');
    zoom.cx = drag.cx - dx / zoom.fw; zoom.cy = drag.cy - dy / zoom.fh;
    layout();
  });
  const end = e => {
    if (!drag) return;
    const d = drag; drag = null;
    stage.classList.remove('panning');
    if (split.dragging) { split.dragging = false; setSplitAt(split.s); return; }
    if (!d.moved && e.type === 'pointerup') {
      // Split: a click on the photo puts the divider there (Z still zooms).
      if (split.on && !$('#split').hidden) { setSplitAt(splitFromX(e.clientX)); return; }
      setZoom(!zoom.on, { x: e.clientX, y: e.clientY });
    }
  };
  stage.addEventListener('pointerup', end);
  stage.addEventListener('pointercancel', end);
}


// ---------- Picture loading state ----------
// Whatever sets #eimg's src, the box shows a spinner if it takes a while, falls back to the photo's
// render or thumbnail if that file fails, and says so (calmly) if nothing can be shown.
function initImageState() {
  const img = $('#eimg'), box = $('#cropBox');
  let t = 0;
  const start = () => {
    clearTimeout(t);
    box.classList.remove('broken');
    if (img.complete && img.naturalWidth) { box.classList.remove('waiting'); return; }
    t = setTimeout(() => { if (!(img.complete && img.naturalWidth)) box.classList.add('waiting'); }, 250);
  };
  new MutationObserver(start).observe(img, { attributes: true, attributeFilter: ['src'] });
  img.addEventListener('load', () => { clearTimeout(t); box.classList.remove('waiting', 'broken'); });
  img.addEventListener('error', () => {
    clearTimeout(t);
    const cur = img.getAttribute('src'), thumb = ed && api.url(ed.p.thumb);
    if (!cur) return;
    for (const alt of [ed?.url, thumb]) if (alt && alt !== cur && !img.dataset.failed?.includes(alt)) {
      img.dataset.failed = (img.dataset.failed || '') + ' ' + cur;
      img.src = alt; return;
    }
    box.classList.remove('waiting'); box.classList.add('broken');
  });
}

// ---------- Real-time GPU preview ----------
// While you edit, the photo is drawn by the GPU from the unedited proxy every frame. The server render
// still runs; when it arrives the view stays on the GPU picture unless the two differ visibly.
let gpu = null, geo = null, gpuOn = false, gpuRaf = 0, gpuToken = 0;
const gpuStats = { frames: [], lastInput: 0, latency: [] };
function initGPU() {
  // In Baseline Darkroom.app (WebKit) the WebGL preview is off unless asked for: localStorage photolab.gpu = '1'.
  let want = true;
  if (isApp) { try { want = localStorage.getItem('photolab.gpu') === '1'; } catch (_) { want = false; } }
  if (want) {
    const cv = document.createElement('canvas');
    cv.className = 'gpu'; cv.id = 'gpuCanvas'; cv.setAttribute('aria-hidden', 'true');
    $('#frame').after(cv);
    try { gpu = createGPU(cv); } catch (_) { gpu = null; }
    if (!gpu) cv.remove();
  }
  window.__gpu = { stats: gpuStats, get gpu() { return gpu; } };
}
const lutUrl = film => {
  if (!film) return null;
  const f = (films() || []).find(x => (x.path ?? x.id) === film);
  return f?.url ? api.url(f.url) : '/luts/' + film.split('/').map(encodeURIComponent).join('/');
};
function gpuReady() {
  if (!gpu || !ed?.cur || !ed.pipeline || !ed.gpuSrc || gpu.state.src !== ed.gpuSrc) return false;
  const needLut = ed.cur.film && ed.cur.filmStrength > 0;
  return !needLut || gpu.state.lut === lutUrl(ed.cur.film);
}
async function gpuPrepare(e) {
  if (!gpu || !e.original || !e.pipeline) return;      // no pipeline (older server, mock): CSS approximation
  const token = ++gpuToken;
  e.gpuSrc = api.url(e.original);
  const t0 = performance.now();
  try {
    await gpu.setSource(e.gpuSrc);
    if (e.cur.film && e.cur.filmStrength > 0) await gpu.setFilm(lutUrl(e.cur.film));
  } catch (_) { return; }
  if (token !== gpuToken || ed !== e) return;
  gpuStats.firstFrame = performance.now() - t0;
  if (cropMode) gpuShow(true);
}
// The look sliders on screen are the server's values at the Look Amount they were resolved with.
function effective(e) {
  const p = { ...e.cur }, k = (p.lookAmount ?? 100) / (e.lookBase || 100);
  if (k !== 1) for (const key of LOOK_KEYS) if (typeof p[key] === 'number' && key !== 'grain') p[key] *= k;
  return p;
}
// What to draw: the server's pipeline, with the fields of any slider that has moved since recomputed.
function curPipeline(e = ed) { return pipelineFor(effective(e), e.pipeline, e.pipeParams, lutUrl); }
// Long edge of the photo on screen, in device pixels: the server renders the interactive preview at that size.
function shownLong() { return geo ? Math.round(Math.max(geo.w, geo.h) * (devicePixelRatio || 1)) : undefined; }
function gpuDraw() {
  if (!gpuOn || !gpu || !geo || !ed?.cur) return;
  if (gpuRaf) return;
  gpuRaf = requestAnimationFrame(() => {
    gpuRaf = 0;
    if (!gpuOn || !geo || !ed?.cur) return;
    const cv = $('#gpuCanvas'), dpr = devicePixelRatio || 1;
    const W = Math.round(geo.W * dpr), H = Math.round(geo.H * dpr);
    if (cv.width !== W || cv.height !== H) { cv.width = W; cv.height = H; }
    const t0 = performance.now();
    gpu.render(curPipeline(), { box: { x: geo.x * dpr, y: geo.y * dpr, w: geo.w * dpr, h: geo.h * dpr }, region: geo.region, aspect: ed.p.w / ed.p.h });
    gpuStats.frames.push(performance.now() - t0);
    if (gpuStats.frames.length > 600) gpuStats.frames.shift();
    if (gpuStats.lastInput) { gpuStats.latency.push(performance.now() - gpuStats.lastInput); gpuStats.lastInput = 0; if (gpuStats.latency.length > 600) gpuStats.latency.shift(); }
  });
}
function gpuShow(on, instant = false) {
  const cv = $('#gpuCanvas');
  gpuOn = on && !!gpu && !!cv;
  if (!cv) return;
  cv.classList.toggle('on', gpuOn);
  cv.classList.toggle('instant', instant);
  if (gpuOn) gpuDraw();
}
function gpuSync() { if (before || clipOn || zoom.on) gpuShow(false, true); }
function gpuInteract() {
  if (!gpu || before || clipOn || zoom.on || !gpuReady()) {
    // Film not loaded yet? Load it, and draw as soon as it is there.
    if (gpu && ed?.cur?.film && ed.cur.filmStrength > 0 && gpu.state.src === ed.gpuSrc) gpu.setFilm(lutUrl(ed.cur.film)).then(() => gpuInteract()).catch(() => {});
    return;
  }
  gpuStats.lastInput = performance.now();
  if (!gpuOn) gpuShow(true);
  else gpuDraw();
}
// The GPU picture is only for while a slider moves. Once the server render of the latest change is
// decoded under the canvas, fade back to it: the resting picture is always the exact render.
async function gpuSettle(url) {
  if (!gpuOn || !gpu || cropMode) return;
  const e = ed;
  const img = $('#eimg');
  try { if (img.getAttribute('src') === url) await img.decode(); else await preload(url); } catch (_) {}
  if (ed !== e || !gpuOn || cropMode || renderSoon.pending() || e.url !== url) return;
  gpuShow(false);
}

// ---------- Crop bar ----------
function initCropBar() {
  const bar = $('#cropBar');
  bar.innerHTML = `<div class="aspects" id="cbAspects">${ASPECTS.map(([v, l]) => `<button data-a="${v}">${l}</button>`).join('')}<button class="orient" data-a="orient" title="Swap orientation">${icon('orient')}</button></div>
    <span class="cb-sep"></span><label class="cb-l" for="cbRot">Straighten</label><input type="range" id="cbRot" min="-10" max="10" step="0.1" aria-label="Straighten"><output id="cbRotOut"></output>
    <span class="cb-sep"></span><button class="btn" id="cbCancel" hidden>Cancel</button><button class="btn primary" id="cbDone">Done</button>`;
  bar.querySelector('#cbAspects').addEventListener('click', e => { const b = e.target.closest('button'); if (b) chooseAspect(b.dataset.a); });
  const rot = bar.querySelector('#cbRot');
  rot.addEventListener('input', () => { if (!ed?.cur) return; ed.cur.rotate = +rot.value; fillTrack(rot); syncCtl('rotate'); changed(); });
  rot.addEventListener('change', () => { flush(); commit(); });
  rot.addEventListener('dblclick', () => { if (!ed?.cur) return; ed.cur.rotate = ed.auto.rotate; syncCtl('rotate'); changed(true); });
  rot.addEventListener('keydown', e => { if (e.key.startsWith('Arrow')) e.stopPropagation(); });
  bar.querySelector('#cbDone').onclick = () => {
    if (ed?.cropTrial) { ed.cropTrial.apply = true; setCropMode(false); changed(true); return; }
    setCropMode(false);
  };
  bar.querySelector('#cbCancel').onclick = () => setCropMode(false);
}
function syncCropBar() {
  if (!ed?.cur) return;
  const crop = ed.cur.crop, a = crop ? crop.aspect || 'original' : 'original';
  $$('#cbAspects button[data-a]').forEach(b => b.classList.toggle('on', b.dataset.a === a));
  $('#cbAspects .orient').disabled = !crop || a === 'original' || a === '1:1';
  const rot = $('#cbRot');
  rot.value = ed.cur.rotate; fillTrack(rot);
  $('#cbRotOut').textContent = CTL.rotate.fmt(ed.cur.rotate);
}

