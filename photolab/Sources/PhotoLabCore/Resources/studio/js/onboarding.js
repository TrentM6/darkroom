// Onboarding (first launch) and Settings: connect an AI, choose the critique panel, pick where My Look
// starts, learn Selects and Best Work, attach the first folder. GET/POST /api/setup.
import { api } from './api.js';
import { store, on, emit } from './store.js';
import { esc, toast } from './ui.js';
import { attachFolder } from './library.js';

// Glyphs: one outline family (24 grid, 1.5 stroke), like SF Symbols beside text.
const I = {
  check: '<path d="M20 6 9 17l-5-5"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>',
  film: '<rect width="18" height="18" x="3" y="3" rx="2"/><path d="M7 3v18M3 7.5h4M3 12h18M3 16.5h4M17 3v18M17 7.5h4M17 16.5h4"/>',
  spark: '<path d="M9.94 14.06 4 16l5.94 1.94L12 24l1.94-6.06L20 16l-6.06-1.94L12 8z" transform="translate(0 -4)"/><path d="M19 2v4M17 4h4"/>',
  lock: '<rect width="16" height="10" x="4" y="11" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  star: '<path d="M12 2.5l2.9 6.1 6.6.8-4.9 4.6 1.3 6.6L12 17.3l-5.9 3.3 1.3-6.6L2.5 9.4l6.6-.8Z"/>',
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
  seal: '<path d="M12 2.8 14.3 4.5l2.8-.2.9 2.7 2.4 1.5-.9 2.7.9 2.7-2.4 1.5-.9 2.7-2.8-.2L12 19.6l-2.3-1.7-2.8.2-.9-2.7-2.4-1.5.9-2.7-.9-2.7 2.4-1.5.9-2.7 2.8.2Z"/><path d="m8.8 11.4 2.2 2.2 4.2-4.2"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>',
  people: '<circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14.2c2.8.3 5 2.6 5 5.8"/>',
  stack: '<rect x="3" y="8" width="18" height="13" rx="2"/><path d="M6 5h12M9 2h6"/>',
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  lightbulb: '<path d="M9 18h6M10 22h4"/><path d="M12 2a7 7 0 0 0-4 12.7c.6.5 1 1.2 1 2V17h6v-.3c0-.8.4-1.5 1-2A7 7 0 0 0 12 2Z"/>',
};
const ic = (n, cls = 'ic') => `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${I[n]}</svg>`;
const LOOP = '<svg class="loop" viewBox="0 0 64 44" aria-hidden="true"><path d="M33 4c15 0 27 6 27 17 0 12-13 19-29 19S4 33 4 21C4 10 15 4 30 4c3 0 6 .5 8 1.3" fill="none" stroke="var(--pencil)" stroke-width="3" stroke-linecap="round"/></svg>';
const CHECK = `<svg class="tick" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>`;
// A grouped list row (System Settings): a radio circle or checkbox first when the row is a choice, then
// title and detail, then status on the right.
function row({ attrs = '', title, detail = '', trail = '', on = false, extra = '' }) {
  const kind = /role="radio"/.test(attrs) ? 'radio' : /role="checkbox"/.test(attrs) ? 'checkbox' : '';
  const ctl = kind ? `<span class="rc ${kind}${on ? ' on' : ''}" aria-hidden="true">${kind === 'checkbox' && on ? CHECK : ''}</span>` : '';
  return `<div class="g-row${on ? ' on' : ''}${kind ? ' choice' : ''}" ${attrs}>${ctl}<div class="g-main"><div class="g-t">${title}</div>${detail ? `<div class="g-d">${detail}</div>` : ''}${extra}</div>${trail ? `<span class="g-trail">${trail}</span>` : ''}</div>`;
}
const seg = (items, cur, data, label) => `<div class="seg-c" role="tablist" aria-label="${label}">${items.map(([id, l]) => `<button role="tab" aria-selected="${cur === id}" class="${cur === id ? 'on' : ''}" data-${data}="${id}">${esc(l)}</button>`).join('')}</div>`;
const HERO = { check: 'seal', analysis: 'eye', ai: 'link', panel: 'people', look: 'film', selects: 'star', folder: 'folder' };
// Steps: AI and Panel only when the photographer turns analysis on.
// The introduction replayed from Settings (tour) shows only what Darkroom is and how it works.
const steps = () => tour ? ['welcome', 'look', 'selects'] : ['welcome', 'check', 'analysis', ...(draft.enabled ? ['ai', 'panel'] : []), 'look', 'selects', 'folder'];
const stepId = () => steps()[step];

let setup = null;
let root = null;
let mode = null;          // 'onboarding' | 'settings'
let step = 0;
let tab = 'ai';           // settings tab: ai | panel | intro
let notice = '';          // a line above the settings body ("Now choose your panel")
let filter = 'all';
let claude = null;        // {installed, signedIn, account}
let busy = false;
let tour = false;
let picking = false;      // the "Choose your own" page is open
let query = '';           // its search
let err = '';
const draft = { group: null, enabled: null, provider: 'claude-code', keys: {}, model: {}, panel: [], starter: null, starterTouched: false };

export const setupOpen = () => !!mode;
export async function loadSetup() { setup = await api.get('/api/setup'); emit('setup', setup); return setup; }
export function currentSetup() { return setup; }

export async function initOnboarding() {
  try { await loadSetup(); } catch (_) { return; }
  if (setup.needsOnboarding && api.mode === 'real') openOnboarding();
  on('library', lib => {
    // The first folder attached during onboarding finishes it.
    if (mode === 'onboarding' && stepId() === 'folder' && (lib?.sources || []).length) finish(true);
  });
}

function reset() {
  draft.enabled = mode === 'onboarding' && setup.needsOnboarding ? null : setup.ai.enabled;
  draft.provider = setup.ai.provider === 'none' ? (setup.ai.claudeCode.installed ? 'claude-code' : 'anthropic') : setup.ai.provider;
  draft.keys = {}; draft.model = {};
  if (setup.ai.model) draft.model[setup.ai.provider] = setup.ai.model;
  draft.panel = setup.panel.chosen ? [...setup.panel.ids] : [];
  draft.group = setup.panel.chosen ? (setup.panel.group || 'custom') : null;
  draft.starter = null; draft.starterTouched = false;
  err = ''; notice = ''; filter = 'all'; picking = false; query = '';
}

export function openOnboarding() {
  if (!setup) return;
  mode = 'onboarding'; tour = false; step = 0; reset();
  mount(); probeClaude();
}

export async function openSettings(which = 'ai') {
  try { await loadSetup(); } catch (_) { toast("Couldn't load settings"); return; }
  mode = 'settings'; tour = false; tab = which; reset();
  if (tab === 'panel' && !draft.enabled) tab = 'ai';
  mount(); probeClaude();
}

async function probeClaude() {
  if (!setup?.ai?.claudeCode?.installed) { claude = { installed: false }; return; }
  try { claude = await api.get('/api/setup/claude'); } catch (_) { claude = null; }
  if (mode) paint();
}

function mount() {
  if (!root) {
    root = document.createElement('div');
    root.className = 'onb';
    root.innerHTML = '<div class="onb-scrim"></div><div class="onb-card" role="dialog" aria-modal="true" aria-labelledby="onbTitle"></div>';
    document.body.appendChild(root);
    root.addEventListener('click', onClick);
    root.addEventListener('input', onInput);
    root.addEventListener('keydown', onKeyDown);
    root.querySelector('.onb-scrim').addEventListener('click', () => { if (mode === 'settings') close(); });
  }
  root.hidden = false;
  paint();
  requestAnimationFrame(() => root.querySelector('.onb-card [data-primary]')?.focus());
}

function close() {
  mode = null; tour = false;
  if (root) root.hidden = true;
}

// ---------- Panel seating (mirrors StudioPanel.seat on the server) ----------
const DEFAULT_SEATS = { light: 'meyerowitz', moment: 'levitt', composition: 'webb', color: 'eggleston', density: 'davidson', restraint: 'leiter' };
const isDefaultPanel = ids => ids.length === setup.panel.max && [...ids].sort().join() === ['davidson', 'eggleston', 'leiter', 'levitt', 'meyerowitz', 'webb'].join();
function seatPanel(ids) {
  if (!ids.length || isDefaultPanel(ids)) return { ...DEFAULT_SEATS };
  const grp = setup.groups.find(g => g.ids.length === ids.length && g.ids.every(i => ids.includes(i)));
  if (grp) return { ...grp.seats };
  const people = ids.map(id => setup.catalog.find(p => p.id === id)).filter(Boolean);
  const seats = setup.seats.map(s => s.id), n = people.length, k = seats.length;
  let best = null, bestScore = -Infinity;
  const a = new Array(k).fill(0);
  for (let code = 0; code < n ** k; code++) {
    let c = code;
    for (let i = 0; i < k; i++) { a[i] = c % n; c = Math.floor(c / n); }
    const counts = new Array(n).fill(0);
    for (const i of a) counts[i]++;
    if (counts.includes(0)) continue;
    let score = 0;
    seats.forEach((s, i) => { score += people[a[i]].strengths[s] || 0; });
    score -= 0.01 * counts.reduce((t, x) => t + x * x, 0);
    if (score > bestScore + 1e-9) { bestScore = score; best = [...a]; }
  }
  const out = {};
  seats.forEach((s, i) => { out[s] = people[best[i]].id; });
  return out;
}
function suggestedStarter(ids) {
  const g = draft.group && draft.group !== 'custom' ? setup.groups.find(x => x.id === draft.group) : null;
  if (g) return g.film;
  const people = ids.map(id => setup.catalog.find(p => p.id === id)).filter(Boolean);
  if (!people.length) return 'kodachrome';
  const counts = {};
  for (const p of people) counts[p.film] = (counts[p.film] || 0) + 1;
  const top = Math.max(...Object.values(counts));
  return people.find(p => counts[p.film] === top).film;
}

// ---------- Rendering ----------
let painted = '';
function paint() {
  const card = root.querySelector('.onb-card');
  const scroller = card.querySelector('.g-scroll');
  const scroll = scroller ? scroller.scrollTop : 0;
  const key = mode + ':' + (mode === 'settings' ? tab : stepId()) + (picking ? ':pick' : '');
  card.innerHTML = mode === 'settings' ? settingsHTML() : stepHTML();
  const g = card.querySelector('.g-scroll'); if (g && key === painted) g.scrollTop = scroll;
  // A new page fades in; a repaint of the same page doesn't.
  if (key !== painted) card.querySelector('.onb-page')?.classList.add('enter');
  painted = key;
  fillCharts();
}

function stepHTML() {
  const all = steps(), k = step, n = all.length, id = all[k];
  const [title, lead, body] = stepContent(id);
  const last = k === n - 1;
  let primary = last ? 'Done' : 'Continue';
  let secondary = '';
  if (id === 'folder' && !tour) { primary = 'Choose Folder…'; secondary = '<button class="btn plain" data-act="next">Later</button>'; }
  let act = id === 'folder' && !tour ? 'choose' : 'next';
  if (id === 'panel' && picking) { primary = 'Done'; act = 'pickdone'; }
  const hero = id === 'welcome' ? '<img class="onb-appicon" src="/app-icon.png" alt="" width="88" height="88">' : `<div class="onb-glyph">${ic(HERO[id] || 'spark')}</div>`;
  return `<div class="onb-page">${hero}<h1 id="onbTitle">${title}</h1><p class="onb-lead">${lead}</p><div class="onb-body">${body}</div>
      ${err ? `<p class="onb-err" role="alert">${esc(err)}</p>` : ''}</div>
    <div class="onb-foot">${k ? `<button class="btn plain" data-act="${id === 'panel' && picking ? 'pickback' : 'back'}">Back</button>` : ''}<span class="grow"></span>${secondary}
      <button class="btn primary" data-act="${act}" data-primary${canContinue() && !busy ? '' : ' disabled'}>${busy ? 'Checking…' : primary}</button></div>`;
}

function stepContent(id) {
  if (id === 'welcome') return ['Welcome to Darkroom',
    'A darkroom for your digital photos.',
    `<ul class="onb-feat">
      <li>${ic('film')}<div><b>Contact sheets</b><span>Every shoot as 35&nbsp;mm strips. Mark the keepers with a grease pencil.</span></div></li>
      <li>${ic('spark')}<div><b>My Look</b><span>Every photo opens already edited, in a look that learns from your best work.</span></div></li>
      <li>${ic('lock')}<div><b>Your photos stay put</b><span>Darkroom never copies, moves or changes your originals.</span></div></li>
    </ul>`];
  if (id === 'check') {
    const c = setup.checks, ok = c.rawTherapee && c.films;
    const st = good => good ? `<span class="ok">${ic('check', 'ic xs')}Installed</span>` : '<span class="bad">Missing</span>';
    return [ok ? 'Ready to develop' : 'Something is missing',
      ok ? 'Darkroom develops your photos with RawTherapee and its film simulation library.'
        : 'Run the Darkroom installer again to add what is missing, then reopen Darkroom.',
      `<div class="g">${row({ title: 'RawTherapee', detail: 'The open-source raw processor', trail: st(c.rawTherapee) })}
        ${row({ title: 'Film simulations', detail: 'Kodak, Fuji, Ilford, Polaroid and more', trail: st(c.films) })}
        ${row({ title: 'Library', detail: 'Edits, marks and your look stay on this Mac', trail: '<span class="ok">' + ic('check', 'ic xs') + 'Ready</span>' })}</div>`];
  }
  if (id === 'analysis') return ['Photo analysis',
    'Connect an AI and Darkroom can critique any photo you ask about, judged by a panel of photographers you choose. It is optional.',
    `<div class="g" role="radiogroup" aria-label="Photo analysis">
      ${row({ attrs: `data-enable="true" role="radio" tabindex="0" aria-checked="${draft.enabled === true}"`, on: draft.enabled === true, title: 'Set up analysis', detail: 'Connect Claude Code or an API key, then choose your panel.' })}
      ${row({ attrs: `data-enable="false" role="radio" tabindex="0" aria-checked="${draft.enabled === false}"`, on: draft.enabled === false, title: 'Not now', detail: 'Everything else works the same. Turn it on later in Settings.' })}
    </div>`];
  if (id === 'ai') return ['Connect an AI',
    'Only the photo you ask about is sent, as a small copy.',
    aiOptionsHTML()];
  if (id === 'panel' && picking) return ['Choose photographers',
    'Up to six. What each one judges appears beside their name.',
    pickerHTML()];
  if (id === 'panel') return ['Choose your panel',
    'A group of photographers judges every photo, each on their part. Pick the kind of photography you want to be held to.',
    panelHTML()];
  if (id === 'look') {
    const pick = draft.starter || (draft.enabled ? suggestedStarter(draft.panel) : 'kodachrome');
    const flow = `<ul class="onb-feat">
      <li>${ic('film')}<div><b>Starts from a film</b><span>Kodachrome, Portra, HP5 and more, chosen when you set up Darkroom.</span></div></li>
      <li>${ic('star')}<div><b>Learns from your Best Work</b><span>Press F on your strongest frames. My Look studies them.</span></div></li>
      <li>${ic('spark')}<div><b>Moves with you</b><span>As your Best Work changes, My Look follows, and so does every photo you haven't edited.</span></div></li>
    </ul>`;
    if (tour) return ['My Look', 'Every photo opens already finished, in a look that learns from your best work.', flow];
    const tiles = setup.starters.map(s => {
      const on = s.id === pick;
      const sug = !draft.starterTouched && draft.enabled && on && draft.panel.length;
      return `<button class="ft${on ? ' on' : ''}" data-starter="${s.id}" role="radio" aria-checked="${on}">
        <span class="th"><img data-chart="${s.id}" alt="" ${chartCache.has(s.id) ? `src="${chartCache.get(s.id)}" class="ready"` : ''}></span>
        <span class="ln"><span class="rc radio${on ? ' on' : ''}" aria-hidden="true"></span><b>${esc(s.name)}</b></span>
        <span class="nt">${sug ? 'Suggested by your panel' : esc(s.note)}</span></button>`;
    }).join('');
    return ['Where My Look starts',
      'Choose a film to start from. As you favorite your best work, My Look moves toward it.',
      `<div class="fts" role="radiogroup" aria-label="Starting film">${tiles}</div>`];
  }
  if (id === 'selects') return ['Selects and Best Work',
    'Two piles, across every project.',
    `<div class="onb-piles">
      <div><div class="pv">${LOOP}</div><b>Selects</b><span>Press <kbd>P</kbd> to pick a frame. Picks gather in All Selects, ready to edit and export.</span></div>
      <div><div class="pv"><svg class="bigstar" viewBox="0 0 24 24" aria-hidden="true"><path d="${I.star.match(/d="([^"]+)"/)[1]}" fill="none" stroke="var(--pencil)" stroke-width="1.5" stroke-linejoin="round"/></svg></div><b>Best Work</b><span>Press <kbd>F</kbd> on your strongest frames. They become your portfolio and teach My Look.</span></div>
    </div>
    <p class="onb-keys"><kbd>X</kbd> rejects&emsp;<kbd>U</kbd> clears a mark&emsp;<kbd>Space</kbd> looks closer</p>`];
  return ['Add your photos',
    'Choose a folder of shoots. Each folder of photos inside becomes a project, and new photos appear as you add them.',
    `<div class="onb-drop">${ic('folder', 'ic')}<span>Or drop a folder here</span></div>`];
}

function aiOptionsHTML() {
  const a = setup.ai;
  let cc = 'Uses your Claude subscription', ccTrail = '';
  if (!a.claudeCode.installed) { cc = 'Install Claude Code from claude.com/code and sign in'; ccTrail = 'Not installed'; }
  else if (claude && claude.signedIn === false) { cc = 'Open Terminal, run claude and sign in'; ccTrail = 'Not signed in'; }
  else if (claude && claude.account) { cc = `Signed in as ${esc(claude.account)}`; }
  const fields = prov => {
    const p = a[prov];
    return `<div class="g-fields">
      <input type="password" data-key="${prov}" value="${esc(draft.keys[prov] ?? '')}" placeholder="${p.hasKey ? `API key saved (${esc(p.hint)})` : 'API key'}" aria-label="API key" autocomplete="off" spellcheck="false">
      <input type="text" data-model="${prov}" value="${esc(draft.model[prov] ?? '')}" placeholder="Model: ${esc(p.defaultModel)}" aria-label="Model" autocomplete="off" spellcheck="false">
    </div>`;
  };
  const opt = (id, title, detail, trail = '') => row({ attrs: `data-provider="${id}" role="radio" tabindex="0" aria-checked="${draft.provider === id}"`, on: draft.provider === id,
    title, detail, trail, extra: draft.provider === id && (id === 'anthropic' || id === 'openai') ? fields(id) : '' });
  return `<div class="g" role="radiogroup" aria-label="AI provider">
    ${opt('claude-code', 'Claude Code', cc, ccTrail)}
    ${opt('anthropic', 'Anthropic API', a.anthropic.hasKey ? 'Key saved. Billed per photo by Anthropic.' : 'A key from console.anthropic.com, billed per photo')}
    ${opt('openai', 'OpenAI API', a.openai.hasKey ? 'Key saved. Billed per photo by OpenAI.' : 'A key from platform.openai.com, billed per photo')}
  </div>`;
}

// The panel, picked like Control Center's controls: "Your panel" on top (each with what they judge), and
// every photographer below, one line each. A tap moves a photographer between the two.
// The panel step: ready-made groups by style first (most people know the kind of photography, not the
// names); "Choose your own" opens the photographer picker.
function panelHTML() {
  const surname = id => setup.catalog.find(p => p.id === id)?.surname || id;
  const mineNames = draft.group === 'custom' && draft.panel.length ? draft.panel.map(id => esc(surname(id))).join(', ') : '';
  const rows = setup.groups.map(g => row({ attrs: `data-group="${g.id}" role="radio" tabindex="0" aria-checked="${draft.group === g.id}"`, on: draft.group === g.id,
    title: esc(g.name), detail: `${esc(g.note)}<span class="g-names">${g.ids.map(id => esc(surname(id))).join(', ')}</span>` })).join('')
    + row({ attrs: `data-group="custom" role="radio" tabindex="0" aria-checked="${draft.group === 'custom'}"`, on: draft.group === 'custom',
      title: 'Choose your own', detail: `Pick up to six photographers by name.${mineNames ? `<span class="g-names">${mineNames}</span>` : ''}`,
      trail: `<span class="g-more">${draft.group === 'custom' && draft.panel.length ? 'Edit' : ''}<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 6 6 6-6 6"/></svg></span>` });
  return `<div class="g" role="radiogroup" aria-label="Panel">${rows}</div>`;
}

// "Choose your own": its own page. Search, one alphabetical list with checkboxes; rows never move, and a
// chosen photographer shows what they judge on the right.
function pickerHTML() {
  return `<div class="pick-top"><label class="search">${ic('search', 'ic')}<input type="search" data-search value="${esc(query)}" placeholder="Search names or styles" aria-label="Search photographers" autocomplete="off" spellcheck="false"></label>
      <span class="pick-count">${draft.panel.length} of ${setup.panel.max}</span></div>
    <div class="g g-scroll g-list pick-list">${pickerRows()}</div>`;
}
function pickerRows() {
  const max = setup.panel.max, full = draft.panel.length >= max;
  const seats = draft.panel.length ? seatPanel(draft.panel) : {};
  const seatOf = id => setup.seats.filter(s => seats[s.id] === id).map(s => s.label).join(', ');
  const qq = query.trim().toLowerCase();
  const genre = id => (setup.genres.find(g => g.id === id)?.label || id).toLowerCase();
  const list = setup.catalog
    .filter(p => !qq || [p.name, p.known, ...p.genres.map(genre)].some(t => t.toLowerCase().includes(qq)))
    .sort((a, b) => a.surname.localeCompare(b.surname));
  return list.map(p => {
    const on = draft.panel.includes(p.id);
    return row({ attrs: `data-pid="${p.id}" role="checkbox" tabindex="0" aria-checked="${on}"${!on && full ? ' aria-disabled="true"' : ''} title="${esc(p.work)}"`, on,
      title: `${esc(p.name)}<span class="g-known">${esc(p.known)}</span>`, trail: on ? esc(seatOf(p.id)) : '' });
  }).join('') || `<div class="g-row g-empty">No one matches “${esc(query)}”.</div>`;
}

// Starting films, each shown as the same colour chart through that film's own simulation.
const CHART = [[111, 159, 216], [217, 161, 132], [181, 50, 43], [224, 178, 60], [79, 122, 58], [128, 128, 128]];
const chartCache = new Map();
const lutUrl = path => (path.startsWith('../Black-and-White/') ? '/luts-bw/' + path.slice(19) : '/luts/' + path).split('/').map((c, i) => i < 2 ? c : encodeURIComponent(c)).join('/');
async function chartFor(st) {
  if (chartCache.has(st.id)) return chartCache.get(st.id);
  const W = 240, H = 120, c = document.createElement('canvas');
  c.width = W; c.height = H;
  const x = c.getContext('2d');
  // six colour stripes over a black-to-white ramp
  const sw = W / CHART.length;
  CHART.forEach(([r, g, b], i) => { x.fillStyle = `rgb(${r},${g},${b})`; x.fillRect(Math.round(i * sw), 0, Math.ceil(sw), H * 0.72); });
  const ramp = x.createLinearGradient(0, 0, W, 0); ramp.addColorStop(0, '#000'); ramp.addColorStop(1, '#fff');
  x.fillStyle = ramp; x.fillRect(0, H * 0.72, W, H * 0.28);
  if (st.film) {
    try {
      const img = new Image(); img.src = lutUrl(st.film); await img.decode();
      const side = img.naturalWidth, L = Math.round(Math.cbrt(side)), N = L * L;
      const lc = document.createElement('canvas'); lc.width = side; lc.height = side;
      const lx = lc.getContext('2d', { willReadFrequently: true }); lx.drawImage(img, 0, 0);
      const lut = lx.getImageData(0, 0, side, side).data;
      const d = x.getImageData(0, 0, W, H), px = d.data, k = (N - 1) / 255;
      for (let i = 0; i < px.length; i += 4) {
        const idx = Math.round(px[i] * k) + Math.round(px[i + 1] * k) * N + Math.round(px[i + 2] * k) * N * N;
        const o = ((Math.floor(idx / side) * side) + (idx % side)) * 4;
        px[i] = lut[o]; px[i + 1] = lut[o + 1]; px[i + 2] = lut[o + 2];
      }
      x.putImageData(d, 0, 0);
    } catch (_) { /* LUT missing: the plain chart */ }
  }
  const url = c.toDataURL('image/png');
  chartCache.set(st.id, url);
  return url;
}
function fillCharts() {
  root?.querySelectorAll('img[data-chart]').forEach(async el => {
    const st = setup.starters.find(s => s.id === el.dataset.chart);
    if (st) { el.src = await chartFor(st); el.classList.add('ready'); }
  });
}

function settingsHTML() {
  const on = !!draft.enabled;
  const tabs = seg([['ai', 'Analysis'], ...(on ? [['panel', 'Panel']] : []), ['intro', 'Introduction']], tab, 'tab', 'Settings');
  let body = '';
  if (tab === 'ai') {
    body = `<div class="g">${row({ title: 'Photo analysis', detail: '', trail: `<button class="switch${on ? ' on' : ''}" role="switch" aria-checked="${on}" aria-label="Photo analysis" data-act="toggle"><i></i></button>` })}</div>
      <p class="g-foot">An AI critiques the photos you ask about, judged by your panel. When off, Analysis doesn't appear anywhere in Darkroom.</p>`
      + (on ? `<h2 class="g-h">Provider</h2>${aiOptionsHTML()}<p class="g-foot">Only the photo you ask about is sent, as a small copy.</p>` : '');
  } else if (tab === 'panel') body = picking ? `<h2 class="pick-h">Choose photographers</h2>${pickerHTML()}` : `${notice ? `<p class="onb-notice">${esc(notice)}</p>` : ''}${panelHTML()}`;
  else body = `<div class="g">${row({ title: 'Introduction', detail: 'How Selects, Best Work and My Look fit together', trail: '<button class="btn" data-act="replay">Show</button>' })}</div>`;
  const label = tab === 'ai' && on && !setup.ai.enabled && !setup.panel.chosen ? 'Continue' : 'Save';
  const save = tab === 'intro' ? '' : picking
    ? `<button class="btn primary" data-act="pickdone" data-primary${draft.panel.length ? '' : ' disabled'}>Done</button>`
    : `<button class="btn primary" data-act="save" data-primary${canSave() && !busy ? '' : ' disabled'}>${busy ? 'Checking…' : label}</button>`;
  const cancel = picking ? '<button class="btn plain" data-act="pickback">Back</button>' : `<button class="btn plain" data-act="close">${tab === 'intro' ? 'Done' : 'Cancel'}</button>`;
  return `<div class="onb-page settings"><div class="onb-shead"><h1 id="onbTitle">Settings</h1>${tabs}</div><div class="onb-body">${body}</div>${err ? `<p class="onb-err" role="alert">${esc(err)}</p>` : ''}</div>
    <div class="onb-foot"><span class="grow"></span>${cancel}${save}</div>`;
}

// ---------- Validation and saving ----------
function canContinue() {
  const id = stepId();
  if (id === 'analysis') return draft.enabled !== null;
  if (id === 'ai') return providerUsable();
  if (id === 'panel') return draft.panel.length > 0;
  return true;
}
function canSave() {
  if (tab === 'panel') return draft.panel.length > 0;
  return !draft.enabled || providerUsable();
}
function providerUsable() {
  const p = draft.provider;
  if (p === 'anthropic' || p === 'openai') return !!(draft.keys[p] || setup.ai[p].hasKey);
  return p === 'claude-code';
}

async function saveAI() {
  const p = draft.provider, body = { provider: p, enabled: true };
  if (p === 'anthropic' || p === 'openai') {
    const key = (draft.keys[p] || '').trim();
    if (key) {
      busy = true; err = ''; paint();
      let r;
      try { r = await api.post('/api/setup/test', { provider: p, key }); } catch (e) { r = { ok: false, message: e.message }; }
      busy = false;
      if (!r.ok) { err = r.message || "That key didn't work."; paint(); return false; }
      body.keys = { [p]: key };
    }
    body.model = (draft.model[p] || '').trim();
  }
  setup = await api.post('/api/setup', body);
  return true;
}
async function savePanel() { setup = await api.post('/api/setup', { panel: draft.panel }); emit('setup', setup); return true; }

async function next() {
  err = '';
  const id = stepId();
  if (!tour) {
    try {
      if (id === 'analysis' && !draft.enabled) setup = await api.post('/api/setup', { enabled: false });
      if (id === 'ai' && !(await saveAI())) return;
      if (id === 'panel') { await savePanel(); if (!draft.starterTouched) draft.starter = null; }
      if (id === 'look' && setup.needsOnboarding) setup = await api.post('/api/setup', { starter: draft.starter || (draft.enabled ? suggestedStarter(draft.panel) : 'kodachrome') });
    } catch (e) { err = e.message || "Couldn't save"; paint(); return; }
  }
  if (step === steps().length - 1) return tour ? (close(), undefined) : finish(false);
  step++;
  paint();
  root.querySelector('.onb-card [data-primary]')?.focus();
}

async function finish(attached) {
  try { setup = await api.post('/api/setup', { onboarded: true }); } catch (_) {}
  close();
  emit('setup', setup);
  if (attached) toast('Your projects appear as Darkroom reads the photos', { ms: 5000 });
}

async function save() {
  err = '';
  try {
    if (tab === 'ai') {
      const turningOn = draft.enabled && !setup.ai.enabled;
      if (!draft.enabled) setup = await api.post('/api/setup', { enabled: false });
      else if (!(await saveAI())) return;
      emit('setup', setup);
      // Just turned on with no panel picked yet: choose one next.
      if (turningOn && !setup.panel.chosen) { tab = 'panel'; notice = 'Analysis is on. Now choose your panel.'; draft.panel = []; paint(); return; }
    }
    if (tab === 'panel') await savePanel();
  } catch (e) { err = e.message || "Couldn't save"; paint(); return; }
  emit('setup', setup);
  toast('Saved', { ms: 1600 });
  close();
}

// ---------- Events ----------
function onClick(e) {
  const t = e.target.closest('[data-act], [data-provider], [data-pid], [data-filter], [data-starter], [data-tab], [data-enable], [data-group]');
  if (!t || busy) return;
  if (t.dataset.enable) { draft.enabled = t.dataset.enable === 'true'; err = ''; paint(); return; }
  if (t.dataset.provider) { if (e.target.closest('input, .g-fields')) return; draft.provider = t.dataset.provider; err = ''; paint(); root.querySelector(`[data-key="${draft.provider}"]`)?.focus(); return; }
  if (t.dataset.pid) {
    const id = t.dataset.pid, i = draft.panel.indexOf(id);
    if (i >= 0) draft.panel.splice(i, 1);
    else if (draft.panel.length >= setup.panel.max) { toast(`A panel has at most ${setup.panel.max} photographers`, { ms: 2200 }); return; }
    else draft.panel.push(id);
    if (picking) { refreshPicker(); root.querySelector(`[data-pid="${CSS.escape(id)}"]`)?.focus({ preventScroll: true }); return; }
    paint(); root.querySelector(`[data-pid="${CSS.escape(id)}"]`)?.focus({ preventScroll: true }); return;
  }
  if (t.dataset.group) {
    draft.group = t.dataset.group;
    if (draft.group !== 'custom') draft.panel = [...setup.groups.find(g => g.id === draft.group).ids];
    else {
      if (setup.groups.some(g => g.ids.length === draft.panel.length && g.ids.every(i => draft.panel.includes(i)))) draft.panel = [];
      picking = true; query = '';
      paint(); root.querySelector('[data-search]')?.focus(); return;
    }
    paint(); return;
  }
  if (t.dataset.filter) { filter = t.dataset.filter; paint(); return; }
  if (t.dataset.starter) { if (tour) return; draft.starter = t.dataset.starter; draft.starterTouched = true; paint(); return; }
  if (t.dataset.tab) { tab = t.dataset.tab; err = ''; notice = ''; picking = false; paint(); return; }
  const a = t.dataset.act;
  if (a === 'next') next();
  else if (a === 'back') { err = ''; step = Math.max(0, step - 1); paint(); }
  else if (a === 'choose') attachFolder();
  else if (a === 'classic') { draft.panel = ['meyerowitz', 'levitt', 'davidson', 'eggleston', 'leiter', 'webb']; paint(); }
  else if (a === 'pickdone') { if (draft.panel.length) { picking = false; paint(); } }
  else if (a === 'pickback') { picking = false; if (!draft.panel.length) draft.group = null; paint(); }
  else if (a === 'toggle') { draft.enabled = !draft.enabled; err = ''; paint(); }
  else if (a === 'save') save();
  else if (a === 'close') close();
  else if (a === 'replay') { mode = 'onboarding'; tour = true; step = 0; reset(); paint(); }
}
function refreshPicker() {
  const list = root.querySelector('.pick-list'), count = root.querySelector('.pick-count');
  if (list) list.innerHTML = pickerRows();
  if (count) count.textContent = `${draft.panel.length} of ${setup.panel.max}`;
  const done = root.querySelector('[data-act="pickdone"]'); if (done) done.disabled = !draft.panel.length;
}
function onInput(e) {
  if (e.target.matches('[data-search]')) { query = e.target.value; refreshPicker(); return; }
  const k = e.target.dataset.key, m = e.target.dataset.model;
  if (k) { draft.keys[k] = e.target.value; err = ''; }
  if (m) draft.model[m] = e.target.value;
  const btn = root.querySelector('[data-primary]');
  if (btn) btn.disabled = !(mode === 'settings' ? canSave() : canContinue());
}
function onKeyDown(e) {
  e.stopPropagation();
  if (e.key === 'Escape' && picking) { e.preventDefault(); picking = false; if (!draft.panel.length) draft.group = null; paint(); return; }
  if (e.key === 'Escape' && mode === 'settings') { e.preventDefault(); close(); return; }
  if ((e.key === 'Enter' || e.key === ' ') && e.target.matches('[data-provider], [data-enable], [data-pid], [data-starter], [data-group]')) { e.preventDefault(); e.target.click(); return; }
  if (e.key === 'Escape' && tour) { e.preventDefault(); close(); return; }
  if (e.key === 'Enter' && e.target.matches('input')) { e.preventDefault(); root.querySelector('[data-primary]:not(:disabled)')?.click(); }
}
void store;
