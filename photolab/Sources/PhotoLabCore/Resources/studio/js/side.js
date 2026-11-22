// Sidebar: Projects · All Selects · Best Work, then each attached folder with its shoots.
import { store, on, ls } from './store.js';
import { $, $$, esc, openMenu } from './ui.js';
import { icon } from './icons.js';
import { go, current } from './router.js';
import { groupedProjects, projectMenu, reveal } from './library.js';
import { newCollection, renameCollection, deleteCollection } from './collections.js';

export function initSide() {
  $$('#side [data-nav]').forEach(b => b.onclick = () => go(b.dataset.nav === 'projects' ? '/' : `/c/${b.dataset.nav}`));
  const list = $('#sideProjects');
  list.addEventListener('click', e => {
    const t = e.target.closest('[data-node]');
    if (t) { toggleNode(t.dataset.node); return; }
    const b = e.target.closest('[data-pid]');
    if (!b) return;
    const p = store.library?.projects?.find(x => String(x.id) === b.dataset.pid);
    if (p?.status === 'missing') { const r = b.getBoundingClientRect(); projectMenu(p, r.left + 20, r.bottom, null); return; }
    go(`/p/${encodeURIComponent(b.dataset.pid)}`);
  });
  list.addEventListener('contextmenu', e => {
    const b = e.target.closest('[data-pid], [data-sid]');
    if (!b) return;
    e.preventDefault();
    if (b.dataset.pid) {
      const p = store.library?.projects?.find(x => String(x.id) === b.dataset.pid);
      if (p) projectMenu(p, e.clientX, e.clientY, null);
    } else {
      const s = store.library?.sources?.find(x => String(x.id) === b.dataset.sid);
      if (s) openMenu(e.clientX, e.clientY, [{ label: 'Show in Finder', disabled: !s.path, run: () => reveal(s.path) }]);
    }
  });
  // Collections: open one, make one, rename or delete one (right-click).
  const cols = $('#sideCols');
  cols.addEventListener('click', e => {
    if (e.target.closest('[data-act="new-col"]')) { newCollection(); return; }
    const b = e.target.closest('[data-cid]');
    if (b) go(`/c/col/${encodeURIComponent(b.dataset.cid)}`);
  });
  cols.addEventListener('contextmenu', e => {
    const b = e.target.closest('[data-cid]');
    if (!b) return;
    e.preventDefault();
    const c = (store.library?.collections || []).find(x => x.id === b.dataset.cid);
    const inside = current().ctx?.kind === 'col' && current().ctx.cid === c?.id;
    if (c) openMenu(e.clientX, e.clientY, [{ label: 'Rename…', run: () => renameCollection(c) }, { label: 'Delete…', run: () => deleteCollection(c, inside) }]);
  });
  on('library', render);
  $('#settingsBtn').onclick = () => window.studio?.openSettings?.();
}

const busy = p => p.status && !['ready', 'missing', 'error'].includes(p.status);

function render() {
  // Link folders (a collection's own photos) aren't listed as projects, but their marks count in All Selects and
  // Best Work, which gather them too.
  const all = store.library?.projects || [];
  const ps = all.filter(p => !p.linked);
  const sum = k => all.reduce((n, p) => n + (Number(p[k]) || 0), 0);
  const txt = (id, v) => { const el = $(id), t = String(v || ''); if (el.textContent !== t) el.textContent = t; };
  txt('#nProjects', ps.length);
  txt('#nSelects', sum('picks'));
  txt('#nBest', all.some(p => p.favorites != null) ? sum('favorites') : store.library?.bestCount);
  // Patched only when something changed: the 5 s library poll never rebuilds the list.
  const html = groupedProjects().map(g => treeHTML(g)).join('');
  const cs = store.library?.collections || [];
  const colHtml = `<div class="side-src side-colhead"><span class="t">Collections</span><button class="side-add" data-act="new-col" title="New Collection" aria-label="New Collection">${icon('plus')}</button></div>`
    + (cs.length ? cs.map(c => `<button class="side-item side-col" data-cid="${esc(c.id)}" title="${esc(c.name)}">${icon('stack', 'ic')}<span class="t">${esc(c.name)}</span><span class="n">${c.count || ''}</span></button>`).join('')
      : `<button class="side-item side-col empty" data-act="new-col"><span class="t">New Collection…</span></button>`);
  const colsEl = $('#sideCols');
  if (colsEl._html !== colHtml) { colsEl._html = colHtml; colsEl.innerHTML = colHtml; }
  const list = $('#sideProjects');
  if (list._html !== html) { list._html = html; list.innerHTML = html; }
  // Low disk: one calm line, no numbers.
  const note = $('#sideNote');
  const hide = !store.library?.engine?.paused;
  if (note.hidden !== hide) note.hidden = hide;
  const nt = hide ? '' : 'Paused: disk full';
  if (note.textContent !== nt) note.textContent = nt;
  highlight(current());
}

// ---------- Folder tree ----------
// Each attached folder, and every folder inside it that holds shoots (November 2025, October, …), is a
// group you can fold away, so a hundred shoots stay a short list. Open/closed is remembered per group;
// until you choose, a big library starts folded. The group holding the shoot you're in opens itself.
const GENERIC = new Set(['output', 'outputs', 'capture', 'selects', 'export', 'exports', 'jpg', 'jpgs', 'jpeg', 'jpegs', 'edits', 'processed', 'final', 'finals']);
let openState = ls.get('sideOpen', {});
const parts = path => String(path || '').split('/').filter(Boolean);
function shootDirs(p, source) {
  // the folders between the attached folder and the shoot (the shoot's own folder, and a generic "Output" under it, excluded)
  let f = parts(p.folder || p.path);
  if (f.length && GENERIC.has(f[f.length - 1].trim().toLowerCase())) f = f.slice(0, -1);
  f = f.slice(0, -1);
  // A folder attached on its own (no attached parent) is one row: never its path from the top of the disk.
  if (!source) return [];
  const root = parts(source.path);
  return root.every((x, i) => f[i] === x) ? f.slice(root.length) : [];
}
function buildTree(g) {
  const top = { kids: [], items: [], key: 'src:' + (g.source ? g.source.id : 'loose'), name: g.source ? g.source.name : 'Folders', count: 0, path: g.source?.path };
  const find = (node, name) => node.kids.find(k => k.name === name);
  for (const p of g.projects) {
    let node = top; top.count++;
    for (const d of shootDirs(p, g.source)) {
      let k = find(node, d);
      if (!k) { k = { kids: [], items: [], key: node.key + '/' + d, name: d, count: 0 }; node.kids.push(k); node.items.push({ node: k }); }
      k.count++; node = k;
    }
    node.items.push({ p });
  }
  return top;
}
const total = () => (store.library?.projects || []).length;
function isOpen(node, depth) {
  if (node.key in openState) return !!openState[node.key];
  return depth === 0;       // folders inside an attached folder start folded; the one you're in opens itself
}
function containsCurrent(node) {
  const r = current();
  if (r.ctx?.kind !== 'project') return false;
  const walk = n => n.items.some(i => i.p ? String(i.p.id) === r.ctx.pid : walk(i.node));
  return walk(node);
}
function toggleNode(key) {
  const node = lastNodes.get(key);
  const now = node ? (isOpen(node.n, node.depth) || containsCurrent(node.n)) : true;
  openState = { ...openState, [key]: !now };
  ls.set('sideOpen', openState);
  render();
}
const lastNodes = new Map();
const CHEV = '<svg class="chev" viewBox="0 0 24 24" aria-hidden="true"><path d="m9 6 6 6-6 6"/></svg>';
function treeHTML(g) {
  const top = buildTree(g);
  const out = [];
  const projectRow = (p, depth) => {
    const miss = p.status === 'missing';
    const tail = busy(p) ? '<span class="dot" title="Analyzing"></span>' : `<span class="n">${p.count ?? ''}</span>`;
    return `<button class="side-item${miss ? ' missing' : ''}" style="--d:${depth}" data-pid="${esc(p.id)}" title="${esc(miss ? 'Folder missing' : p.name)}"><span class="t">${esc(p.name)}</span>${tail}</button>`;
  };
  const walk = (node, depth) => {
    lastNodes.set(node.key, { n: node, depth });
    const open = isOpen(node, depth) || containsCurrent(node);
    const head = depth === 0
      ? `<button class="side-src${open ? ' open' : ''}" data-node="${esc(node.key)}"${g.source ? ` data-sid="${esc(g.source.id)}" title="${esc(node.path || node.name)}"` : ''} aria-expanded="${open}">${CHEV}<span class="t">${esc(node.name)}</span><span class="n">${open ? '' : node.count}</span></button>`
      : `<button class="side-item side-dir${open ? ' open' : ''}" style="--d:${depth - 1}" data-node="${esc(node.key)}" aria-expanded="${open}" title="${esc(node.name)}">${CHEV}${icon('folder', 'ic fic')}<span class="t">${esc(node.name)}</span><span class="n" title="${node.count} shoots">${open ? '' : node.count}</span></button>`;
    out.push(head);
    if (!open) return;
    // Folders first, then the shoots that sit loose at this level (like the Finder); each keeps the chosen sort.
    for (const it of node.items) if (!it.p) walk(it.node, depth + 1);
    for (const it of node.items) if (it.p) out.push(projectRow(it.p, depth));
  };
  walk(top, 0);
  return out.join('');
}

export function highlight(r) {
  const nav = r.view === 'library' ? 'projects' : r.ctx?.kind === 'project' ? null : r.ctx?.kind;
  // Active item: filled icon (cross-faded), plus the background as a static cue.
  $$('#side [data-nav]').forEach(b => { const on = b.dataset.nav === nav; b.classList.toggle('on', on); b.querySelector('.swap')?.classList.toggle('on', on); b.querySelector('.gl')?.classList.toggle('on', on); });
  $$('#sideProjects [data-pid]').forEach(b => b.classList.toggle('on', r.ctx?.kind === 'project' && b.dataset.pid === r.ctx.pid));
  $$('#sideCols [data-cid]').forEach(b => b.classList.toggle('on', r.ctx?.kind === 'col' && b.dataset.cid === r.ctx.cid));
}
