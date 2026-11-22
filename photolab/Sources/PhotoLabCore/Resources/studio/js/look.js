// My Look learns from Best Work. GET /api/look says where the look comes from right now
// ({source: "learned"|"starter"|"pinned", favorites, updatedAt}); the editor shows it as one line.
// When favorites change the server relearns in the background (debounced) and re-renders unedited
// photos: we poll the status until it moves, then pick up the new thumbnails as they arrive.
import { api, P } from './api.js';
import { on, emit, syncThumbs, loadLibrary } from './store.js';
import { toast } from './ui.js';

export const look = { data: null };
let supported = true;
let stamp = null;

const stampOf = j => j ? [j.source, j.favorites, j.updatedAt, JSON.stringify(j.params || null)].join('|') : '';

// Fetch the status. Returns it, or null when the server doesn't have the endpoint (older backend).
export async function fetchLook() {
  if (!supported) return null;
  try {
    const j = await api.get(P.look());
    if (!j || !j.source) throw Object.assign(new Error('no look state'), { status: 404 });
    const s = stampOf(j), moved = stamp !== null && s !== stamp;
    stamp = s;
    look.data = j;
    emit('look', j);
    if (moved) followRenders();
    return j;
  } catch (err) {
    if (err.status === 404 || err.status === 405) { supported = false; look.data = null; emit('look', null); }
    return null;
  }
}

// Favorites changed (or Pin was released): ask again a few times while the server relearns.
let watchTimer = 0, watchUntil = 0;
export function watchLook(ms = 45000) {
  if (!supported) return;
  watchUntil = Math.max(watchUntil, Date.now() + ms);
  if (watchTimer) return;
  const tick = async () => {
    watchTimer = 0;
    if (document.hidden) { watchTimer = setTimeout(tick, 3000); return; }
    const before = stamp;
    await fetchLook();
    if (stamp !== before) watchUntil = Math.min(watchUntil, Date.now() + 8000);   // moved: one more look, then stop
    if (Date.now() < watchUntil) watchTimer = setTimeout(tick, 3000);
  };
  watchTimer = setTimeout(tick, 1500);
}

// The look moved: unedited photos re-render in the background, visible ones first. Swap in new
// thumbnails as their versions change; stop after a quiet minute.
let renderTimer = 0, renderUntil = 0;
function followRenders() {
  renderUntil = Date.now() + 60000;
  if (renderTimer) return;
  const tick = async () => {
    renderTimer = 0;
    let changed = [];
    if (!document.hidden) { try { changed = await syncThumbs(); } catch (_) {} }
    if (changed.length) { renderUntil = Math.max(renderUntil, Date.now() + 20000); emit('rerendered', changed); }
    if (Date.now() < renderUntil) renderTimer = setTimeout(tick, 3000);
    else loadLibrary().catch(() => {});      // project covers
  };
  renderTimer = setTimeout(tick, 1000);
}

export async function setPinned(pinned, { quiet = false } = {}) {
  if (!supported) return;
  const prev = look.data;
  if (prev) { look.data = { ...prev, source: pinned ? 'pinned' : prev.favorites >= 5 ? 'learned' : 'starter' }; emit('look', look.data); }
  try {
    await api.post(P.lookPin(), { pinned });
    await fetchLook();
    if (!pinned) watchLook();          // learning resumes: the look may move
  } catch (_) {
    look.data = prev; emit('look', prev);
    if (!quiet) toast(pinned ? "Couldn't pin My Look" : "Couldn't unpin My Look");
  }
}

export function initLook() {
  on('favorites', () => watchLook());
  document.addEventListener('visibilitychange', () => { if (!document.hidden && supported) fetchLook(); });
}
