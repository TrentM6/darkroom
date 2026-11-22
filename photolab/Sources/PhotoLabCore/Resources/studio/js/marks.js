// Darkroom grease-pencil marks, drawn as SVG over a frame of w x h pixels, and the small UI glyphs
// drawn from the same geometry, so the app speaks one visual language:
//   pick / Selects: a china-marker loop · reject: an ✕ · favorite / Best Work: a star
// Every stroke is seeded by the photo id, so a mark looks the same each time it is drawn.

function hash(str) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const r2 = v => Math.round(v * 100) / 100;

// Catmull-Rom through the points, as cubic Béziers (one path string).
function smooth(pts, close = false) {
  let d = `M${r2(pts[0][0])} ${r2(pts[0][1])}`;
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] || pts[i], p1 = pts[i], p2 = pts[i + 1], p3 = pts[i + 2] || p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C${r2(c1[0])} ${r2(c1[1])} ${r2(c2[0])} ${r2(c2[1])} ${r2(p2[0])} ${r2(p2[1])}`;
  }
  return close ? d + ' Z' : d;
}
const poly = (pts, close = false) => 'M' + pts.map(p => `${r2(p[0])} ${r2(p[1])}`).join(' L') + (close ? ' Z' : '');

// A clean pencil line: one constant-width stroke over a soft halo (the halo separates it from busy or
// dark pictures). No blobs, no texture passes. Drawn on (once) when the mark is applied.
function pencil(d, sw, hk, anim, cls = '') {
  const st = anim ? ` style="animation-delay:${Math.round(anim.delay)}ms"` : '', dr = (anim ? ' draw' : '') + (cls ? ' ' + cls : '');
  return `<path class="mh${dr}" d="${d}" pathLength="1" stroke-width="${r2(sw * hk)}"${st}/>`
    + `<path class="mp${dr}" d="${d}" pathLength="1" stroke-width="${r2(sw)}"${st}/>`;
}

// The loop: a rounded rectangle that hugs its own frame (an even margin of a few pixels, corners just
// outside the picture's corners), drawn once around with a gentle hand wobble and a short overshoot
// that runs a little wide where it closes, like a china marker lifted at the end.
function hugPts(w, h, mx, my, rand, ox = 0, oy = 0, lw = 0) {
  // Corner radius: as round as it can be while the line (and its width) still clears the picture's corner.
  const mm = Math.min(mx, my);
  const R = Math.max(mm, Math.min(0.2 * Math.min(w, h) + mm, (mm * Math.SQRT2 - lw / 2 - 0.5) / (Math.SQRT2 - 1)));
  const x0 = ox - mx, y0 = oy - my, x1 = ox + w + mx, y1 = oy + h + my;
  const sw = x1 - x0 - 2 * R, sh = y1 - y0 - 2 * R, q = Math.PI * R / 2;
  const P = 2 * sw + 2 * sh + 4 * q;
  // Point and outward normal at arc length t from the middle of the top edge, clockwise.
  const at = t => {
    t = ((t % P) + P) % P;
    const segs = [
      [sw / 2, l => [x0 + R + sw / 2 + l, y0, 0, -1]],
      [q, l => { const a = -Math.PI / 2 + l / R; return [x1 - R + R * Math.cos(a), y0 + R + R * Math.sin(a), Math.cos(a), Math.sin(a)]; }],
      [sh, l => [x1, y0 + R + l, 1, 0]],
      [q, l => { const a = l / R; return [x1 - R + R * Math.cos(a), y1 - R + R * Math.sin(a), Math.cos(a), Math.sin(a)]; }],
      [sw, l => [x1 - R - l, y1, 0, 1]],
      [q, l => { const a = Math.PI / 2 + l / R; return [x0 + R + R * Math.cos(a), y1 - R + R * Math.sin(a), Math.cos(a), Math.sin(a)]; }],
      [sh, l => [x0, y1 - R - l, -1, 0]],
      [q, l => { const a = Math.PI + l / R; return [x0 + R + R * Math.cos(a), y0 + R + R * Math.sin(a), Math.cos(a), Math.sin(a)]; }],
      [sw / 2, l => [x0 + R + l, y0, 0, -1]],
    ];
    for (const [len, f] of segs) { if (t <= len) return f(t); t -= len; }
    return segs[0][1](0);
  };
  const m = Math.min(mx, my);
  const start = P * (0.62 + rand() * 0.1);            // starts on the left side, upper half
  const over = 0.035 + rand() * 0.02;                 // overshoot past the start
  const ph1 = rand() * 6.28, ph2 = rand() * 6.28, amp = m * (0.3 + rand() * 0.15);
  // A hand never draws it quite level: turned a fraction of a degree about the frame's centre.
  const tilt = (rand() - 0.5) * 0.018, cx = ox + w / 2, cy = oy + h / 2, ct = Math.cos(tilt), st = Math.sin(tilt);
  const N = Math.max(48, Math.min(120, Math.round(P / 6))), pts = [];
  for (let i = 0; i <= N; i++) {
    const u = i / N, t = start + P * (1 + over) * u;
    const [x, y, nx, ny] = at(t);
    // Gentle irregularity, and a slight outward drift so the tail passes outside the start.
    const o = amp * (0.6 * Math.sin(2 * Math.PI * u * 2 + ph1) + 0.4 * Math.sin(2 * Math.PI * u * 3 + ph2)) * 0.5 + m * (-0.15 + 0.45 * u);
    const px = x + nx * o - cx, py = y + ny * o - cy;
    pts.push([cx + px * ct - py * st, cy + px * st + py * ct]);
  }
  return pts;
}

// A gently bowed line with a little hand wobble, as points.
function linePts(x0, y0, x1, y1, rand, bend, N = 14) {
  const len = Math.hypot(x1 - x0, y1 - y0) || 1, nx = -(y1 - y0) / len, ny = (x1 - x0) / len;
  const bow = (rand() - 0.5) * 2 * bend * len, ph = rand() * 6.28;
  const pts = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N, o = bow * Math.sin(Math.PI * t) + Math.sin(t * 9 + ph) * len * 0.004;
    pts.push([x0 + (x1 - x0) * t + nx * o, y0 + (y1 - y0) * t + ny * o]);
  }
  return pts;
}

// The star: a clean five-point outline (no crossing lines), slightly rounded at the joins by the
// stroke. Tips vary a hair per photo so it still reads as drawn by hand. One geometry everywhere.
function pentagram(cx, cy, r, rand, rot = 0) {
  const pts = [], ri = r * 0.45;
  for (let i = 0; i < 10; i++) {
    const a = -Math.PI / 2 + rot + i * Math.PI / 5, rr = i % 2 ? ri : r * (0.97 + rand() * 0.06);
    pts.push([cx + Math.cos(a) * rr, cy + Math.sin(a) * rr]);
  }
  pts.push(pts[0]);
  return pts;
}
// Straight segments between dense points: keep the tips sharp.
const polyline = pts => 'M' + pts.map(p => `${r2(p[0])} ${r2(p[1])}`).join(' L') + (pts.length > 2 && pts[0] === pts[pts.length - 1] ? ' Z' : '');

// Stroke weight for a frame. Projects: about 4 px at the default thumbnail size, never under 2.4 px.
// Collections (calm): about 2.7 px, 1.8–3 px.
const weight = m => Math.max(2.4, Math.min(4.2, m * 0.034));
const weightCalm = m => Math.max(1.8, Math.min(3, m * 0.02));

// How a view marks its frames: the same everywhere. A Select carries its circle and Best Work its star in every
// view (projects, All Selects, Best Work, collections, loupe, editor strip), in one style: the calm weight and red.
export function marksFor() {
  return { calm: true };
}

// SVG overlay for one frame. opts: {animate: Set('pick'|'favorite'|'reject'), calm, loop: false = no pick
// loop, pad: the room around the frame in px (contact sheet: the gap to the next frame)}.
// The SVG is static: it is only rebuilt when the photo's marks or the frame size change.
export function marksSVG(p, w, h, opts = {}) {
  if (!p || (!p.flag && !p.favorite)) return '';
  const loop = opts.loop !== false, calm = !!opts.calm, hk = calm ? 1.3 : 1.45;
  if (!loop && !p.favorite) return '';
  const seed = hash(String(p.key || p.id));
  const anim = opts.animate || new Set();
  const m = Math.min(w, h), sw = calm ? weightCalm(m) : weight(m);
  let body = '';
  if (p.flag === 'reject') {
    // Two clean strokes, corner to corner, slightly past the frame.
    const rand = rng(seed ^ 0x51), o = 0.03, j = () => (rand() - 0.5) * 0.02;
    const a = anim.has('reject') ? { delay: 0 } : null, b = anim.has('reject') ? { delay: 90 } : null;
    const k = calm ? 0.85 : 1.1;
    body += pencil(smooth(linePts(w * (-o + j()), h * (-o + j()), w * (1 + o + j()), h * (1 + o + j()), rand, 0.02)), sw * k, hk, a);
    body += pencil(smooth(linePts(w * (1 + o + j()), h * (-o + j()), w * (-o + j()), h * (1 + o + j()), rand, 0.02)), sw * k, hk, b);
  } else if (p.flag === 'pick' || p.favorite) {
    const a = anim.has('pick') || anim.has('favorite') ? { delay: 0 } : null;
    if (loop) {
      // Margin: a few pixels all round; in the contact sheet never past the gap to the next frame.
      const room = opts.pad;
      const mx = room != null ? Math.max(1.5, Math.min(9, room - sw / 2 - 1)) : Math.max(4, Math.min(9, m * 0.05));
      const my = room != null ? Math.max(mx, Math.min(mx * 1.2, 10)) : mx;
      body += pencil(smooth(hugPts(w, h, mx, my, rng(seed), 0, 0, sw)), sw, hk, a);
    }
    if (p.favorite) {
      // A small filled star on the frame's top-right corner, turned a little per photo.
      const rand = rng(seed ^ 0x9e37), r = Math.max(5, h * 0.11);
      const cx = w - r * 0.55, cy = r * 0.5;
      const b = anim.has('favorite') ? { delay: a && p.flag === 'pick' ? 160 : 0 } : null;
      body += pencil(polyline(pentagram(cx, cy, r, rand, (rand() - 0.5) * 0.3)), Math.max(1.4, sw * 0.5), hk, b, 'star');
    }
  }
  return `<svg class="marks${calm ? ' calm' : ''}" viewBox="0 0 ${r2(w)} ${r2(h)}" width="${r2(w)}" height="${r2(h)}" aria-hidden="true" focusable="false">${body}</svg>`;
}

// Small UI glyphs from the same hand: 'pick' (loop), 'reject' (✕), 'favorite' (star). currentColor;
// the star fills when its control is on (CSS).
const glyphCache = new Map();
export function glyph(kind, size = 16) {
  const key = kind + size;
  if (glyphCache.has(key)) return glyphCache.get(key);
  const rand = rng(kind === 'pick' ? 1103 : kind === 'reject' ? 2207 : 3301);
  let body = '';
  if (kind === 'pick') {
    // The loop mark, around a small frame.
    const fw = size * 0.5, fh = size * 0.36, mg = size * 0.09;
    body = `<path d="${smooth(hugPts(fw, fh, mg, mg, rand, (size - fw) / 2, (size - fh) / 2))}"/>`;
  } else if (kind === 'reject') {
    const a = size * 0.2, z = size * 0.8;
    body = `<path d="${smooth(linePts(a, a, z, z, rand, 0.04, 6))}"/><path d="${smooth(linePts(z, a, a, z, rand, 0.04, 6))}"/>`;
  } else {
    // The favorite mark's star: the same one-stroke pentagram (filled when its control is on).
    body = `<path class="gf" d="${polyline(pentagram(size / 2, size * 0.54, size * 0.44, rand, 0))}"/>`;
  }
  const svg = `<svg class="glyph g-${kind}" focusable="false" viewBox="0 0 ${size} ${size}" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
  glyphCache.set(key, svg);
  return svg;
}
