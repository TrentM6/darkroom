// API client. Talks to the local Darkroom server. The in-browser mock (development only) is used only when
// asked for with ?mock: a slow server is waited for, never replaced by demo data.
//   ?mock   use the mock
import { MockServer } from './mock.js';

const qs = new URLSearchParams(location.search);
let mock = null;
let firstLibrary = null;

export const api = {
  mode: 'unknown',

  async init() {
    if (qs.has('mock')) return this.useMock();
    this.mode = 'real';
    for (let attempt = 0; attempt < 8; attempt++) {
      try {
        const ctl = new AbortController();
        const t = setTimeout(() => ctl.abort(), 15000);
        const r = await fetch('/api/library', { cache: 'no-store', signal: ctl.signal });
        clearTimeout(t);
        if (!r.ok) throw new Error('HTTP ' + r.status);
        const j = await r.json();
        if (!j || !Array.isArray(j.projects)) throw new Error('not a library');
        firstLibrary = j;
        return;
      } catch (_) { await new Promise(res => setTimeout(res, 1000)); }
    }
  },

  async useMock() {
    mock = new MockServer(qs.get('media') || '/media/demo/');
    await mock.load();
    this.mode = 'mock';
  },

  async req(method, path, body) {
    if (this.mode === 'mock') return mock.handle(method, path, body);
    if (method === 'GET' && path === '/api/library' && firstLibrary) { const j = firstLibrary; firstLibrary = null; return j; }
    const opt = { method, cache: 'no-store', headers: {} };
    if (body !== undefined) { opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body); }
    const r = await fetch(path, opt);
    const text = await r.text();
    let j = {};
    if (text) { try { j = JSON.parse(text); } catch (_) { j = { error: text.slice(0, 200) }; } }
    if (!r.ok) { const e = new Error(j.error || j.message || ('HTTP ' + r.status)); e.status = r.status; throw e; }
    return j;
  },
  get(p) { return this.req('GET', p); },
  post(p, b = {}) { return this.req('POST', p, b); },
  put(p, b = {}) { return this.req('PUT', p, b); },
  patch(p, b = {}) { return this.req('PATCH', p, b); },
  del(p) { return this.req('DELETE', p); },

  // Image URLs from the server (or the mock fixtures) -> something the page can load.
  url(u) {
    if (!u) return '';
    if (/^(https?:|data:|blob:|\/)/.test(u)) return u;
    return this.mode === 'mock' ? mock.media + u : '/' + u;
  },
};

// Edits and marks carry an increasing `seq`, so a slow older request can't undo a newer one.
let lastSeq = 0;
export function nextSeq() { lastSeq = Math.max(lastSeq + 1, Date.now()); return lastSeq; }

// Path helpers so every view builds the same URLs.
export const P = {
  library: () => '/api/library',
  libraryOrder: () => '/api/library/order',
  sources: () => '/api/sources',
  locate: pid => `/api/project/${enc(pid)}/locate`,
  status: pid => `/api/project/${enc(pid)}/status`,
  project: pid => `/api/project/${enc(pid)}`,
  photo: (pid, id) => `/api/project/${enc(pid)}/photo/${enc(id)}`,
  params: (pid, id) => `/api/project/${enc(pid)}/photo/${enc(id)}/params`,
  reset: (pid, id) => `/api/project/${enc(pid)}/photo/${enc(id)}/reset`,
  critique: (pid, id) => `/api/project/${enc(pid)}/photo/${enc(id)}/critique`,
  neutralize: (pid, id) => `/api/project/${enc(pid)}/photo/${enc(id)}/neutralize`,
  rate: pid => `/api/project/${enc(pid)}/rate`,
  paste: pid => `/api/project/${enc(pid)}/paste`,
  look: () => '/api/look',
  lookPin: () => '/api/look/pin',
  lookApply: () => '/api/look/apply',
  settings: () => '/api/settings',
  export: pid => `/api/project/${enc(pid)}/export`,
  reveal: () => '/api/reveal',
  selects: () => '/api/collections/selects',
  best: () => '/api/collections/best',
  bestOrder: () => '/api/collections/best/order',
  bestExport: () => '/api/collections/best/export',
  collections: () => '/api/collections',
  collection: cid => `/api/collections/${enc(cid)}`,
  colAdd: cid => `/api/collections/${enc(cid)}/add`,
  colRemove: cid => `/api/collections/${enc(cid)}/remove`,
  colOrder: cid => `/api/collections/${enc(cid)}/order`,
  colExport: cid => `/api/collections/${enc(cid)}/export`,
};
function enc(s) { return encodeURIComponent(s); }
