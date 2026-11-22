// Baseline Darkroom: boot, routing between the three screens, global keyboard.
import { api } from './api.js';
import { store, loadLibrary, on } from './store.js';
import { $, isTyping, isDialogOpen, menuOpen, toast, initTooltips, hideTip, closeMenu, isApp } from './ui.js';
import { hydrateIcons } from './icons.js';
import { current, onRoute } from './router.js';
import { initLibrary, showLibrary, libraryKey, attachFolder } from './library.js';
import { initSide, highlight } from './side.js';
import { initGrid, showGrid, gridKey } from './grid.js';
import { initEdit, showEdit, editKey, editKeyUp, leaveEdit } from './edit.js';
import { undo, redo } from './undo.js';
import { glyph } from './marks.js';
import { initLook, fetchLook } from './look.js';
import { initUpdates } from './updates.js';
import { initOnboarding, setupOpen, openSettings } from './onboarding.js';
import { exportSheetOpen } from './exportsheet.js';

let view = null;

async function boot() {
  // Baseline Darkroom.app (WebKit): calmer compositing (see styles.css "app mode"), no WebGL preview.
  document.documentElement.classList.toggle('app', isApp);
  hydrateIcons();
  document.querySelectorAll('[data-glyph]').forEach(el => { el.innerHTML = glyph(el.dataset.glyph, 16); });
  initTooltips();
  await api.init();
  document.documentElement.dataset.mode = api.mode;
  initLibrary(); initSide(); initGrid(); initEdit();
  initLook(); fetchLook(); initUpdates();
  on('library', engineWarning);
  try { await loadLibrary(); } catch (_) { toast("Couldn't reach Darkroom"); }
  initOnboarding();
  window.studio = Object.assign(window.studio || {}, { openSettings });
  onRoute(route);
  route(current());
  window.addEventListener('keydown', onKey);
  window.addEventListener('keyup', e => { if (view === 'edit') editKeyUp(e); });
  initDrop();
  // No enter animations on first load: transitions switch on after the first painted frame.
  requestAnimationFrame(() => requestAnimationFrame(() => document.documentElement.classList.remove('preload')));
}

// RawTherapee missing or broken, or renders that keep failing: said once per state, with the fix in Settings.
let engineWarned = null;
function engineWarning(lib) {
  const e = lib?.engine;
  if (!e) return;
  const state = e.problem || (e.failing >= 3 ? 'failing' : null);
  if (state === engineWarned) return;
  engineWarned = state;
  if (!state) return;
  if (e.problem) toast(String(e.error || "RawTherapee can't run").split(';')[0], { ms: 12000, action: 'Settings', onAction: () => openSettings() });
  else toast("Photos keep failing to render. Darkroom will try them again later.", { ms: 9000 });
}

async function route(r) {
  hideTip(); closeMenu();
  const next = r.view;
  if (view === 'edit' && next !== 'edit') leaveEdit();
  $('#v-library').hidden = next !== 'library';
  $('#v-grid').hidden = next !== 'grid';
  $('#v-edit').hidden = next !== 'edit';
  $('#side').hidden = next === 'edit';
  $('#loupe').hidden = true;
  view = next;
  highlight(r);
  if (next === 'library') { document.title = 'Darkroom'; await showLibrary(); }
  else if (next === 'grid') await showGrid(r.ctx);
  else await showEdit(r.ctx, r.pid, r.id);
}

function onKey(e) {
  if (isDialogOpen() || menuOpen() || setupOpen() || exportSheetOpen()) return;
  if ((e.metaKey || e.ctrlKey) && e.key === ',') { e.preventDefault(); openSettings(); return; }
  if (isTyping(e)) return;
  if (libraryKey(e)) return;
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z' && !e.altKey) {
    e.preventDefault();
    if (e.shiftKey) redo(); else undo();
    return;
  }
  if (view === 'grid') gridKey(e);
  else if (view === 'edit') editKey(e);
  else if (view === 'library') {
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      const cards = [...document.querySelectorAll('#libGrid .card')];
      const i = cards.indexOf(document.activeElement);
      const j = i < 0 ? 0 : Math.max(0, Math.min(cards.length - 1, i + (e.key === 'ArrowRight' ? 1 : -1)));
      cards[j]?.focus(); e.preventDefault();
    }
  }
}

// Dropping a folder: the Mac app handles the drop natively and calls window.studio.attached().
// In a plain browser there is no folder path, so offer the Attach dialog instead.
function initDrop() {
  const veil = $('#dropVeil');
  let depth = 0;
  const hasFiles = e => [...(e.dataTransfer?.types || [])].includes('Files');
  window.addEventListener('dragenter', e => { if (!hasFiles(e)) return; e.preventDefault(); depth++; veil.hidden = false; });
  window.addEventListener('dragleave', e => { if (!hasFiles(e)) return; depth = Math.max(0, depth - 1); if (!depth) veil.hidden = true; });
  window.addEventListener('dragover', e => { if (hasFiles(e)) e.preventDefault(); });
  window.addEventListener('drop', e => {
    if (!hasFiles(e)) return;
    e.preventDefault(); depth = 0; veil.hidden = true;
    const f = e.dataTransfer.files?.[0];
    if (f && f.path) window.studio.attachPath(f.path);
    else attachFolder();
  });
}

window.addEventListener('contextmenu', e => { if (!e.target.closest('input, .notes')) e.preventDefault(); });
void store;
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true }); else boot();
