// The marks bar under the photo (Edit and loupe): Pick · Favorite · Reject (the same order everywhere).
// Same marks, same API and the same undo as the keyboard (P / F / X / U keep working).
import { store, rate } from './store.js';
import { glyph } from './marks.js';

export function mountRateBar(el, getKey) {
  el.innerHTML = `
    <button class="rb mark" data-a="pick" title="Pick (P)" aria-pressed="false">${glyph('pick', 18)}</button>
    <button class="rb mark" data-a="favorite" title="Favorite (F)" aria-pressed="false">${glyph('favorite', 18)}</button>
    <button class="rb mark" data-a="reject" title="Reject (X)" aria-pressed="false">${glyph('reject', 18)}</button>`;
  el.setAttribute('role', 'toolbar');
  el.setAttribute('aria-label', 'Marks');
  el.addEventListener('click', e => {
    const b = e.target.closest('button');
    const key = getKey(), p = key && store.byKey.get(key);
    if (!b || !p) return;
    b.blur();
    if (b.dataset.a === 'pick') rate([key], { flag: p.flag === 'pick' ? null : 'pick' });
    else if (b.dataset.a === 'reject') rate([key], { flag: p.flag === 'reject' ? null : 'reject' });
    else if (b.dataset.a === 'favorite') rate([key], { favorite: !p.favorite });
  });
}

export function paintRateBar(el, p) {
  if (!el || !p) return;
  const set = (sel, on) => { const b = el.querySelector(sel); b.classList.toggle('on', on); b.setAttribute('aria-pressed', String(on)); };
  set('[data-a=pick]', p.flag === 'pick');
  set('[data-a=reject]', p.flag === 'reject');
  set('[data-a=favorite]', !!p.favorite);
}
