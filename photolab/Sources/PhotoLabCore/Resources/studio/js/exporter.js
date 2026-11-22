// Export with a progress toast and a Reveal action.
//   {pid, ids: [..] | 'picks' | 'all', count?}   photos of one project
//   {best: true, items?: [{projectId, id}], count?}   Best Work (all, or the given items)
//   {photos: [normalised photos]}                 any mix of projects (one request per project)
//   {col: <id>, items?: [{projectId, id}]}        a collection (all, or the given items)
import { api, P } from './api.js';
import { toast, prettyDir } from './ui.js';

let running = false;

export async function runExport(job) {
  if (running) return;
  running = true;
  const n = job.photos ? job.photos.length : Array.isArray(job.ids) ? job.ids.length : job.items ? job.items.length : job.count;
  const t = toast(n > 1 ? `Exporting ${n} photos…` : 'Exporting…', { spin: true });
  try {
    let results;
    const opts = { ...(job.items ? { items: job.items } : {}), ...(job.dest ? { dest: job.dest } : {}), ...(job.frame !== undefined ? { frame: job.frame } : {}) };
    if (job.col) {
      results = [await api.post(P.colExport(job.col), opts)];
    } else if (job.best) {
      results = [await api.post(P.bestExport(), opts)];
    } else if (job.photos) {
      const by = new Map();
      for (const p of job.photos) { if (!by.has(p.pid)) by.set(p.pid, []); by.get(p.pid).push(p.id); }
      results = [];
      for (const [pid, ids] of by) results.push(await api.post(P.export(pid), { ids }));
    } else {
      results = [await api.post(P.export(job.pid), { ids: job.ids })];
    }
    const c = results.reduce((s, j) => s + (j.count ?? 0), 0) || n || 0;
    const failed = results.reduce((s, j) => s + (Array.isArray(j.failed) ? j.failed.length : (j.failed || 0)), 0);
    const dirs = [...new Set(results.map(j => j.dir).filter(Boolean))];
    const dir = dirs.length === 1 ? dirs[0] : commonParent(dirs);
    const where = prettyDir(dir);
    const msg = c === 1 ? `Exported to ${where}` : `Exported ${c} photos to ${where}`;
    t.update(failed ? `${msg} · ${failed} failed` : msg, {
      action: dir ? 'Reveal' : null,
      onAction: () => api.post(P.reveal(), { path: dir }).catch(() => toast("Couldn't show the folder")),
      ms: 7000,
    });
  } catch (err) {
    t.update(err.message && err.message.length < 90 ? `Export failed: ${err.message}` : 'Export failed', { ms: 7000 });
  } finally { running = false; }
}

function commonParent(dirs) {
  if (!dirs.length) return '';
  const split = dirs.map(d => d.split('/'));
  const out = [];
  for (let i = 0; i < split[0].length; i++) { const s = split[0][i]; if (split.every(x => x[i] === s)) out.push(s); else break; }
  return out.join('/') || dirs[0];
}
