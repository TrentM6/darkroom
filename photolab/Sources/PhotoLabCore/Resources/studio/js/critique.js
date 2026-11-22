// Analysis: a critique of one frame by Claude (on request, through the photographer's own Claude Code).
// A (or the Analysis button) turns the canvas into a review spread: the photo moves to the left and stays
// whole, the critique is a reading column on the right (editor and loupe). A, Esc or × goes back.
//  - Verdict, the panel line, the summary as a lead, then "The picture" and "The print": each criterion
//    with its judge, a 5-step score, the note, and its fix right under it ("Saturation 30 → 5  [Fix]",
//    "Crop to 4:5  [Preview]", "Next time: …"). Then "Edit vs original", all fixes with "Apply all fixes",
//    "Next time", and the factual "Worth a look" cues from the on-device analysis.
//  - Fixes go through the editor's normal params path (undoable; the critique then turns stale).
//  - "Taste" (at the bottom) edits the photographer's taste profile Claude reads (settings ai.taste).
//  - A cached `aiCritique` shows at once. Otherwise one "Ask Claude" button; the request takes under a
//    minute, you can keep working, and the result appears in place (or waits for when you come back).
//  - `stale`: the photo was edited since; the old critique stays, dimmed, with "Ask again".
// Once opened it follows you to the next photo until you close it or leave the view.
import { api, P } from './api.js';
import { esc, isApp } from './ui.js';
import { CTL } from './params.js';
import { currentSetup, openSettings } from './onboarding.js';
import { on } from './store.js';

// Who writes the critique, for the labels: Claude (Claude Code or the Anthropic API) or the OpenAI model.
const aiName = () => (cur?.provider || currentSetup()?.ai?.provider) === 'openai' ? 'the AI' : 'Claude';
const AiName = () => aiName() === 'Claude' ? 'Claude' : 'The AI';

// The earlier flat shape (five criteria at the top level) still renders, as one group.
const ROWS = [['light', 'Light'], ['color', 'Colour'], ['subject', 'Subject'], ['moment', 'Moment'], ['composition', 'Composition']];
const PICTURE = [['moment', 'Moment'], ['wit', 'Wit'], ['composition', 'Composition'], ['light', 'Light'], ['subject', 'Subject']];
const PRINT = [['color', 'Colour'], ['saturation', 'Saturation'], ['density', 'Density'], ['contrast', 'Contrast'], ['vignette', 'Vignette'], ['crispness', 'Crispness']];
const PARAM_LABEL = k => (CTL[k] && CTL[k].label && !['Amount'].includes(CTL[k].label) ? CTL[k].label
  : { filmStrength: 'Film amount', lookAmount: 'Look amount', film: 'Film', grainSize: 'Grain size', rotate: 'Straighten', crop: 'Crop' }[k] || k);

let col = null, scroller = null;      // the reading column and its scrolling body
let host = null;                      // {el, photo(), relayout(), btn}: where the column lives
let wantOpen = false;
let cur = null;                       // {key, pid, id, ai, available, cues, refetch, onFix}
let mode = 'critique';                // or 'taste'
let shownKey = '';                    // the photo the column last showed (scroll resets on a new one)
const applied = new Set();            // fixes applied this session: <photo>|<critique time>|<which>
let token = 0, cueTimer = 0;
const aiCache = new Map();            // key -> aiCritique received in this session
const pending = new Map();            // key -> Promise
const errors = new Map();             // key -> the last attempt's error sentence (server's aiError, or ours)

const hasCues = d => !!(d && d.critique && Array.isArray(d.critique.cues) && d.critique.cues.length);
// Whether a photo has anything to show (the editor hides the button otherwise).
// Analysis turned off in Settings: no button, no panel, no A key.
export const hasAnalysis = d => !!d && d.aiEnabled !== false && currentSetup()?.ai?.enabled !== false && (d.aiAvailable !== undefined || d.aiCritique != null || hasCues(d));

function scoreOf(v) { return Math.max(0, Math.min(5, Math.round(Number(v && typeof v === 'object' ? v.score : v) || 0))); }
function noteOf(v) { return v && typeof v === 'object' ? (v.note || v.phrase || '') : ''; }
const lines = v => (Array.isArray(v) ? v : v ? [v] : []).map(x => typeof x === 'string' ? x : (x && (x.text || x.note)) || '').filter(Boolean);

const VERDICTS = { keeper: 'keeper', strong: 'strong', workable: 'workable', weak: 'weak' };
const score = n => `<span class="rv-score" role="img" aria-label="${n} of 5">${[1, 2, 3, 4, 5].map(i => `<i${i <= n ? ' class="on"' : ''}></i>`).join('')}</span>`;
const X = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>`;
const CHECK = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>`;
const BACK = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m15 18-6-6 6-6"/></svg>`;
const closeBtn = `<button class="rv-x" data-act="close" aria-label="Close" title="Close (A)">${X}</button>`;
// Tabs: Critique (default) and Panel. Remembered between sessions.
let tab = (() => { try { return localStorage.getItem('photolab.critTab') === 'panel' ? 'panel' : 'critique'; } catch (_) { return 'critique'; } })();
const tabsBar = () => `<div class="rv-tabs" role="tablist" aria-label="Analysis">`
  + [['critique', 'Critique'], ['panel', 'Panel']].map(([k, l]) => `<button role="tab" id="critTab-${k}" data-tab="${k}" aria-selected="${tab === k}" tabindex="${tab === k ? 0 : -1}">${l}</button>`).join('')
  + `</div>`;
const minus = v => String(v).replace(/^-/, '−');
const num = v => { const n = Number(v); return Number.isFinite(n) ? minus(Number.isInteger(n) ? n : Math.round(n * 100) / 100) : esc(String(v)); };
// "+10", "−0.3", or "to 20" for an absolute value.
export function changeText(c) {
  if (c == null) return '';
  if (typeof c === 'object' && c.to !== undefined) return `to ${minus(c.to)}`;
  const n = Number(typeof c === 'string' ? c.replace('−', '-') : c);
  if (Number.isFinite(n)) return (n > 0 ? '+' : n < 0 ? '−' : '') + (Number.isInteger(n) ? Math.abs(n) : String(Math.abs(n)));
  return String(c);
}
// One change, as the photographer reads it: "Saturation 30 → 5", or "Saturation −25" without a start.
const changeHTML = c => {
  const label = esc(PARAM_LABEL(c.param));
  if (c.from !== undefined && c.to !== undefined) return `${label} <span class="rv-num">${num(c.from)}<span class="rv-arr" aria-label="to"> → </span>${num(c.to)}</span>`;
  return `${label} <span class="rv-num">${esc(changeText(c.change !== undefined ? c.change : { to: c.to }))}</span>`;
};
const fixId = (which) => `${cur.key}|${(cur.ai && (cur.ai.createdAt || cur.ai.summary)) || ''}|${which}`;
const canFix = fix => !!(cur && cur.onFix && fix && fix.type && fix.type !== 'reshoot');

// The same change proposed by two criteria (Colour and Saturation both "Saturation 0 → −25") shows once,
// under the first; the second points to it.
const seenFix = new Map();          // signature -> the criterion label that shows it
const fixSig = fix => fix.type === 'params' ? 'p:' + (fix.changes || []).filter(c => c && c.param).map(c => `${c.param}=${c.to ?? ('+' + c.change)}`).sort().join(',')
  : fix.type === 'crop' ? `c:${fix.aspect}:${JSON.stringify(fix.rect || {})}` : fix.type === 'straighten' ? `s:${fix.degrees}` : '';
// A criterion's fix, directly under its note.
function fixRow(k, fix, label = '') {
  if (!fix || typeof fix !== 'object') return '';
  if (fix.type === 'reshoot') return fix.note ? `<p class="rv-next"><span class="rv-nl">Next time</span>${esc(nextTime(fix.note))}</p>` : '';
  let what = '', act = 'Fix';
  if (fix.type === 'params') {
    const ch = (Array.isArray(fix.changes) ? fix.changes : []).filter(c => c && c.param);
    if (!ch.length) return '';
    what = ch.map(changeHTML).join('<span class="rv-sep">, </span>');
  } else if (fix.type === 'crop') {
    what = `Crop${fix.aspect && fix.aspect !== 'free' ? ` to <span class="rv-num">${esc(fix.aspect)}</span>` : ''}`; act = 'Preview';
  } else if (fix.type === 'straighten') {
    const d = Number(fix.degrees);
    what = `Straighten <span class="rv-num">${Number.isFinite(d) ? `${d > 0 ? '' : '−'}${Math.abs(d)}°` : ''}</span>`;
  } else return '';
  const sig = fixSig(fix);
  if (sig && seenFix.has(sig)) return `<p class="rv-same">Same fix as ${esc(seenFix.get(sig))}</p>`;
  if (sig) seenFix.set(sig, label || k);
  const done = applied.has(fixId(k));
  const btn = canFix(fix)
    ? (done ? `<span class="rv-done">${CHECK}Applied</span>`
      : `<button class="rv-btn" data-act="fix" data-k="${esc(k)}"${fix.why ? ` title="${esc(fix.why)}"` : ''}>${act}</button>`)
    : '';
  return `<div class="rv-fix"><span class="rv-fw">${what}</span>${btn}</div>`;
}

function item(k, label, v) {
  if (v == null) return '';
  const note = noteOf(v), fix = v && typeof v === 'object' ? v.fix : null;
  const name = (v && typeof v === 'object' && v.label) || label, judge = v && typeof v === 'object' ? v.judge : null;
  return `<article class="rv-item"><div class="rv-ih"><h4 class="rv-name">${esc(name)}${judge ? `<span class="rv-judge"> · ${esc(judge)}</span>` : ''}</h4>${score(scoreOf(v))}</div>`
    + (note ? `<p class="rv-text">${esc(note)}</p>` : '') + fixRow(k, fix, name) + `</article>`;
}
const group = (title, obj, keys) => {
  if (!obj) return '';
  const rows = keys.map(([k, label]) => item(k, label, obj[k] ?? (k === 'color' ? obj.colour : null))).join('');
  return rows ? `<section class="rv-sec">${title ? `<h3 class="rv-label">${title}</h3>` : ''}<div class="rv-items">${rows}</div></section>` : '';
};
// "Next time, step left…" under a "Next time" label reads twice: drop the lead-in.
const nextTime = t => { const m = String(t).match(/^\s*next time[,:]?\s+(.*)$/is); return m ? m[1].charAt(0).toUpperCase() + m[1].slice(1) : t; };
// The merged list, one change per slider (the first wins), so "Apply all fixes" never applies one twice.
const paramFixes = ai => { const seen = new Set(); return (Array.isArray(ai.fixes) ? ai.fixes : []).filter(x => x && x.param && !seen.has(x.param) && seen.add(x.param)); };
const block = (label, items, cls = '') => items.length ? `<section class="rv-sec ${cls}"><h3 class="rv-label">${label}</h3>${items.map(t => `<p class="rv-text">${esc(t)}</p>`).join('')}</section>` : '';

function renderAI(ai, busy, err) {
  seenFix.clear();
  const v = String(ai.verdict || '').trim();
  const panel = Array.isArray(ai.panel) ? ai.panel.filter(Boolean) : [];
  // A new request on top of an existing critique (stale, or a retry after an error): one quiet notice.
  const notice = busy ? `<div class="rv-notice" role="status"><span class="rv-spin" aria-hidden="true"></span><span>Asking ${aiName()} again. Usually under a minute.</span></div>`
    : err ? `<div class="rv-notice" role="status"><span>${esc(err)}</span><button class="rv-link" data-act="ask">Try again</button></div>`
    : ai.stale ? `<div class="rv-notice"><span>${(ai.version || 1) < 2 && !ai.picture ? 'An older kind of critique.' : 'Edited since this critique.'}</span><button class="rv-link" data-act="ask">Ask again</button></div>`
    : '';
  const groups = ai.picture || ai.print
    ? group('The picture', ai.picture, PICTURE) + group('The print', ai.print, PRINT)
    : group('', ai, ROWS);
  const fixes = paramFixes(ai);
  const allDone = applied.has(fixId('all'));
  const fixHTML = fixes.length ? `<section class="rv-sec rv-all"><h3 class="rv-label">All fixes</h3><ul class="rv-list">${fixes.map(x =>
    `<li><span class="rv-fw">${changeHTML(x)}</span>${x.why ? `<span class="rv-why">${esc(x.why)}</span>` : ''}</li>`).join('')}</ul>`
    + (cur && cur.onFix ? (allDone ? `<p class="rv-done rv-alldone">${CHECK}Fixes applied</p>` : `<button class="btn primary rv-apply" data-act="fixall">Apply all fixes</button>`) : '')
    + `</section>` : '';
  return notice
    + `<div class="rv-body${ai.stale ? ' dim' : ''}">`
    + `<header class="rv-head">${v ? `<p class="rv-verdict" data-v="${VERDICTS[v.toLowerCase()] || ''}">${esc(v)}</p>` : ''}`
    + (panel.length ? `<p class="rv-panel" aria-label="Judged against ${esc(panel.join(', '))}" title="Judged against these photographers"><span class="rv-pl">Panel</span>${panel.map(n => esc(n)).join('<span class="rv-dot" aria-hidden="true"> · </span>')}</p>` : '') + `</header>`
    + (ai.summary ? `<p class="rv-lead">${esc(ai.summary)}</p>` : '')
    + groups
    + block('Edit vs original', lines(ai.editVsOriginal))
    + fixHTML
    + block('Next time', lines(ai.reshoot).map(nextTime))
    + (ai.picture ? '' : block('Intangibles', lines(ai.intangibles)) + block('Try', lines(ai.suggestion)))
    + `</div>`;
}

// While Claude looks: the shape of what is coming, quietly.
const skeleton = () => `<div class="rv-skel" aria-hidden="true"><i class="w20 h24"></i><i class="w60 h10"></i><i class="w100"></i><i class="w95"></i><i class="w70"></i>`
  + `<i class="w25 h10 gap"></i>` + [0, 1, 2].map(() => `<i class="w35 gap2"></i><i class="w100"></i><i class="w85"></i>`).join('') + `</div>`;

function renderTaste() {
  return `<div class="rv-top"><button class="rv-back" data-act="tastecancel" aria-label="Back to the critique" title="Back (Esc)">${BACK}</button><span class="rv-tt">Taste</span><span class="grow"></span>${closeBtn}</div>
    <div class="rv-scroll"><div class="rv-taste">
    <p class="rv-text">What you like in a picture. Claude reads this with every critique.</p>
    <textarea class="rv-ta" id="critTaste" rows="12" maxlength="2000" spellcheck="true" aria-label="Taste" disabled>Loading…</textarea>
    <p class="rv-hint rv-terr" id="critTasteErr" hidden></p>
    <div class="rv-actions"><button class="btn" data-act="tastecancel">Cancel</button><button class="btn primary" data-act="tastesave">Save</button></div>
    </div></div>`;
}

function renderCritique() {
  if (cur.available === false && !cur.ai) {
    const why = currentSetup()?.ai?.problem || 'Connect an AI in Settings to get critiques.';
    return `<div class="rv-state"><p class="rv-st">No AI connected</p><p class="rv-hint">${esc(why)}</p><div class="rv-actions"><button class="btn" data-act="settings">Open Settings</button></div></div>`;
  }
  const busy = pending.has(cur.key) || cur.state === 'running';
  const err = !busy ? errors.get(cur.key) || null : null;
  let top;
  if (cur.ai) top = renderAI(cur.ai, busy, err);
  else if (busy) top = `<div class="rv-state" role="status"><p class="rv-st"><span class="rv-spin" aria-hidden="true"></span>Asking ${aiName()}…</p><p class="rv-hint">Usually under a minute. You can keep working.</p></div>` + skeleton();
  else if (err) top = `<div class="rv-state"><p class="rv-st">Couldn't get a critique</p><p class="rv-hint">${esc(err)}</p><div class="rv-actions"><button class="btn" data-act="ask">Try again</button></div></div>`;
  else top = `<div class="rv-state"><p class="rv-st">A critique of this photo by ${aiName()}</p><p class="rv-hint">Judged by the panel, picture and print, with a fix for every problem. Takes under a minute.</p><div class="rv-actions"><button class="btn primary" data-act="ask">Ask ${aiName()}</button></div></div>`;
  const cues = (cur.cues || []).slice(0, 4);
  const cueHTML = cues.length ? `<section class="rv-sec rv-cues"><h3 class="rv-label">Worth a look</h3><ul class="rv-list">${cues.map(t => `<li>${esc(t)}</li>`).join('')}</ul></section>` : '';
  const foot = cur.available !== false ? `<footer class="rv-foot"><button class="rv-link" data-act="taste">Taste</button><span class="rv-hint">${AiName()} reads it with every critique.</span></footer>` : '';
  return top + cueHTML + foot;
}

function render() {
  if (mode === 'taste' && cur) return renderTaste();
  // No photo details yet (the next photo is loading): the shape only.
  const body = !cur ? (tab === 'panel' ? renderPanel() : skeleton()) : tab === 'panel' ? renderPanel() : renderCritique();
  return `<div class="rv-top">${tabsBar()}<span class="grow"></span>${closeBtn}</div>`
    + `<div class="rv-scroll" role="tabpanel" aria-labelledby="critTab-${tab}" tabindex="-1"><div class="rv-in">${body}</div></div>`;
}

// The panel: the photographers the work is judged against (from Settings; no AI call).
const ORIGINAL_ERA = { meyerowitz: '1960s–70s New York, Kodachrome', levitt: 'New York, 1970s colour', davidson: 'Subway, 1980s New York',
  eggleston: 'Dye-transfer colour', leiter: 'Painterly New York colour', webb: 'Layered frames in hard light' };
function renderPanel() {
  const st = currentSetup();
  if (!st) return `<p class="rv-lead">Every photo is judged against the panel you chose in Settings.</p>`;
  const seats = st.panel.seats, ids = st.panel.ids;
  const people = ids.map(id => st.catalog.find(p => p.id === id)).filter(Boolean);
  const n = people.length, words = ['one', 'two', 'three', 'four', 'five', 'six'];
  const items = people.map(p => {
    const mine = seats.filter(s => s.photographer === p.id).map(s => s.label);
    return `<article class="rv-item"><div class="rv-ih"><h4 class="rv-name">${esc(p.name)}</h4><span class="rv-era">${esc(ORIGINAL_ERA[p.id] && st.panel.isDefault ? ORIGINAL_ERA[p.id] : p.known)}</span></div><p class="rv-text"><span class="rv-what">${esc(mine.join(' · '))}.</span> ${esc(p.work)}</p></article>`;
  }).join('');
  const standard = st.panel.isDefault ? `<section class="rv-sec"><h3 class="rv-label">The standard</h3><p class="rv-text">Gritty and dense like New York, but true colour, readable shadows, natural contrast, no visible effects.</p></section>` : '';
  return `<p class="rv-lead">Every photo is judged against ${words[n - 1] || n} photographer${n === 1 ? '' : 's'}, each on their part.</p><div class="rv-sec"><div class="rv-items">${items}</div></div>${standard}`
    + `<div class="rv-actions"><button class="btn" data-act="settings-panel">Change Panel</button></div>`;
}
function setTab(k, focus = false) {
  if (k === tab) return;
  tab = k;
  try { localStorage.setItem('photolab.critTab', k); } catch (_) {}
  paint();
  if (scroller) scroller.scrollTop = 0;
  if (focus) col.querySelector(`#critTab-${k}`)?.focus();
}

// Apply one criterion's fix, or all params fixes, through the editor (it records undo and re-renders).
function applyFix(which) {
  if (!cur || !cur.onFix || !cur.ai) return;
  let fix = null;
  if (which === 'all') fix = { type: 'params', changes: paramFixes(cur.ai).map(x => ({ param: x.param, change: x.change, to: x.to })) };
  else {
    for (const g of [cur.ai.picture, cur.ai.print, cur.ai]) {
      const v = g && (g[which] ?? (which === 'color' ? g.colour : null));
      if (v && typeof v === 'object' && v.fix) { fix = v.fix; break; }
    }
  }
  if (!fix) return;
  if (fix.type === 'crop') close(false);  // the crop tool needs the whole canvas (Apply / Cancel)
  const ok = cur.onFix(fix);
  if (ok !== false && fix.type !== 'crop') { applied.add(fixId(which)); repaint(); }
}

// Taste profile: GET/PUT /api/settings {ai: {taste}}.
async function openTaste() {
  mode = 'taste';
  paint();
  const ta = col.querySelector('#critTaste');
  try {
    const j = await api.get(P.settings());
    if (mode !== 'taste') return;
    ta.value = (j && j.ai && typeof j.ai.taste === 'string') ? j.ai.taste : '';
  } catch (_) { ta.value = ''; }
  ta.disabled = false;
  ta.focus();
}
async function saveTaste() {
  const ta = col.querySelector('#critTaste'), errEl = col.querySelector('#critTasteErr');
  if (!ta) return;
  const btn = col.querySelector('[data-act="tastesave"]');
  btn.disabled = true;
  try {
    await api.put(P.settings(), { ai: { taste: ta.value } });
    mode = 'critique'; paint();
  } catch (_) {
    errEl.hidden = false; errEl.textContent = "Couldn't save. Try again.";
    btn.disabled = false;
  }
}

function ensure() {
  if (col) return col;
  col = document.createElement('aside');
  col.className = 'review';
  col.id = 'review';
  col.setAttribute('aria-label', 'Analysis');
  col.hidden = true;
  col.addEventListener('click', e => {
    const t = e.target.closest('[data-tab]');
    if (t) { setTab(t.dataset.tab); return; }
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const act = b.dataset.act;
    if (act === 'ask') ask();
    else if (act === 'close') close();
    else if (act === 'fix') applyFix(b.dataset.k);
    else if (act === 'fixall') applyFix('all');
    else if (act === 'taste') openTaste();
    else if (act === 'tastecancel') { mode = 'critique'; paint(); }
    else if (act === 'tastesave') saveTaste();
    else if (act === 'settings') openSettings('ai');
    else if (act === 'settings-panel') openSettings('panel');
  });
  on('setup', () => { if (col && !col.hidden) paint(); });
  col.addEventListener('keydown', e => {
    if (e.target.closest('[role="tab"]') && (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Home' || e.key === 'End')) {
      e.preventDefault(); e.stopPropagation();
      setTab(e.key === 'ArrowLeft' || e.key === 'Home' ? 'critique' : 'panel', true);
      return;
    }
    if (e.target.closest('textarea')) {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); saveTaste(); }
      if (e.key !== 'Escape') e.stopPropagation();
    }
  });
  // The loupe closes on a press on its background: not on one in the column.
  col.addEventListener('mousedown', e => e.stopPropagation());
  // Esc closes it before anything else sees the key (in Taste it goes back to the critique).
  window.addEventListener('keydown', e => {
    if (e.key === 'Escape' && isCritiqueOpen()) {
      e.preventDefault(); e.stopImmediatePropagation();
      if (mode === 'taste') { mode = 'critique'; paint(); } else close();
    }
  }, true);
  return col;
}

// ---------- The spread: column in, photo over (and back) ----------
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const EASE = 'cubic-bezier(0.2, 0, 0, 1)';
// The photo glides from where it was to where the new layout puts it (FLIP).
// (Not in Baseline Darkroom.app: no animated compositing on large picture layers there; it reflows at once.)
function glide(el, from) {
  if (!el || !from || reduced() || isApp) return;
  const to = el.getBoundingClientRect();
  if (!to.width || !from.width) return;
  const dx = from.left - to.left, dy = from.top - to.top, s = from.width / to.width;
  if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5 && Math.abs(s - 1) < 0.002) return;
  el.animate([{ transformOrigin: '0 0', transform: `translate(${dx}px, ${dy}px) scale(${s})` }, { transformOrigin: '0 0', transform: 'none' }],
    { duration: 280, easing: EASE });
}
function mount(animate) {
  ensure();
  if (!host || !host.el) return;
  const ph = host.photo && host.photo(), from = animate && ph ? ph.getBoundingClientRect() : null;
  if (col.parentNode !== host.el) host.el.appendChild(col);
  const wasHidden = col.hidden;
  col.hidden = false;
  host.el.classList.add('reviewing');
  if (host.btn) { host.btn.setAttribute('aria-pressed', 'true'); host.btn.classList.add('on'); }
  host.relayout && host.relayout();
  if (animate && wasHidden) {
    glide(ph, from);
    if (!reduced()) col.animate([{ opacity: 0, transform: 'translateX(12px)' }, { opacity: 1, transform: 'none' }], { duration: 240, easing: EASE });
  }
}

function paint() {
  ensure();
  const st = scroller ? scroller.scrollTop : 0;
  col.innerHTML = render();
  scroller = col.querySelector('.rv-scroll');
  const k = cur ? cur.key + '|' + tab + '|' + mode : '';
  if (scroller) scroller.scrollTop = k === shownKey ? st : 0;
  shownKey = k;
  waitForCues();
}
const repaint = () => { if (isCritiqueOpen()) paint(); };
function close(animate = true) {
  wantOpen = false; mode = 'critique'; clearTimeout(cueTimer);
  if (!col || col.hidden) return;
  const h = host, ph = h && h.photo && h.photo(), from = animate && ph ? ph.getBoundingClientRect() : null;
  col.hidden = true;
  if (h && h.el) {
    h.el.classList.remove('reviewing');
    if (h.btn) { h.btn.setAttribute('aria-pressed', 'false'); h.btn.classList.remove('on'); }
    h.relayout && h.relayout();
    if (animate) glide(ph, from);
  }
}

// Ask Claude for this photo (force when the old critique is stale). The server answers at once with
// aiState "running"; the photo is then fetched about every 1.5 s until it is idle. The result is kept
// per photo, so it shows when you come back.
const sleep = ms => new Promise(r => setTimeout(r, ms));
function ask() {
  if (!cur || pending.has(cur.key)) return;
  const { key, pid, id, refetch } = cur;
  const force = !!(cur.ai && cur.ai.stale) || errors.has(key);
  errors.delete(key);
  const pr = (async () => {
    let j = await api.post(P.critique(pid, id), force ? { force: true } : {});
    for (let i = 0; i < 100 && j && j.aiState === 'running'; i++) {      // ~2.5 min at most
      await sleep(1500);
      if (!refetch) break;
      j = await refetch();
    }
    absorb(key, j);
  })().catch(err => { errors.set(key, (err && err.message && err.message.length < 140) ? err.message : "Claude couldn't be reached."); })
    .finally(() => { pending.delete(key); if (cur && cur.key === key) { cur.state = 'idle'; repaint(); } });
  pending.set(key, pr);
  repaint();
}
// Take the AI fields from a photo object into the session cache (and the open column).
function absorb(key, j) {
  if (!j) return;
  if (j.aiCritique) aiCache.set(key, j.aiCritique);
  if (j.aiError) errors.set(key, j.aiError); else if (j.aiState !== 'running') errors.delete(key);
  if (cur && cur.key === key) {
    if (j.aiCritique) cur.ai = j.aiCritique;
    if (j.aiAvailable !== undefined) cur.available = j.aiAvailable;
    if (j.aiProvider) cur.provider = j.aiProvider;
    cur.state = j.aiState || 'idle';
  }
}
// A photo that is already running when it is opened (asked from the other view, or before a reload):
// follow it until it is idle.
function follow() {
  if (!cur || cur.state !== 'running' || pending.has(cur.key) || !cur.refetch) return;
  const { key, refetch } = cur;
  const pr = (async () => {
    let j = null;
    for (let i = 0; i < 100; i++) {
      await sleep(1500);
      j = await refetch();
      if (!j || j.aiState !== 'running') break;
    }
    absorb(key, j);
  })().catch(() => {}).finally(() => { pending.delete(key); if (cur && cur.key === key) { cur.state = 'idle'; repaint(); } });
  pending.set(key, pr);
}

// The on-device cues may still be computing (null): ask again a few times while the column is open.
function waitForCues() {
  clearTimeout(cueTimer);
  if (!cur || cur.cues !== null || !cur.refetch) return;
  const t = token, c = cur;
  let tries = 0;
  const tick = async () => {
    if (t !== token || !isCritiqueOpen()) return;
    let d = null;
    try { d = await c.refetch(); } catch (_) {}
    if (t !== token) return;
    const cues = d && d.critique ? d.critique.cues : null;
    if (cues !== null && cues !== undefined) { c.cues = Array.isArray(cues) ? cues.filter(Boolean) : []; repaint(); return; }
    if (++tries < 8) cueTimer = setTimeout(tick, 2500);
  };
  cueTimer = setTimeout(tick, 2000);
}

export const isCritiqueOpen = () => !!col && !col.hidden;

// The view's current photo: its detail `d` (null while loading), the view's host for the column
// ({el: the canvas the column joins, photo(): the element that glides, relayout(), btn}), how to fetch
// the photo again (for late cues and while Claude works) and how to apply a fix (editor only).
export function setAnalysis(photo, d, h, refetch = null, onFix = null) {
  token++;
  clearTimeout(cueTimer);
  if (h && h !== host) {
    if (isCritiqueOpen()) close(false);
    host = h;
  }
  if (!photo || !hasAnalysis(d)) {
    cur = null;
    // While the next photo loads the column stays (no jump); with nothing to show it goes.
    if (isCritiqueOpen()) {
      if (photo) { const keep = wantOpen; close(false); wantOpen = keep; } else paint();
    }
    return;
  }
  const key = photo.key;
  // The server's copy is authoritative (it knows when an edit made it stale); an answer received in this
  // session fills in while the photo's details are still the ones from before the request.
  const ai = d.aiCritique || aiCache.get(key) || null;
  if (d.aiError && !pending.has(key)) errors.set(key, d.aiError);
  cur = {
    key, pid: photo.pid, id: photo.id, ai, available: d.aiAvailable, provider: d.aiProvider, state: d.aiState || 'idle',
    cues: d.critique ? (d.critique.cues === null ? null : (d.critique.cues || []).filter(Boolean)) : [],
    refetch, onFix,
  };
  follow();
  if (wantOpen && mode !== 'taste') { paint(); if (!isCritiqueOpen()) mount(false); }
}
export function toggleCritique(h) {
  if (h && h !== host) { if (isCritiqueOpen()) close(false); host = h; }
  if (isCritiqueOpen()) { close(); return; }
  if (!cur) return;
  wantOpen = true;
  paint();
  mount(true);
}
// Leaving the editor or the loupe closes it.
export function hideCritique() { close(false); }
