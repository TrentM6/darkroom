// Edit parameters: slider definitions, neutral values and the instant CSS approximation.
const sgn = d => v => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(d);
const int = v => String(Math.round(v));
const pct = v => Math.round(v) + '%';

export const SECTIONS = [
  { id: 'look', title: 'My Look' },
  { id: 'light', title: 'Light', ctls: [
    { k: 'exposure', label: 'Exposure', min: -2, max: 2, step: 0.05, fmt: sgn(2) },
    { k: 'contrast', label: 'Contrast', min: 0, max: 100, step: 1, fmt: int },
    // Shown Lightroom-style: left (negative) recovers highlights. The server's value is the opposite
    // sign (+ = recovery), so the slider shows and sends −value; params, copy/paste and undo keep the server's sign.
    { k: 'highlights', label: 'Highlights', min: -100, max: 100, step: 1, fmt: sgn(0), invert: true },
    { k: 'shadows', label: 'Shadows', min: -100, max: 100, step: 1, fmt: sgn(0) },
    { k: 'blacks', label: 'Blacks', min: -50, max: 50, step: 1, fmt: sgn(0) },
  ] },
  { id: 'colour', title: 'Colour', ctls: [
    { k: 'warmth', label: 'Warmth', min: -50, max: 50, step: 1, fmt: sgn(0) },
    { k: 'tint', label: 'Tint', min: -50, max: 50, step: 1, fmt: sgn(0) },
    { k: 'vibrance', label: 'Vibrance', min: -100, max: 100, step: 1, fmt: sgn(0) },
    { k: 'saturation', label: 'Saturation', min: -100, max: 100, step: 1, fmt: sgn(0) },
  ] },
  // Casts that differ by tone (film scans: blue-green shadows, pink highlights). Neutralize sets them from the photo.
  { id: 'balance', title: 'Colour Balance', ctls: [
    { k: 'shadowWarmth', label: 'Warmth', group: 'Shadows', min: -50, max: 50, step: 1, fmt: sgn(0) },
    { k: 'shadowTint', label: 'Tint', group: 'Shadows', min: -50, max: 50, step: 1, fmt: sgn(0) },
    { k: 'highlightWarmth', label: 'Warmth', group: 'Highlights', min: -50, max: 50, step: 1, fmt: sgn(0) },
    { k: 'highlightTint', label: 'Tint', group: 'Highlights', min: -50, max: 50, step: 1, fmt: sgn(0) },
  ] },
  { id: 'film', title: 'Film', ctls: [
    { k: 'filmStrength', label: 'Amount', min: 0, max: 100, step: 1, fmt: pct },
  ] },
  { id: 'effects', title: 'Effects', ctls: [
    { k: 'punch', label: 'Punch', min: 0, max: 100, step: 1, fmt: int },
    { k: 'vignette', label: 'Vignette', min: 0, max: 100, step: 1, fmt: int },
    { k: 'sharpen', label: 'Sharpen', min: 0, max: 100, step: 1, fmt: int },
    { k: 'grain', label: 'Grain', min: 0, max: 100, step: 1, fmt: int },
  ] },
  { id: 'geometry', title: 'Geometry', ctls: [
    { k: 'rotate', label: 'Straighten', min: -10, max: 10, step: 0.1, fmt: v => sgn(1)(v) + '°' },
  ] },
  { id: 'frame', title: 'Frame' },
];
export const LOOK_AMOUNT = { k: 'lookAmount', label: 'Amount', min: 0, max: 150, step: 1, fmt: pct };
export const FRAME_CTLS = [
  { k: 'side', label: 'Sides', min: 0, max: 5, step: 0.1, fmt: v => v.toFixed(1) + '%' },
  { k: 'topBottom', label: 'Top/Bottom', min: 0, max: 5, step: 0.1, fmt: v => v.toFixed(1) + '%' },
];
export const CTL = Object.fromEntries([LOOK_AMOUNT, ...SECTIONS.flatMap(s => s.ctls || [])].map(c => [c.k, c]));

// My Look = the look-defining parameters only.
export const LOOK_KEYS = ['film', 'filmStrength', 'contrast', 'blacks', 'punch', 'vibrance', 'saturation', 'warmth', 'tint', 'vignette', 'sharpen', 'grain', 'grainSize'];
const SCALED = LOOK_KEYS.filter(k => k !== 'film' && k !== 'grainSize' && k !== 'grain');
export const GRAIN_SIZES = [['fine', 'Fine'], ['medium', 'Medium'], ['coarse', 'Coarse']];
const STRINGS = new Set(['film', 'grainSize', 'crop']);

export const NEUTRAL = {
  exposure: 0, contrast: 0, highlights: 0, shadows: 0, blacks: 0, punch: 0, vibrance: 0, saturation: 0,
  warmth: 0, tint: 0, film: '', filmStrength: 0, vignette: 0, rotate: 0, sharpen: 0, grain: 0, grainSize: 'fine',
  shadowWarmth: 0, shadowTint: 0, highlightWarmth: 0, highlightTint: 0,
  lookAmount: 100, crop: null,
};
export const norm = q => {
  const o = { ...NEUTRAL, ...(q || {}) };
  for (const k of Object.keys(NEUTRAL)) if (!STRINGS.has(k) && typeof o[k] !== 'number') o[k] = Number(o[k]) || NEUTRAL[k];
  if (!['fine', 'medium', 'coarse'].includes(o.grainSize)) o.grainSize = 'fine';
  return o;
};
export const sameParams = (a, b) => Object.keys(NEUTRAL).every(k =>
  k === 'film' || k === 'grainSize' ? (a[k] || '') === (b[k] || '')
    : k === 'crop' ? JSON.stringify(a.crop || null) === JSON.stringify(b.crop || null)
      : Math.abs(a[k] - b[k]) < 1e-6);

export const FILMS_FALLBACK = [
  ['Kodak/Kodak Kodachrome 64.png', 'Kodachrome 64'], ['Kodak/Kodak Kodachrome 200.png', 'Kodachrome 200'],
  ['Kodak/Kodak Ektachrome 100 VS.png', 'Ektachrome 100 VS'], ['Kodak/Kodak Ektar 100.png', 'Ektar 100'],
  ['Kodak/Kodak Portra 400 2.png', 'Portra 400'], ['Kodak/Kodak Portra 800 2.png', 'Portra 800'],
  ['Fuji/Fuji Superia 400 2.png', 'Superia 400'], ['Fuji/Fuji 400H 2.png', 'Fuji 400H'],
].map(([path, name]) => ({ path, name }));

// What the renderer effectively applies: look-defining sliders scaled by the Look amount.
function effective(p) {
  const e = { ...p }, a = (p.lookAmount ?? 100) / 100;
  for (const k of SCALED) e[k] = p[k] * a;
  return e;
}

// CSS approximation of `cur` relative to the params the on-screen image was rendered with.
// Returns {filter, matrix, rotate (deg, CSS sense), vignette (0..1)}.
export function approx(cur, shown) {
  const a = effective(cur), b = effective(shown), d = k => (a[k] || 0) - (b[k] || 0);
  const bright = Math.pow(2, d('exposure') * 0.75) * (1 + d('shadows') * 0.0025 - d('highlights') * 0.0012 + d('blacks') * 0.002);
  const contrast = 1 + d('contrast') * 0.006 - d('blacks') * 0.006 + d('punch') * 0.002 + d('filmStrength') * 0.0015;
  const sat = Math.max(0, 1 + d('saturation') * 0.01 + d('vibrance') * 0.006 + d('filmStrength') * 0.003);
  const w = (d('warmth') + (d('shadowWarmth') + d('highlightWarmth')) * 0.4) * 0.3, t = (d('tint') + (d('shadowTint') + d('highlightTint')) * 0.4) * 0.3;
  const rG = 1 + w * 0.006 + t * 0.005, gG = 1 - t * 0.008, bG = 1 - w * 0.014 + t * 0.003;
  const parts = [];
  if (w || t) parts.push('url(#wbx)');
  if (Math.abs(bright - 1) > 1e-3) parts.push(`brightness(${bright.toFixed(3)})`);
  if (Math.abs(contrast - 1) > 1e-3) parts.push(`contrast(${contrast.toFixed(3)})`);
  if (Math.abs(sat - 1) > 1e-3) parts.push(`saturate(${sat.toFixed(3)})`);
  return {
    filter: parts.join(' '),
    matrix: `${rG} 0 0 0 0  0 ${gG} 0 0 0  0 0 ${bG} 0 0  0 0 0 1 0`,
    rotate: -d('rotate'),           // renderer: + = counter-clockwise
    vignette: Math.max(0, Math.min(1, d('vignette') / 100)),
  };
}

// Crop: {aspect, portrait, x, y, w, h} normalised to the (straightened) image; null = full frame.
export const ASPECTS = [['original', 'Original'], ['3:2', '3:2'], ['4:5', '4:5'], ['1:1', '1:1'], ['16:9', '16:9']];
export function aspectRatio(aspect, portrait) {
  if (!aspect || aspect === 'original') return null;
  const [x, y] = aspect.split(':').map(Number);
  const long = Math.max(x, y) / Math.min(x, y);
  return portrait ? 1 / long : long;
}
// The largest rect of ratio r (w/h in pixels) inside an image of aspect A, centred on (cx, cy).
export function fitCrop(r, A, cx = 0.5, cy = 0.5) {
  let w, h;
  if (r < A) { h = 1; w = r / A; } else { w = 1; h = A / r; }
  const x = Math.min(1 - w, Math.max(0, cx - w / 2)), y = Math.min(1 - h, Math.max(0, cy - h / 2));
  return { x: round4(x), y: round4(y), w: round4(w), h: round4(h) };
}
export const round4 = v => Math.round(v * 10000) / 10000;
