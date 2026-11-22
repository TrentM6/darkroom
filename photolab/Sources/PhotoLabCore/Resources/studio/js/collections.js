// Collections: bodies of work put together by hand, from any shoots, in your own order.
//   B                      add the selection to the current collection (the last one you added to; asks
//                          for a name the first time)
//   right-click            Add to <collection> / New Collection… / (inside one) Remove from Collection
//   drag onto the sidebar  add to that collection
// A collection holds references: removing a photo from it, or deleting it, never touches a file.
import { api, P } from './api.js';
import { store, loadLibrary, ls, emit } from './store.js';
import { toast, dialog } from './ui.js';
import { go } from './router.js';

export const collections = () => store.library?.collections || [];
let target = ls.get('colTarget', null);
export const targetCollection = () => collections().find(c => c.id === target) || null;
function setTarget(id) { target = id; ls.set('colTarget', id); }
const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
const refsOf = keys => keys.map(k => store.byKey.get(k)).filter(Boolean).map(p => ({ projectId: p.pid, id: p.id }));
const show = c => () => go(`/c/col/${encodeURIComponent(c.id)}`);

export async function newCollection(keys = []) {
  const v = await dialog({ title: 'New Collection', text: keys.length ? `With ${plural(keys.length, 'photo')}.` : '',
    fields: [{ name: 'name', placeholder: 'Name, e.g. New York Street' }], ok: 'Create', okEnabled: v => !!v.name });
  if (!v || !v.name) return null;
  try {
    const c = await api.post(P.collections(), { name: v.name, items: refsOf(keys) });
    setTarget(c.id);
    await loadLibrary();
    emit('collections', c.id);
    toast(keys.length ? `Added ${plural(keys.length, 'photo')} to ${c.name}` : `Made ${c.name}`, { action: 'Show', onAction: show(c), ms: 4000 });
    return c;
  } catch (err) { toast(err.message && err.message.length < 80 ? err.message : "Couldn't make the collection"); return null; }
}

export async function addTo(cid, keys) {
  const items = refsOf(keys);
  if (!items.length) return;
  try {
    const c = await api.post(P.colAdd(cid), { items });
    setTarget(cid);
    await loadLibrary();
    emit('collections', cid);
    const msg = c.added ? `Added ${plural(c.added, 'photo')} to ${c.name}` : `Already in ${c.name}`;
    toast(msg, { action: 'Show', onAction: show(c), ms: 3500 });
  } catch (_) { toast("Couldn't add to the collection"); }
}

/** B: the current collection, or a new one the first time. */
export function addToTarget(keys) {
  const t = targetCollection();
  return t ? addTo(t.id, keys) : newCollection(keys);
}

export async function removeFrom(cid, keys, after) {
  const items = refsOf(keys);
  if (!items.length) return;
  try {
    const c = await api.post(P.colRemove(cid), { items });
    await loadLibrary();
    await after?.();
    toast(`Removed ${plural(items.length, 'photo')} from ${c.name}`, {
      action: 'Undo', ms: 5000,
      onAction: async () => { await api.post(P.colAdd(cid), { items }).catch(() => {}); await loadLibrary(); await after?.(); },
    });
  } catch (_) { toast("Couldn't remove from the collection"); }
}

/** Menu items for a selection: add to each collection, or a new one. */
export function addMenuItems(keys, exceptId = null) {
  const cs = collections().filter(c => c.id !== exceptId);
  const t = targetCollection();
  const items = cs.slice(0, 10).map(c => ({ label: `Add to ${c.name}`, key: t && t.id === c.id ? 'B' : undefined, run: () => addTo(c.id, keys) }));
  items.push({ label: 'New Collection…', key: t ? undefined : 'B', run: () => newCollection(keys) });
  return items;
}

export async function renameCollection(c) {
  const v = await dialog({ title: 'Rename Collection', fields: [{ name: 'name', value: c.name }], ok: 'Rename', okEnabled: v => !!v.name });
  if (!v || !v.name || v.name === c.name) return;
  try { await api.patch(P.collection(c.id), { name: v.name }); await loadLibrary(); } catch (_) { toast("Couldn't rename"); }
}

export async function deleteCollection(c, inside) {
  const v = await dialog({ title: `Delete “${c.name}”?`, text: 'Only the collection goes. The photos stay in their projects and on disk.', ok: 'Delete', danger: true });
  if (!v) return;
  try {
    await api.del(P.collection(c.id));
    if (target === c.id) setTarget(null);
    await loadLibrary();
    if (inside) go('/');
  } catch (_) { toast("Couldn't delete"); }
}
