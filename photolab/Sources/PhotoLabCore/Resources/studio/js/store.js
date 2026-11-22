// Shared state. The current "context" is a project, All Selects or Best Work; photos are keyed
// "<projectId>/<photoId>" so collections can mix projects.
import { api, P, nextSeq } from './api.js';
import { toast } from './ui.js';
import { sameCtx } from './router.js';
import { pushUndo } from './undo.js';

const ls = {
  get(k, d) { try { const v = localStorage.getItem('photolab.' + k); return v == null ? d : JSON.parse(v); } catch (_) { return d; } },
  set(k, v) { try { localStorage.setItem('photolab.' + k, JSON.stringify(v)); } catch (_) {} },
};
export { ls };

const listeners = new Map();
export function on(ev, fn) { if (!listeners.has(ev)) listeners.set(ev, new Set()); listeners.get(ev).add(fn); }
export function emit(ev, data) { listeners.get(ev)?.forEach(fn => { try { fn(data); } catch (e) { console.error(e); } }); }

const FILTERS = ['all', 'selects', 'favorites', 'unflagged', 'rejected'];
let f0 = ls.get('filter', 'all'); if (f0 === 'picks') f0 = 'selects'; if (!FILTERS.includes(f0)) f0 = 'all';

export const store = {
  library: null,
  ctx: null,             // {kind: 'project'|'selects'|'best', pid?, name}
  project: null,         // the project payload when ctx.kind === 'project'
  photos: [],
  byKey: new Map(),
  details: new Map(),    // key -> Promise<detail>
  filter: f0,            // project filter
  pfilter: 'all',        // All Selects / Best Work: one project, or 'all' (remembered per view)
  sort: 'time',
  size: ls.get('size', 190),
  sel: new Set(),        // keys
  focus: null,           // key
  anchor: null,
  _vis: null,
};
export const keyOf = p => p.pid + '/' + p.id;
// key -> Set of mark kinds applied by the last user action (consumed by the next draw).
export const justMarked = new Map();
export function takeMarked(key) { const k = justMarked.get(key); justMarked.delete(key); return k; }

// Contact sheet (film strips) or grid, remembered per project and per collection. Film strips are the
// default; earlier choices were reset to them once (view.migrated = 1).
(() => {
  try {
    if (ls.get('view.migrated', 0) >= 1) return;
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const k = localStorage.key(i);
      if (k && k.startsWith('photolab.view.') && k !== 'photolab.view.migrated') localStorage.removeItem(k);
    }
    ls.set('view.migrated', 1);
  } catch (_) {}
})();
export function viewMode(pid) { return ls.get('view.' + pid, 'sheet') === 'grid' ? 'grid' : 'sheet'; }
export function setViewMode(pid, v) { ls.set('view.' + pid, v); emit('view'); }

// ---------- Normalisation (lenient with the server's JSON) ----------
export function normFlag(f) {
  if (f === 'pick' || f === 'picked' || f === 1 || f === true) return 'pick';
  if (f === 'reject' || f === 'rejected' || f === -1) return 'reject';
  return null;
}
function parseTime(t) {
  if (t == null) return null;
  if (typeof t === 'number') return new Date(t < 1e12 ? t * 1000 : t);
  const d = new Date(String(t).replace(/^(\d{4}):(\d{2}):(\d{2})[ T]/, '$1-$2-$3T'));
  return isNaN(d) ? null : d;
}
export function normPhoto(p, pid, projectName) {
  const time = parseTime(p.time ?? p.captureTime ?? p.date);
  const o = {
    ...p,
    id: String(p.id),
    pid: String(p.projectId ?? p.pid ?? pid),
    projectName: p.projectName ?? projectName ?? '',
    w: p.w ?? p.width ?? 3, h: p.h ?? p.height ?? 2,
    t: time ? time.getTime() : 0,
    timeLabel: time ? time.toTimeString().slice(0, 5) : '',
    rating: Math.max(0, Math.min(5, Number(p.rating) || 0)),
    flag: normFlag(p.flag),
    favorite: !!(p.favorite ?? p.fav),
    edited: !!p.edited,
    burst: p.burst ?? p.burstId ?? null,
    moment: p.moment ?? p.groupId ?? null,
    hint: Array.isArray(p.hint) ? p.hint[0] : (p.hint || null),
    streetScore: typeof p.streetScore === 'number' ? p.streetScore : (p.streetScore?.total ?? 0),
  };
  if (o.favorite) o.flag = 'pick';
  o.key = keyOf(o);
  return o;
}

// ---------- Library ----------
export async function loadLibrary() {
  const j = await api.get(P.library());
  // A project whose folder is gone is "missing", whatever its analysis state.
  for (const p of j.projects || []) {
    if (p.missing === true) p.status = 'missing';
    if (p.status && typeof p.status === 'object') { p.done = p.status.done; p.total = p.status.total; p.status = p.status.state; }
    if (p.status === 'done') p.status = 'ready';
  }
  store.library = j;
  emit('library', j);
  return j;
}
export const films = () => (store.library?.films?.length ? store.library.films : null);
export const ctxName = ctx => ctx.kind === 'selects' ? 'All Selects' : ctx.kind === 'best' ? 'Best Work'
  : ctx.kind === 'col' ? (store.library?.collections?.find(c => c.id === ctx.cid)?.name || 'Collection')
  : (store.library?.projects?.find(p => String(p.id) === ctx.pid)?.name || store.project?.name || '');

// ---------- Context ----------
const ctxUrl = ctx => ctx.kind === 'selects' ? P.selects() : ctx.kind === 'best' ? P.best() : ctx.kind === 'col' ? P.collection(ctx.cid) : P.project(ctx.pid);
export async function loadContext(ctx, { keepSelection = true } = {}) {
  const same = sameCtx(store.ctx, ctx);
  let photos, name;
  if (ctx.kind === 'project') {
    const j = await api.get(P.project(ctx.pid));
    store.project = { ...j, id: String(j.id ?? ctx.pid) };
    name = j.name;
    photos = (j.photos || []).map(p => normPhoto(p, ctx.pid, j.name)).sort((a, b) => a.t - b.t || a.id.localeCompare(b.id));
  } else {
    const j = await api.get(ctxUrl(ctx));
    store.project = null;
    name = ctx.kind === 'col' ? (j.name || ctxName(ctx)) : ctxName(ctx);
    photos = (j.photos || []).map(p => normPhoto(p));
  }
  store.ctx = { ...ctx, name };
  store.photos = photos;
  store.byKey = new Map(photos.map(p => [p.key, p]));
  if (!same) {
    store.details = new Map();
    // The project filter is remembered per collection; it falls back to all when that project has no photos here.
    const pf = ctx.kind === 'project' ? 'all' : ls.get('pfilter.' + ctx.kind, 'all');
    store.pfilter = pf !== 'all' && photos.some(p => p.pid === pf) ? pf : 'all';
  }
  if (!same || !keepSelection) { store.sel = new Set(); store.focus = null; store.anchor = null; }
  for (const k of [...store.sel]) if (!store.byKey.has(k)) store.sel.delete(k);
  if (store.focus && !store.byKey.has(store.focus)) store.focus = null;
  invalidate();
  emit('context', store.ctx);
  return store.ctx;
}

export function invalidate() { store._vis = null; }

export function matches(p) {
  const kind = store.ctx?.kind;
  if (kind === 'selects') return p.flag === 'pick' && (store.pfilter === 'all' || p.pid === store.pfilter);
  if (kind === 'best') return p.favorite && (store.pfilter === 'all' || p.pid === store.pfilter);
  if (kind === 'col') return store.pfilter === 'all' || p.pid === store.pfilter;
  switch (store.filter) {
    case 'selects': return p.flag === 'pick';
    case 'favorites': return p.favorite;
    case 'unflagged': return !p.flag;
    case 'rejected': return p.flag === 'reject';
    default: return true;
  }
}
export function visible() {
  if (store._vis) return store._vis;
  let v = store.photos.filter(matches);
  if (store.ctx?.kind === 'project' && store.sort === 'street') v = [...v].sort((a, b) => b.streetScore - a.streetScore || a.t - b.t);
  store._vis = v;
  return v;
}

export function setFilter(f) { store.filter = f; ls.set('filter', f); invalidate(); emit('view'); }
export function setPFilter(pid) {
  store.pfilter = pid;
  if (store.ctx && store.ctx.kind !== 'project') ls.set('pfilter.' + store.ctx.kind, pid);
  invalidate(); emit('view');
}
export function setSort(s) { store.sort = s; ls.set('sort', s); invalidate(); emit('view'); }

export function detail(key, { fresh = false } = {}) {
  const p = store.byKey.get(key);
  if (!p) return Promise.reject(new Error('no photo'));
  if (!fresh && store.details.has(key)) return store.details.get(key);
  const pr = api.get(P.photo(p.pid, p.id)).catch(err => { store.details.delete(key); throw err; });
  store.details.set(key, pr);
  return pr;
}

// ---------- Marks ----------
// change: {flag: 'pick'|'reject'|null} | {favorite: bool}. Star ratings are not part of the UI: the
// backend's stored rating is never sent or changed from here.
// A favorite is always a pick; rejecting or unflagging clears the favorite.
function applyMark(p, c) {
  if ('flag' in c) { p.flag = c.flag; if (c.flag !== 'pick') p.favorite = false; }
  if ('favorite' in c) { p.favorite = c.favorite; if (c.favorite) p.flag = 'pick'; }
}
export async function rate(keys, change, { undoable = true } = {}) {
  change = Object.fromEntries(Object.entries(change).filter(([k]) => k === 'flag' || k === 'favorite'));
  const ps = keys.map(k => store.byKey.get(k)).filter(Boolean);
  if (!ps.length || !Object.keys(change).length) return;
  const before = ps.map(p => [p, p.flag, p.favorite]);
  if (undoable) {
    // Undo puts every photo back exactly as it was (grouped by identical previous marks).
    const prev = new Map();
    for (const [p, f, fav] of before) {
      const k = JSON.stringify([f, fav]);
      if (!prev.has(k)) prev.set(k, { change: { flag: f, favorite: fav }, keys: [] });
      prev.get(k).keys.push(p.key);
    }
    const keysNow = ps.map(p => p.key);
    pushUndo({
      label: 'marks',
      undo: () => Promise.all([...prev.values()].map(g => rate(g.keys, g.change, { undoable: false }))),
      redo: () => rate(keysNow, change, { undoable: false }),
    });
  }
  // Which marks were just applied, so views can draw them on (once).
  const kinds = new Set();
  if (change.flag === 'pick') kinds.add('pick');
  if (change.flag === 'reject') kinds.add('reject');
  if (change.favorite) kinds.add('favorite');
  ps.forEach(p => { applyMark(p, change); justMarked.set(p.key, kinds); emit('photo', p); });
  invalidate();
  emit('rated', ps.map(p => p.key));
  // My Look learns from Best Work: any favorite that came or went.
  const favChanged = before.some(([p, , fav]) => p.favorite !== fav);
  const body = { ...change };
  if ('flag' in body) body.flag = body.flag || 'none';
  const byPid = new Map();
  for (const p of ps) { if (!byPid.has(p.pid)) byPid.set(p.pid, []); byPid.get(p.pid).push(p.id); }
  try {
    await Promise.all([...byPid].map(([pid, ids]) => api.post(P.rate(pid), { ids, ...body, seq: nextSeq() })));
    if ('favorite' in change || 'flag' in change) loadLibrary().catch(() => {});
    if (favChanged) emit('favorites');
  } catch (err) {
    for (const [p, f, fav] of before) { p.flag = f; p.favorite = fav; emit('photo', p); }
    invalidate(); emit('rated', ps.map(p => p.key));
    toast("Couldn't save marks");
  }
}

// Background re-renders (My Look followed new favorites): fetch the open context again and swap in
// thumbnails whose version changed. Returns the keys that changed. Edits in flight are untouched.
export async function syncThumbs() {
  const ctx = store.ctx;
  if (!ctx) return [];
  const j = await api.get(ctx.kind === 'project' ? P.project(ctx.pid) : ctxUrl(ctx));
  if (store.ctx !== ctx) return [];
  const changed = [];
  for (const raw of j.photos || []) {
    const pid = String(raw.projectId ?? raw.pid ?? ctx.pid), key = pid + '/' + raw.id;
    const p = store.byKey.get(key);
    if (!p || !raw.thumb || raw.thumb === p.thumb) continue;
    store.details.delete(key);
    if (raw.edited !== undefined) p.edited = !!raw.edited;
    setThumb(key, raw.thumb);
    changed.push(key);
  }
  return changed;
}

// Bump a photo's thumbnail after a render.
export function setThumb(key, thumb) {
  const p = store.byKey.get(key);
  if (!p || !thumb) return;
  p.thumb = thumb;
  emit('photo', p);
}

// ---------- Settings ----------
export function frameSettings() {
  const f = store.library?.frame || {};
  return { enabled: f.enabled ?? true, side: num(f.side, 1), topBottom: num(f.topBottom ?? f.top_bottom, 0.5) };
}
function num(v, d) { const n = Number(v); return isFinite(n) ? n : d; }
let settingsTimer = null;
export function saveFrame(frame) {
  store.library = { ...(store.library || {}), frame: { ...frameSettings(), ...frame } };
  emit('frame', frameSettings());
  clearTimeout(settingsTimer);
  settingsTimer = setTimeout(async () => {
    try { await api.put(P.settings(), { frame: frameSettings() }); }
    catch (_) { toast("Couldn't save frame settings"); }
  }, 350);
}
