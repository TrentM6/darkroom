// In-browser stand-in for the Baseline Darkroom server, built from a real shoot (mock/jul4th.json).
// Development only: renders are the fixture's pre-rendered previews, so the UI keeps its
// instant CSS approximation on top of them (see `previewParams`).
const KEY = 'photolab.mock.v3';
const LOOK_KEYS = ['film', 'filmStrength', 'contrast', 'blacks', 'punch', 'vibrance', 'saturation', 'warmth', 'tint', 'vignette', 'sharpen', 'grain', 'grainSize'];
const FILMS = [
  ['Kodak/Kodak Kodachrome 64.png', 'Kodachrome 64'], ['Kodak/Kodak Kodachrome 200.png', 'Kodachrome 200'],
  ['Kodak/Kodak Ektachrome 100 VS.png', 'Ektachrome 100 VS'], ['Kodak/Kodak Ektar 100.png', 'Ektar 100'],
  ['Kodak/Kodak Portra 400 2.png', 'Portra 400'], ['Kodak/Kodak Portra 800 2.png', 'Portra 800'],
  ['Fuji/Fuji Superia 400 2.png', 'Superia 400'], ['Fuji/Fuji 400H 2.png', 'Fuji 400H'],
].map(([path, name]) => ({ path, name }));

const wait = ms => new Promise(r => setTimeout(r, ms));
const clone = o => JSON.parse(JSON.stringify(o));

export class MockServer {
  constructor(media) { this.media = media.endsWith('/') ? media : media + '/'; }

  async load() {
    const r = await fetch('mock/jul4th.json', { cache: 'no-store' });
    this.fx = await r.json();
    try { this.s = JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (_) { this.s = null; }
    if (!this.s) {
      const base = this.fx.details[this.fx.project.photos[0].id].auto;
      this.s = {
        sources: [{ id: 'src1', name: 'Shoots', path: this.fx.project.source.replace(/\/[^/]+$/, '') }],
        projects: [{ id: 'jul4th', name: 'July 4th', date: '2026-07-04', path: this.fx.project.source, sourceId: 'src1', n: this.fx.project.photos.length, created: 0 }],
        photos: {},   // "pid/id" -> {rating, flag, params, edited}
        look: Object.fromEntries(LOOK_KEYS.map(k => [k, base[k]])),
        frame: { enabled: true, side: 1, topBottom: 0.5 },
        exportRoot: '~/Desktop',
      };
    }
    if (!this.s.starter) this.s.starter = { ...this.s.look };
    this.save();
  }

  // ---------- My Look learns from Best Work (mock: relearns 3 s after the last favorite change) ----------
  favParams() {
    this.syncBest();
    return (this.s.best || []).map(k => {
      const [pid, id] = k.split('/');
      return this.rec(pid, id).params || this.fx.details[id]?.params;
    }).filter(Boolean);
  }
  lookState() {
    const n = this.favParams().length;
    return {
      params: this.s.look, targets: {}, favorites: n, updatedAt: this.s.lookAt || 0,
      source: this.s.lookPinned ? 'pinned' : n >= 5 ? 'learned' : 'starter',
    };
  }
  relearn() {
    if (this.s.lookPinned) return;
    const favs = this.favParams(), w = Math.min(1, favs.length / 5), st = this.s.starter;
    const med = a => { const b = [...a].sort((x, y) => x - y), m = b.length >> 1; return b.length % 2 ? b[m] : (b[m - 1] + b[m]) / 2; };
    const mode = a => { const c = new Map(); a.forEach(v => c.set(v, (c.get(v) || 0) + 1)); return [...c].sort((x, y) => y[1] - x[1])[0]?.[0]; };
    const next = {};
    for (const k of LOOK_KEYS) {
      const vals = favs.map(p => p[k]).filter(v => v !== undefined && v !== null);
      if (!vals.length || w === 0) { next[k] = st[k]; continue; }
      if (typeof st[k] === 'number') next[k] = Math.round((st[k] * (1 - w) + med(vals) * w) * 100) / 100;
      else next[k] = w >= 0.5 ? mode(vals) : st[k];
    }
    if (JSON.stringify(next) === JSON.stringify(this.s.look)) return;
    this.s.look = next;
    this.s.lookAt = Date.now();
    this.followLook(true);
  }
  // Unedited photos follow the look; "re-render" them a few at a time.
  followLook(stagger) {
    let i = 0;
    for (const p of this.s.projects) for (const ph of this.photosOf(p)) {
      const r = this.rec(p.id, ph.id);
      if (r.edited) continue;
      r.params = { ...(r.params || this.fx.details[ph.id].params), ...this.s.look };
      if (!stagger) { r.v = (r.v || 0) + 1; continue; }
      setTimeout(() => { r.v = (r.v || 0) + 1; this.save(); }, 400 + (i++ >> 2) * 700);
    }
  }
  scheduleRelearn(ms = 3000) { clearTimeout(this.lt); this.lt = setTimeout(() => { this.relearn(); this.save(); }, ms); }
  // Best Work order: favorites in the saved order, new ones appended.
  syncBest() {
    const favs = Object.entries(this.s.photos).filter(([, r]) => r.fav).map(([k]) => k)
      .filter(k => this.s.projects.some(p => k.startsWith(p.id + '/')));
    this.s.best = [...(this.s.best || []).filter(k => favs.includes(k)), ...favs.filter(k => !(this.s.best || []).includes(k))];
  }
  save() { try { localStorage.setItem(KEY, JSON.stringify(this.s)); } catch (_) {} }

  proj(pid) { const p = this.s.projects.find(x => x.id === pid); if (!p) throw Object.assign(new Error('Not found'), { status: 404 }); return p; }
  // Imports "analyse" over a few seconds.
  progress(p) {
    if (!p.created) return { state: 'ready', done: p.n, total: p.n };
    const done = Math.min(p.n, Math.floor((Date.now() - p.created) / 260));
    return { state: done >= p.n ? 'ready' : 'analyzing', done, total: p.n };
  }
  // Claude's critique (mock): on request, kept per photo; an edit marks it stale.
  ai(r) { return { aiAvailable: !localStorage.getItem('photolab.mock.noai'), aiState: r.running ? 'running' : 'idle', aiError: r.aiError || null, aiCritique: r.ai || null }; }
  rec(pid, id) { return this.s.photos[pid + '/' + id] || (this.s.photos[pid + '/' + id] = {}); }
  photosOf(p) {
    const st = this.progress(p);
    return this.fx.project.photos.slice(0, p.created ? st.done : p.n);
  }
  light(pid, ph) {
    const r = this.rec(pid, ph.id);
    return { ...ph, thumb: ph.thumb + (r.v ? '?v=' + r.v : ''), rating: r.rating || 0, flag: r.flag || null, favorite: !!r.fav, edited: !!r.edited };
  }

  async handle(method, path, body) {
    await wait(method === 'GET' ? 40 : 90);
    const m = path.match(/^\/api\/(.*)$/);
    const parts = m[1].split('/').map(decodeURIComponent);
    const res = await this.route(method, parts, body || {});
    this.save();
    return clone(res === undefined ? { ok: true } : res);
  }

  async route(method, parts, b) {
    const [a, pid, c, id, d] = parts;
    if (a === 'library' && method === 'GET') {
      return {
        projects: this.s.projects.map(p => {
          const ph = this.photosOf(p), st = this.progress(p);
          const picks = ph.filter(x => this.rec(p.id, x.id).flag === 'pick');
          const edited = ph.filter(x => this.rec(p.id, x.id).edited).length;
          const favorites = ph.filter(x => this.rec(p.id, x.id).fav).length;
          return {
            id: p.id, name: p.name, date: p.date, count: p.n, picks: picks.length, favorites, edited, path: p.path, sourceId: p.sourceId || null,
            cover: (picks[0] || ph[0] || {}).thumb || null,
            status: p.missing ? 'missing' : st.state === 'ready' ? 'ready' : 'analyzing', done: st.done, total: st.total,
          };
        }),
        sources: this.s.sources, look: this.s.look, frame: this.s.frame, projectFolders: !!this.s.projectFolders, exportRoot: this.s.exportRoot, films: FILMS,
        projectSort: this.s.projectSort || 'newest', projectOrder: this.s.projectOrder || [],
      };
    }
    if (a === 'library' && pid === 'order' && (method === 'PUT' || method === 'POST')) {
      const modes = ['newest', 'oldest', 'name', 'custom'];
      if (b.projectSort !== undefined && !modes.includes(b.projectSort)) throw new Error('Unknown sort');
      if (Array.isArray(b.projectOrder)) {
        const ids = b.projectOrder.filter(x => this.s.projects.some(p => p.id === x));
        const slots = this.s.projects.map((p, i) => ids.includes(p.id) ? i : -1).filter(i => i >= 0);
        const byId = new Map(this.s.projects.map(p => [p.id, p]));
        slots.forEach((slot, k) => { this.s.projects[slot] = byId.get(ids[k]); });
        this.s.projectSort = 'custom'; this.s.projectOrder = this.s.projects.map(p => p.id);
      } else if (b.projectSort) {
        this.s.projectSort = b.projectSort;
        const by = { newest: (x, y) => String(y.date).localeCompare(String(x.date)), oldest: (x, y) => String(x.date).localeCompare(String(y.date)),
          name: (x, y) => x.name.localeCompare(y.name, undefined, { numeric: true }) }[b.projectSort];
        if (by) this.s.projects.sort(by);
      }
      return this.route('GET', ['library'], {});
    }
    if (a === 'sources' && method === 'POST') {
      const path = String(b.path || '').trim().replace(/\/+$/, '');
      if (!path) throw new Error('Choose a folder');
      const name = path.split('/').pop() || 'Photos';
      const p = { id: 'p' + Date.now().toString(36), name, date: new Date().toISOString().slice(0, 10), path, sourceId: null, n: 18, created: Date.now() };
      this.s.projects.unshift(p);
      return { projectIds: [p.id] };
    }
    if (a === 'settings' && method === 'GET') return { frame: this.s.frame, exportRoot: this.s.exportRoot, ai: { taste: this.s.taste || '' } };
    if (a === 'settings' && method === 'PUT') {
      if (b.ai && typeof b.ai.taste === 'string') this.s.taste = b.ai.taste;
      if (b.frame) this.s.frame = { ...this.s.frame, ...b.frame };
      if (b.exportRoot) this.s.exportRoot = b.exportRoot;
      if (b.projectFolders !== undefined) this.s.projectFolders = !!b.projectFolders;
      return { frame: this.s.frame, exportRoot: this.s.exportRoot };
    }
    if (a === 'look' && !pid && method === 'GET') return this.lookState();
    if (a === 'look' && pid === 'pin' && method === 'POST') {
      this.s.lookPinned = !!b.pinned;
      if (!b.pinned) this.scheduleRelearn(800);
      return this.lookState();
    }
    if (a === 'look' && pid === 'relearn' && method === 'POST') { this.relearn(); return this.lookState(); }
    if (a === 'look' && !pid && method === 'POST') {
      const look = { ...this.s.look, ...pick(b.params, LOOK_KEYS) };
      let unedited = 0, all = 0;
      for (const p of this.s.projects) for (const ph of this.photosOf(p)) { all++; if (!this.rec(p.id, ph.id).edited) unedited++; }
      if (b.dryRun) return { look, unedited, all };
      this.s.look = look;
      this.s.lookAt = Date.now();
      if (b.fromPhoto) this.s.lookPinned = true;
      for (const p of this.s.projects) for (const ph of this.photosOf(p)) {
        const r = this.rec(p.id, ph.id);
        if (!r.edited) { r.params = { ...(r.params || this.fx.details[ph.id].params), ...look }; r.v = (r.v || 0) + 1; }
      }
      return { look, changed: unedited };
    }
    if (a === 'look' && pid === 'apply' && method === 'POST') {
      let changed = 0;
      for (const p of this.s.projects) for (const ph of this.photosOf(p)) {
        const r = this.rec(p.id, ph.id);
        if (r.edited && b.scope !== 'all') continue;
        r.params = { ...(r.params || this.fx.details[ph.id].params), ...this.s.look };
        if (b.scope === 'all') r.edited = false;
        r.v = (r.v || 0) + 1; changed++;
      }
      return { changed };
    }
    if (a === 'reveal') return { ok: true };
    if (a === 'collections') {
      const all = [];
      for (const p of this.s.projects) for (const ph of this.photosOf(p)) all.push({ ...this.light(p.id, ph), projectId: p.id, projectName: p.name });
      if (pid === 'selects') return { photos: all.filter(x => x.flag === 'pick') };
      this.syncBest();
      const byKey = new Map(all.map(x => [x.projectId + '/' + x.id, x]));
      if (pid === 'best' && !c && method === 'GET') return { photos: this.s.best.map(k => byKey.get(k)).filter(Boolean) };
      if (pid === 'best' && c === 'order') { const want = (b.items || []).map(x => x.projectId + '/' + x.id); this.s.best = [...want.filter(k => this.s.best.includes(k)), ...this.s.best.filter(k => !want.includes(k))]; return { ok: true }; }
      if (pid === 'best' && c === 'export') { const n = b.items ? b.items.length : this.s.best.length; await wait(400 + n * 60); return { dir: '/Users/you/Desktop/Best Work', count: n, failed: [] }; }
    }
    if (a !== 'project') throw Object.assign(new Error('unknown endpoint'), { status: 404 });

    const p = this.proj(pid);
    if (!c) {
      if (method === 'GET') return { id: p.id, name: p.name, date: p.date, path: p.path, status: p.missing ? 'missing' : this.progress(p).state, photos: this.photosOf(p).map(ph => this.light(p.id, ph)) };
      if (method === 'PATCH') { if (b.name) p.name = String(b.name).slice(0, 120); return { id: p.id, name: p.name }; }
      if (method === 'DELETE') { this.s.projects = this.s.projects.filter(x => x !== p); this.syncBest(); return { ok: true }; }
    }
    if (c === 'status') return this.progress(p);
    if (c === 'locate') { if (!b.path) throw new Error('Choose a folder'); p.path = b.path; p.missing = false; return { ok: true }; }
    if (c === 'rate') {
      for (const x of b.ids || []) {
        const r = this.rec(pid, x);
        if (b.rating !== undefined) r.rating = b.rating;
        if (b.flag !== undefined) { r.flag = b.flag === 'none' ? null : b.flag || null; if (r.flag !== 'pick') r.fav = false; }
        if (b.favorite !== undefined) { r.fav = !!b.favorite; if (r.fav) r.flag = 'pick'; }
        this.syncBest();
      }
      if (b.favorite !== undefined || b.flag !== undefined) this.scheduleRelearn();
      return { ok: true };
    }
    if (c === 'paste') {
      for (const x of b.ids || []) { const r = this.rec(pid, x); r.params = { ...(r.params || this.fx.details[x].params), ...b.params }; r.edited = true; r.v = (r.v || 0) + 1; }
      return { ok: true, photos: (b.ids || []).map(x => ({ id: x, thumb: this.fx.project.photos.find(q => q.id === x).thumb + '?v=' + this.rec(pid, x).v })) };
    }
    if (c === 'export') {
      const ids = b.ids === 'picks' ? this.photosOf(p).filter(x => this.rec(pid, x.id).flag === 'pick').map(x => x.id)
        : b.ids === 'all' ? this.photosOf(p).map(x => x.id) : (b.ids || []);
      await wait(400 + ids.length * 60);
      return { dir: '/Users/you/Desktop', count: ids.length, failed: [] };
    }
    if (c === 'photo') {
      const fx = this.fx.details[id];
      if (!fx) throw Object.assign(new Error('No such photo'), { status: 404 });
      const r = this.rec(pid, id);
      const ph = this.fx.project.photos.find(q => q.id === id);
      if (!d && method === 'GET') { const cr = mockCritique(id, this.favParams().length); return { ...fx, params: r.params || fx.params, previewParams: fx.params, edited: !!r.edited, ...(cr ? { critique: cr } : {}), ...this.ai(r) }; }
      if (d === 'critique' && method === 'POST') {
        // As documented: returns at once with aiState "running"; a fresh cached critique returns as is.
        if (r.ai && !r.ai.stale && !b.force) return this.ai(r);
        if (!r.running) {
          r.running = true; r.aiError = null; this.save();
          setTimeout(() => {
            r.running = false;
            if (localStorage.getItem('photolab.mock.aiFail')) r.aiError = "Your Claude plan's usage limit is reached. Try again later.";
            else r.ai = mockAI(id);
            this.save();
          }, Number(localStorage.getItem('photolab.mock.aiDelay')) || 9000);
        }
        return this.ai(r);
      }
      if (d === 'params') {
        r.params = { ...(r.params || fx.params), ...b.params }; r.edited = true; r.v = (r.v || 0) + 1;
        if (r.ai) r.ai = { ...r.ai, stale: true };
        await wait(250 + Math.random() * 350);
        return { preview: fx.preview, thumb: ph.thumb + '?v=' + r.v, params: r.params, previewParams: fx.params, ...this.ai(r) };
      }
      if (d === 'reset') {
        delete r.params; r.edited = false; r.v = (r.v || 0) + 1;
        await wait(250);
        return { params: fx.auto, preview: fx.preview, thumb: ph.thumb + '?v=' + r.v, previewParams: fx.params };
      }
    }
    throw Object.assign(new Error('unknown endpoint'), { status: 404 });
  }
}

// Analysis fixtures (the backend builds these from StreetRead and the analysis): deterministic per photo,
// with some photos having none, to exercise the hidden state.
const CRIT = {
  light: [[2, 'Flat, overcast light', 'The light is even and soft, so nothing in the street stands out.'],
    [3, 'Even daylight', 'Clean daylight without strong shadows; it records the scene but adds little.'],
    [4, 'Directional light on the subject', 'Side light models the main figure against a darker street.'],
    [5, 'Hard sun, long shadows', 'Low sun rakes across the street and throws long, graphic shadows.']],
  colour: [[2, 'Muted, close to monotone', 'Greys and beiges dominate; no colour holds the eye.'],
    [3, 'Pleasant but mild colour', 'The colours are clean but none of them pushes against another.'],
    [4, 'One strong red accent', 'A single red shape pulls the eye and anchors the frame.'],
    [5, 'Red and blue clash', 'The red against the deep blue sky gives the frame its punch.']],
  subject: [[2, 'Nothing anchors the eye', 'The frame has no clear subject; the eye wanders.'],
    [3, 'Subject competes with the crowd', 'The main figure is there but other people pull attention away.'],
    [4, 'Subject reads well', 'The main figure separates from the background at a glance.'],
    [5, 'Clear subject, clean ground', 'One figure stands out cleanly against a simple background.']],
  moment: [[2, 'Backs turned', 'Most people face away; there is little to connect with.'],
    [3, 'No people; the scene carries it', 'An empty street; the light and shapes do the work here.'],
    [4, 'Good gesture', 'A raised hand gives the frame a small, readable moment.'],
    [5, 'Stride caught at its peak', 'The walker is caught mid-stride, legs fully apart.']],
  composition: [[2, 'Cluttered; shapes merge', 'A pole grows out of a head and the edges are crowded.'],
    [3, 'Busy at the edges', 'The centre works, but cut-off figures pull at the borders.'],
    [4, 'Clean edges, good balance', 'Nothing important touches the frame edge; weights balance.'],
    [5, 'Clear near, mid and far layers', 'Foreground, middle and distance each carry something.']],
};
function mockCritique(id, favorites) {
  let h = 2166136261 >>> 0;
  for (const c of String(id)) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; }
  if (h % 11 === 0) return null;                       // no critique for this photo
  const keys = ['light', 'colour', 'subject', 'moment', 'composition'];
  const criteria = keys.map((k, i) => {
    const row = CRIT[k][(h >>> (i * 3)) % 4];
    return { key: k, score: row[0], phrase: row[1], detail: row[2] };
  });
  const avg = criteria.reduce((s, c) => s + c.score, 0) / 5;
  const verdict = avg >= 4.4 ? 'Keeper' : avg >= 3.6 ? 'Strong' : avg >= 2.8 ? 'Workable' : 'Weak';
  const sorted = [...criteria].sort((a, b) => b.score - a.score);
  const lc = s => s.charAt(0).toLowerCase() + s.slice(1);
  const summary = `${verdict} frame. ${sorted[0].phrase} carries it; ${lc(sorted[4].phrase)}.`;
  const compare = favorites >= 5 ? (criteria[1].score >= 4 ? 'Colour as rich as your best work' : criteria[0].score <= 2 ? 'Flatter light than your best work' : null) : null;
  const reference = criteria[4].score === 5 ? 'Webb-like layering' : criteria[1].score === 5 ? 'Gruyaert colour field' : criteria[0].score === 5 ? 'Meyerowitz light' : null;
  // "Worth a look" cues (rule-based on the backend): 0–4 per photo.
  const CUES = ['A sign right next to a face', 'Two people echo the same pose', 'Red shirt rhymes with the red sign',
    'A tiny figure against a huge wall', 'Everyone looks the same way', 'A frame within the frame', 'Sun spotlights one person', 'Odd company: a mascot in the queue'];
  const n = (h >>> 7) % 5, cues = [];
  for (let i = 0; i < n; i++) { const c = CUES[(h >>> (i * 4 + 3)) % CUES.length]; if (!cues.includes(c)) cues.push(c); }
  return { verdict, summary, criteria, compare, reference, cues };
}

// Mock critiques in the rebuilt shape (picture / print / edit vs original / fixes / reshoot), written the
// way a seasoned picture editor talks.
const C = (score, note, fix) => (fix ? { score, note, fix } : { score, note });
const AI_VARIANTS = [
  {
    verdict: 'Strong',
    summary: 'The hard afternoon sun and the red sign carry this frame; what holds it back is the crowded right edge, where a half figure pulls the eye out of the picture.',
    picture: {
      moment: C(3, 'Plenty of movement, but no one gesture lifts above the rest; a beat later one of the walkers might have turned toward you.', { type: 'reshoot', note: 'Wait for a face to turn toward the lens before you release.' }),
      wit: C(4, 'The giant hot dog presides over a queue of people who all look a little tired of waiting.'),
      composition: C(3, 'The receding stalls give depth, but the cut-off figure on the right edge fights the flow.', { type: 'crop', aspect: '3:2', rect: { x: 0, y: 0.04, w: 0.9, h: 0.9 }, why: 'Lose the half figure on the right.' }),
      light: C(4, 'Low sun rakes across the boardwalk and rims every figure, so the scene reads in sharp, graphic shapes.'),
      subject: C(3, 'The crowd is the subject; it works as a scene, but the eye has nowhere to rest once it leaves the sign.'),
    },
    print: {
      color: C(5, 'The red of the sign against that deep Kodachrome blue is exactly the palette; the smaller reds in the crowd echo it.'),
      saturation: C(3, 'The shirts in the foreground are pushed past believable; the reds start to bleed.', { type: 'params', changes: [{ param: 'saturation', change: -10 }] }),
      density: C(4, 'Rich mid-tones; the boardwalk holds its texture.'),
      contrast: C(4, 'Punchy without crushing the faces in shade.'),
      vignette: C(2, 'The corners darken more than the light explains and pull attention to the frame.', { type: 'params', changes: [{ param: 'vignette', change: -10 }] }),
      crispness: C(4, 'Sharp where it matters; no halos on the sign.'),
    },
    editVsOriginal: 'Warmer and denser than the camera file, which suits the light; the extra saturation is the one step too far.',
    fixes: [{ param: 'saturation', change: -10, why: 'too much colour in the shirts' }, { param: 'vignette', change: -10, why: 'corners heavier than the light' }],
    reshoot: null,
  },
  {
    verdict: 'Workable',
    summary: 'Good raw material with a real idea in it, the painted face on the wall watching the street, but the frame is tilted and doesn’t yet commit to the idea.',
    picture: {
      moment: C(2, 'The man is walking away with his back to us; we need his face, or at least a glance toward the wall.', { type: 'reshoot', note: 'Stay with this wall and wait for someone walking toward the face.' }),
      wit: null,
      composition: C(2, 'The horizon leans about two degrees to the right, which reads as a mistake rather than a choice.', { type: 'straighten', degrees: 1.8 }),
      light: C(2, 'Flat, overcast light records the scene faithfully but gives the wall and the people the same weight.'),
      subject: C(3, 'The mural is the subject, but the passer-by is too small and too far to the edge to make the conversation land.'),
    },
    print: {
      color: C(3, 'Pleasant, muted colour; without contrast it settles into a single middle tone.'),
      saturation: C(3, 'About right for a grey day.'),
      density: C(2, 'A touch thin; the darks never quite reach black.', { type: 'params', changes: [{ param: 'blacks', change: -6 }, { param: 'exposure', change: -0.15 }] }),
      contrast: C(2, 'Too gentle for this light.', { type: 'params', changes: [{ param: 'contrast', change: 10 }] }),
      vignette: C(3, 'Barely there, which is right.'),
      crispness: C(4, 'Clean detail in the mural.'),
    },
    editVsOriginal: 'Close to the camera file; the look is light-handed here, and the frame wants more weight.',
    fixes: [{ param: 'contrast', change: 10, why: 'flat light needs more snap' }, { param: 'blacks', change: -6, why: 'darks never reach black' }, { param: 'exposure', change: -0.15, why: 'a touch thin' }],
    reshoot: 'Come back on a sunny afternoon: the wall faces west and would take hard side light.',
  },
];
const JUDGES = { moment: 'Levitt', wit: 'Levitt', composition: 'Webb', light: 'Meyerowitz', subject: 'Davidson',
  color: 'Meyerowitz', saturation: 'Eggleston', density: 'Davidson', contrast: 'Davidson', vignette: 'Leiter', crispness: 'Eggleston' };
function mockAI(id) {
  let h = 2166136261 >>> 0;
  for (const c of String(id)) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; }
  const v = JSON.parse(JSON.stringify({ ...AI_VARIANTS[h % AI_VARIANTS.length], createdAt: new Date().toISOString() }));
  for (const g of [v.picture, v.print]) for (const k in g) if (g[k]) g[k].judge = JUDGES[k];
  v.panel = ['Meyerowitz', 'Levitt', 'Davidson', 'Eggleston', 'Leiter', 'Webb'];
  return v;
}

function pick(o, keys) { const r = {}; for (const k of keys) if (o && o[k] !== undefined) r[k] = o[k]; return r; }
