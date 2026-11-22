// Small shared UI pieces: toasts, menus, dialogs, helpers.
export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => [...r.querySelectorAll(s)];
export const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Keys typed into a text field never trigger shortcuts. Sliders and buttons still let letter shortcuts through.
export function isTyping(e) {
  const t = e.target;
  if (!t || !t.tagName) return false;
  if (t.isContentEditable) return true;
  if (t.tagName === 'TEXTAREA' || t.tagName === 'SELECT') return true;
  if (t.tagName === 'INPUT') return !['range', 'checkbox', 'radio', 'button'].includes(t.type);
  return false;
}

// Inside Baseline Darkroom.app (WKWebView): the native bridge is there.
export const isApp = !!(window.webkit?.messageHandlers?.photolab || window.photolab);

// Point an <img> at a new picture without a blank frame: the new file is decoded off-screen first and
// swapped in only then (the old picture stays until that moment). `commit` runs in the same task as
// the swap (e.g. a layout that depends on the new picture). onFail 'set' swaps anyway (lets the
// element's own error handling run); the default keeps the old picture.
export function swapImg(img, src, { onFail = 'keep', commit } = {}) {
  if (img.getAttribute('src') === src && !img.dataset.want) { commit?.(); return Promise.resolve(true); }
  if (img.dataset.want === src && img._swap) return img._swap;
  img.dataset.want = src;
  const pre = new Image(); pre.decoding = 'async'; pre.src = src;
  const done = (pre.decode ? pre.decode() : new Promise((res, rej) => { pre.onload = res; pre.onerror = rej; }))
    .then(() => true, () => false)
    .then(ok => {
      if (img.dataset.want !== src) return false;      // superseded by a newer picture
      delete img.dataset.want; img._swap = null;
      if (ok || onFail === 'set') { if (img.getAttribute('src') !== src) img.src = src; commit?.(); }
      return ok;
    });
  img._swap = done;
  return done;
}
// Set an <img> source (no-op when unchanged). An empty <img> loads directly; one that already shows a
// picture swaps after the new one is decoded.
export function setImg(img, src) {
  if (!src) { delete img.dataset.want; if (img.hasAttribute('src')) img.removeAttribute('src'); return; }
  if (img.getAttribute('src') === src && !img.dataset.want) return;
  if (!img.getAttribute('src')) { delete img.dataset.want; img.src = src; return; }
  swapImg(img, src);
}

const preloaded = new Map();
export function preload(src) {
  if (!src) return Promise.resolve();
  if (preloaded.has(src)) return preloaded.get(src);
  const p = new Promise(res => { const i = new Image(); i.decoding = 'async'; i.onload = i.onerror = () => res(i); i.src = src; });
  preloaded.set(src, p);
  if (preloaded.size > 200) preloaded.delete(preloaded.keys().next().value);
  return p;
}

// "1 photo", "2 photos"
export const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;

// ---------- Surfaces that open and close ----------
// Enter and exit are CSS transitions on .open (interruptible); the exit is softer and shorter.
export function showEl(el) {
  clearTimeout(el._hideT);
  el.hidden = false;
  void el.offsetWidth;            // commit the closed state so the transition runs
  el.classList.add('open');
}
export function hideEl(el, ms = 150) {
  el.classList.remove('open');
  clearTimeout(el._hideT);
  el._hideT = setTimeout(() => { if (!el.classList.contains('open')) el.hidden = true; }, ms);
}

// ---------- Tooltips ----------
// Any [title] becomes a tooltip: 500 ms delay, instant while moving between controls.
let tipTimer = null, tipFor = null, tipLast = 0;
function placeTip(el) {
  const tip = $('#tip');
  tip.textContent = el.dataset.tip;
  const r = el.getBoundingClientRect();
  tip.hidden = false;
  const t = tip.getBoundingClientRect();
  let x = r.left + r.width / 2 - t.width / 2, y = r.bottom + 6;
  if (y + t.height > innerHeight - 6) y = r.top - t.height - 6;
  x = Math.max(6, Math.min(innerWidth - t.width - 6, x));
  tip.style.left = Math.round(x) + 'px'; tip.style.top = Math.round(y) + 'px';
}
export function hideTip() {
  clearTimeout(tipTimer); tipTimer = null;
  if (tipFor) tipLast = performance.now();
  tipFor = null;
  const tip = $('#tip');
  if (tip && !tip.hidden) hideEl(tip, 100);
}
export function initTooltips() {
  document.addEventListener('mouseover', e => {
    const el = e.target.closest?.('[title], [data-tip]');
    if (el && el.hasAttribute('title')) {
      const t = el.getAttribute('title');
      el.dataset.tip = t;
      if (!el.hasAttribute('aria-label') && !el.textContent.trim()) el.setAttribute('aria-label', t);
      el.removeAttribute('title');
    }
    if (!el || !el.dataset.tip) { if (tipFor) hideTip(); return; }
    if (el === tipFor) return;
    hideTip();
    tipFor = el;
    const quick = performance.now() - tipLast < 400;
    tipTimer = setTimeout(() => { if (tipFor === el && el.isConnected) { placeTip(el); showEl($('#tip')); } }, quick ? 0 : 500);
  });
  for (const ev of ['mousedown', 'keydown', 'wheel', 'blur']) window.addEventListener(ev, hideTip, true);
}

// ---------- Toasts ----------
export function toast(text, { action, onAction, spin = false, ms = 4500 } = {}) {
  const el = document.createElement('div');
  el.className = 'toast';
  const render = (t, o = {}) => {
    el.innerHTML = `${o.spin ? '<span class="spin"></span>' : ''}<span>${esc(t)}</span>${o.action ? `<button class="btn">${esc(o.action)}</button>` : ''}`;
    if (o.action) el.querySelector('button').onclick = () => { o.onAction?.(); close(); };
  };
  let timer = null;
  const close = () => { clearTimeout(timer); el.classList.remove('open'); el.classList.add('out'); setTimeout(() => el.remove(), 150); };
  const arm = m => { clearTimeout(timer); if (m) timer = setTimeout(close, m); };
  render(text, { action, onAction, spin });
  $('#toasts').appendChild(el);
  void el.offsetWidth;
  el.classList.add('open');
  arm(spin ? 0 : ms);
  return { close, update(t, o = {}) { render(t, o); arm(o.spin ? 0 : (o.ms ?? 5000)); } };
}

// ---------- Context menu ----------
let menuClose = null;
export function openMenu(x, y, items) {
  closeMenu();
  const m = $('#menu');
  m.innerHTML = items.map((it, i) => it === '-' ? '<hr>'
    : it.caption ? `<div class="cap">${esc(it.caption)}</div>`
    : `<button data-i="${i}" class="${it.danger ? 'danger' : ''}${it.on ? ' on' : ''}" ${it.disabled ? 'disabled' : ''}>${it.icon ? `<span class="mi">${it.icon}</span>` : ''}${esc(it.label)}${it.key ? `<span class="k">${esc(it.key)}</span>` : ''}${it.check ? '<span class="k">✓</span>' : ''}</button>`).join('');
  m.hidden = false;
  m.classList.remove('open');
  m.style.left = '0px'; m.style.top = '0px';      // measure at full width, not squeezed at the last spot
  const r = m.getBoundingClientRect();
  m.style.left = Math.min(x, innerWidth - r.width - 8) + 'px';
  m.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
  m.querySelectorAll('button').forEach(b => b.onclick = ev => { ev.stopPropagation(); const it = items[+b.dataset.i]; closeMenu(); it.run?.(); });
  const off = ev => { if (!m.contains(ev.target)) closeMenu(); };
  const key = ev => {
    if (ev.key === 'Escape') { ev.stopPropagation(); closeMenu(); return; }
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      ev.preventDefault(); ev.stopPropagation();
      const bs = [...m.querySelectorAll('button:not(:disabled)')];
      const i = bs.indexOf(document.activeElement);
      bs[(i + (ev.key === 'ArrowDown' ? 1 : -1) + bs.length) % bs.length]?.focus();
    } else if (ev.key !== 'Enter' && ev.key !== ' ') ev.stopPropagation();
  };
  setTimeout(() => { document.addEventListener('mousedown', off, true); document.addEventListener('keydown', key, true); });
  menuClose = () => { document.removeEventListener('mousedown', off, true); document.removeEventListener('keydown', key, true); hideEl(m, 100); };
  m.style.transformOrigin = x > innerWidth - r.width - 8 ? 'top right' : 'top left';
  showEl(m);
  m.querySelector('button:not(:disabled)')?.focus({ preventScroll: true });
}
export function closeMenu() { if (menuClose) { const f = menuClose; menuClose = null; f(); } }
export const menuOpen = () => !!menuClose;

// ---------- Dialogs ----------
let dialogOpen = false;
export const isDialogOpen = () => dialogOpen;
// fields: [{type:'text', name, value, placeholder} | {type:'check', name, label, value}]
export function dialog({ title, text = '', fields = [], ok = 'OK', cancel = 'Cancel', danger = false, okLabel, okEnabled }) {
  return new Promise(resolve => {
    const modal = $('#modal'), d = $('#dialog');
    d.innerHTML = `<h2>${esc(title)}</h2>${text ? `<p id="dlgText">${esc(text)}</p>` : ''}
      ${fields.map(f => f.type === 'check'
        ? `<label class="chk"><input type="checkbox" name="${f.name}" ${f.value ? 'checked' : ''}> ${esc(f.label)}</label>`
        : `<input type="text" name="${f.name}" value="${esc(f.value || '')}" placeholder="${esc(f.placeholder || '')}" spellcheck="false" autocomplete="off">`).join('')}
      <div class="actions"><button class="btn" data-a="cancel">${esc(cancel)}</button><button class="btn ${danger ? 'danger' : 'primary'}" data-a="ok">${esc(ok)}</button></div>`;
    showEl(modal); dialogOpen = true;
    const values = () => Object.fromEntries([...d.querySelectorAll('input')].map(i => [i.name, i.type === 'checkbox' ? i.checked : i.value.trim()]));
    const done = v => { hideEl(modal); dialogOpen = false; document.removeEventListener('keydown', key, true); resolve(v); };
    const okBtn = d.querySelector('[data-a=ok]');
    const sync = () => {
      if (okLabel) okBtn.textContent = okLabel(values());
      if (okEnabled) okBtn.disabled = !okEnabled(values());
    };
    const key = e => {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(null); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); if (!okBtn.disabled) done(values()); }
      else e.stopPropagation();
    };
    document.addEventListener('keydown', key, true);
    d.querySelector('[data-a=cancel]').onclick = () => done(null);
    d.querySelector('[data-a=ok]').onclick = () => done(values());
    modal.onmousedown = e => { if (e.target === modal) done(null); };
    d.querySelectorAll('input[type=checkbox]').forEach(i => i.onchange = sync);
    d.querySelectorAll('input[type=text]').forEach(i => i.oninput = sync);
    sync();
    const first = d.querySelector('input[type=text]') || (okBtn.disabled ? d.querySelector('input, [data-a=cancel]') : okBtn);
    setTimeout(() => { first.focus(); first.select?.(); });
  });
}

export function debounce(fn, ms) {
  let t = null, last = [];
  const f = (...a) => { last = a; clearTimeout(t); t = setTimeout(() => { t = null; fn(...last); }, ms); };
  // Run a pending call now, with the arguments it was scheduled with.
  f.flush = () => { if (t) { clearTimeout(t); t = null; return fn(...last); } };
  f.cancel = () => { clearTimeout(t); t = null; };
  f.pending = () => t !== null;
  return f;
}

// "/Users/me/Desktop/July 4th" -> "Desktop/July 4th"
export function prettyDir(dir) {
  if (!dir) return 'Desktop';
  const parts = String(dir).replace(/\/+$/, '').split('/');
  const i = parts.lastIndexOf('Desktop');
  if (i >= 0) return parts.slice(i).join('/');
  return parts.slice(-2).join('/');
}
