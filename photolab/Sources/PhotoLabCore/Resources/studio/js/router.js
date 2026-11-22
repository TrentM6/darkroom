// Hash routes
//   #/                       library (projects)
//   #/p/<pid>                project grid        #/c/<selects|best>          collection grid
//   #/p/<pid>/e/<id>         edit in a project   #/c/<kind>/e/<pid>/<id>     edit within a collection
//   #/c/col/<cid>            a collection made by hand (and /e/<pid>/<id> to edit in it)
const subs = new Set();
const d = decodeURIComponent, e = encodeURIComponent;
export function current() {
  let h = location.hash.replace(/^#/, '') || '/';
  if (h === '/best' || h === '/selects') h = '/c' + h;      // short aliases
  let m = h.match(/^\/p\/([^/]+)(?:\/e\/([^/]+))?\/?$/);
  if (m) {
    const ctx = { kind: 'project', pid: d(m[1]) };
    return m[2] ? { view: 'edit', ctx, pid: ctx.pid, id: d(m[2]) } : { view: 'grid', ctx };
  }
  m = h.match(/^\/c\/col\/([^/]+)(?:\/e\/([^/]+)\/([^/]+))?\/?$/);
  if (m) {
    const ctx = { kind: 'col', cid: d(m[1]) };
    return m[2] ? { view: 'edit', ctx, pid: d(m[2]), id: d(m[3]) } : { view: 'grid', ctx };
  }
  m = h.match(/^\/c\/(selects|best)(?:\/e\/([^/]+)\/([^/]+))?\/?$/);
  if (m) {
    const ctx = { kind: m[1] };
    return m[2] ? { view: 'edit', ctx, pid: d(m[2]), id: d(m[3]) } : { view: 'grid', ctx };
  }
  return { view: 'library' };
}
const colBase = ctx => ctx.kind === 'col' ? `/c/col/${e(ctx.cid)}` : `/c/${ctx.kind}`;
export const ctxPath = ctx => ctx.kind === 'project' ? `/p/${e(ctx.pid)}` : colBase(ctx);
export const editPath = (ctx, p) => ctx.kind === 'project' ? `/p/${e(ctx.pid)}/e/${e(p.id)}` : `${colBase(ctx)}/e/${e(p.pid)}/${e(p.id)}`;
export const sameCtx = (a, b) => !!a && !!b && a.kind === b.kind && (a.kind !== 'project' || a.pid === b.pid) && (a.kind !== 'col' || a.cid === b.cid);

export function go(path, { replace = false } = {}) {
  const h = '#' + path;
  if (location.hash === h) return;
  if (replace) { history.replaceState(null, '', h); subs.forEach(f => f(current())); }
  else location.hash = h;
}
export function onRoute(f) { subs.add(f); }
window.addEventListener('hashchange', () => subs.forEach(f => f(current())));
