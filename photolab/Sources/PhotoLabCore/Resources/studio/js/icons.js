// One icon set: 24px grid, outline, currentColor. Stroke width comes from CSS (--icon-stroke), so it
// can match the weight of the text beside it (1.5 beside regular, 2 beside medium/semibold).
const s = body => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const f = body => `<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

const FLAG = '<path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><path d="M4 22v-7"/>';
const HEART = '<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>';

export const ICONS = {
  back: s('<path d="m15 18-6-6 6-6"/>'),
  plus: s('<path d="M5 12h14"/><path d="M12 5v14"/>'),
  export: s('<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m17 8-5-5-5 5"/><path d="M12 3v12"/>'),
  grid: s('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/>'),
  gridFill: f('<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/>'),
  film: s('<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M7 3v18"/><path d="M3 7.5h4"/><path d="M3 12h18"/><path d="M3 16.5h4"/><path d="M17 3v18"/><path d="M17 7.5h4"/><path d="M17 16.5h4"/>'),
  more: s('<circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/><circle cx="5" cy="12" r="1"/>'),
  flag: s(FLAG),
  flagFill: f(FLAG),
  heart: s(HEART),
  heartFill: f(HEART),
  reject: s('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'),
  warn: s('<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>'),
  frame: s('<rect x="3" y="3" width="18" height="18" rx="2"/><rect x="7" y="7" width="10" height="10" rx="1"/>'),
  crop: s('<path d="M6 2v14a2 2 0 0 0 2 2h14"/><path d="M18 22V8a2 2 0 0 0-2-2H2"/>'),
  before: s('<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M12 3v18"/>'),
  chev: s('<path d="m6 9 6 6 6-6"/>'),
  notes: s('<path d="M4 6h16"/><path d="M4 12h16"/><path d="M4 18h10"/>'),
  close: s('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'),
  orient: s('<rect x="4" y="8" width="10" height="13" rx="1.5"/><path d="M14 3h3a3 3 0 0 1 3 3v3"/><path d="m17 7 3 3 3-3"/>'),
  folder: s('<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'),
  settings: s('<path d="M20 7h-9"/><path d="M14 17H5"/><circle cx="17" cy="17" r="3"/><circle cx="7" cy="7" r="3"/>'),
  stack: s('<rect x="3" y="8" width="18" height="13" rx="2"/><path d="M6 5h12"/><path d="M9 2h6"/>'),
  folderPlus: s('<path d="M12 10v6"/><path d="M9 13h6"/><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'),
};

export function icon(name, cls = 'ic') {
  return `<span class="${cls}">${ICONS[name] || ''}</span>`;
}

// Two-state icon: both kept in the DOM, cross-faded by CSS (.swap / .swap.on).
export function swapIcon(off, on, cls = 'ic swap') {
  return `<span class="${cls}"><span class="i-off">${ICONS[off]}</span><span class="i-on">${ICONS[on]}</span></span>`;
}

// Fill <span data-icon="..."> placeholders in static markup.
export function hydrateIcons(root = document) {
  root.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = ICONS[el.dataset.icon] || ''; });
}
