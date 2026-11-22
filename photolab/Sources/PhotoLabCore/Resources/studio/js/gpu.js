// Real-time preview on the GPU (WebGL2): the whole edit is applied to the UNEDITED proxy every frame.
// It draws the server's `pipeline` (the exact values written to RawTherapee and the grain step, at proxy
// scale: curve LUT, LabGrid, radii, vignette, grain, AutoFill...). While a slider moves ahead of the server,
// the fields that slider drives are recomputed with the same formulas as AutoEdit.swift pp3Sections;
// everything else stays the server's. Stages:
//   exposure (linear) → highlight compression → Film-like tone curve (contrast, blacks, highlights−/shadows−)
//   → saturation → film (Hald CLUT, blended by Amount) → Lab: shadows lift, local contrast (punch),
//   vibrance, warmth/tint (LabGrid a*/b* shift) → vignette → grain; straighten (rotate + autofill) and crop.
// The server render is still the reference; this only has to be close enough that swapping is barely visible.

const VS = `#version 300 es
in vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }`;

const FS = `#version 300 es
precision highp float;
precision highp sampler3D;
uniform sampler2D uSrc;      // unedited proxy, sRGB texture (samples are linear), mipmapped
uniform sampler2D uBlur;     // the same proxy, gamma-encoded mips: neighbourhood averages close to Lab L averages
uniform sampler2D uCurve;    // tone curve LUT (R16F, pipeline.curve.lut: 256 steps), gamma domain
uniform sampler3D uLut;      // film Hald CLUT
uniform vec4 uBox;           // content box in canvas pixels (x, y, w, h), y from the top
uniform vec2 uCanvas;        // canvas size in pixels
uniform vec4 uRegion;        // crop region in straightened coords (x, y, w, h)
uniform float uAspect;       // source w / h
uniform float uRot;          // radians (+ = counter-clockwise, as RawTherapee)
uniform float uFill;         // autofill scale for the rotation
uniform float uExpo;         // 2^EV
uniform float uHlc;          // RawTherapee highlight compression: comp = (max(0, EV) + 1) * HighlightCompr / 100
uniform float uSat;          // exposure-tab saturation factor (1 + s/100)
uniform float uChroma;       // Lab chromaticity (saturated-red guard), fraction; before the film LUT
uniform float uFilm;         // film strength 0..1 (0 = none)
uniform float uLutN;         // CLUT cube size
uniform vec2 uVib;           // vibrance: pastels, saturated (fractions)
uniform vec2 uAB;            // Lab a*, b* shift
uniform vec2 uBalS, uBalH;   // colour balance by tone: Lab a*, b* for the shadows and the highlights (Balance.swift)
uniform float uPunch;        // local contrast amount
uniform float uShadows;      // shadow lift 0..1
uniform float uLodPunch, uLodShadow;
uniform float uVig;          // vignette strength (stops)
uniform float uGrain;        // grain amplitude (fraction of full scale at the midtones)
uniform vec3 uGrainMix;      // single weight, clump size, clump weight
uniform float uGrainCells;   // grain cells across the long edge
uniform float uSeed;
uniform vec4 uTune;
uniform vec4 uTune2;         // shadow tonal width, mode          // calibration: base gain, highlight compression, shadow lift, vignette
out vec4 frag;

vec3 toLin(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 toGam(vec3 c) { c = max(c, 0.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
float curve(float x) { float n = float(textureSize(uCurve, 0).x); return texture(uCurve, vec2(clamp(x, 0.0, 1.0) * ((n - 1.0) / n) + 0.5 / n, 0.5)).r; }

// Linear sRGB <-> CIELab (D65)
vec3 lin2xyz(vec3 c) { return mat3(0.4124564, 0.2126729, 0.0193339, 0.3575761, 0.7151522, 0.1191920, 0.1804375, 0.0721750, 0.9503041) * c; }
vec3 xyz2lin(vec3 x) { return mat3(3.2404542, -0.9692660, 0.0556434, -1.5371385, 1.8760108, -0.2040259, -0.4985314, 0.0415560, 1.0572252) * x; }
float fLab(float t) { return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0; }
float fInv(float t) { return t > 0.206897 ? t * t * t : (t - 16.0 / 116.0) / 7.787; }
vec3 lin2lab(vec3 c) {
  vec3 x = lin2xyz(max(c, 0.0)) / vec3(0.95047, 1.0, 1.08883);
  vec3 f = vec3(fLab(x.x), fLab(x.y), fLab(x.z));
  return vec3(116.0 * f.y - 16.0, 500.0 * (f.x - f.y), 200.0 * (f.y - f.z));
}
vec3 lab2lin(vec3 l) {
  float fy = (l.x + 16.0) / 116.0, fx = fy + l.y / 500.0, fz = fy - l.z / 200.0;
  return xyz2lin(vec3(fInv(fx), fInv(fy), fInv(fz)) * vec3(0.95047, 1.0, 1.08883));
}

// The first part of the pipeline (per pixel): exposure, highlight compression, tone curve,
// saturation, film. Returns gamma-encoded sRGB.
vec3 tone(vec3 lin) {
  lin *= uTune.x;
  // RawTherapee (curves.cc, threshold 0): out = ln(1 + comp * 2^EV * x) / comp over the whole range.
  float comp = uHlc * uTune.y;
  lin = comp > 0.0 ? log(1.0 + comp * uExpo * lin) / comp : lin * uExpo;
  vec3 g = toGam(lin);
  g = clamp(g, 0.0, 1.0);
  // Film-like curve: the curve on the largest and smallest channel, the middle one in proportion (keeps hue).
  float mx = max(g.r, max(g.g, g.b)), mn = min(g.r, min(g.g, g.b));
  float cmx = curve(mx), cmn = curve(mn);
  vec3 o = mx - mn > 1e-5 ? cmn + (g - mn) * (cmx - cmn) / (mx - mn) : vec3(cmx);
  // Exposure-tab saturation (HSV-like around the value)
  if (uSat != 1.0) { float v = max(o.r, max(o.g, o.b)); o = clamp(v + (o - v) * uSat, 0.0, 1.0); }
  if (uChroma != 0.0) { vec3 l = lin2lab(toLin(o)); l.yz *= 1.0 + uChroma; o = clamp(toGam(lab2lin(l)), 0.0, 1.0); }
  if (uFilm > 0.0) {
    vec3 t = clamp(o, 0.0, 1.0) * ((uLutN - 1.0) / uLutN) + 0.5 / uLutN;
    vec3 lt = texture(uLut, t).rgb;
    o = uTune2.w > 0.5 ? toGam(mix(toLin(o), toLin(lt), uFilm)) : mix(o, lt, uFilm);
  }
  return o;
}

float hash12(vec2 p) {   // stable hash (cell coordinates) -> 0..1
  uvec2 q = uvec2(ivec2(p) + 65536) * uvec2(1597334673u, 3812015801u);
  uint n = (q.x ^ q.y ^ uint(uSeed)) * 1597334673u;
  n ^= n >> 15; n *= 2246822519u; n ^= n >> 13;
  return float(n) / 4294967295.0;
}
float gauss(vec2 c) { return (hash12(c) + hash12(c + 17.3) + hash12(c + 41.7) + hash12(c + 73.1) - 2.0) * 1.7320508; }
float grainAt(vec2 cell) {
  float cs = uGrainMix.y;
  vec2 f = cell / cs, i = floor(f), t = f - i;
  t = t * t * (3.0 - 2.0 * t);
  float clump = mix(mix(gauss(i + 1000.0), gauss(i + vec2(1001.0, 1000.0)), t.x), mix(gauss(i + vec2(1000.0, 1001.0)), gauss(i + 1001.0), t.x), t.y);
  return uGrainMix.x * gauss(floor(cell)) + uGrainMix.z * clump;
}

void main() {
  vec2 px = vec2(gl_FragCoord.x, uCanvas.y - gl_FragCoord.y);
  vec2 u = (px - uBox.xy) / uBox.zw;
  if (u.x < 0.0 || u.y < 0.0 || u.x > 1.0 || u.y > 1.0) { frag = vec4(0.0); return; }
  // crop region -> straightened frame -> source (undo the rotation, autofill)
  vec2 s = uRegion.xy + u * uRegion.zw;
  vec2 p = (s - 0.5) * vec2(uAspect, 1.0);
  float c = cos(uRot), sn = sin(uRot);
  vec2 q = vec2(c * p.x - sn * p.y, sn * p.x + c * p.y) / uFill;
  vec2 uv = q / vec2(uAspect, 1.0) + 0.5;

  vec3 src = texture(uSrc, uv).rgb;
  vec3 g = tone(src);
  vec3 lab = lin2lab(toLin(g));

  if (uShadows > 0.0 || uPunch > 0.0) {
    // Neighbourhood brightness from a coarse mip of the source, through the same tone stage.
    vec2 d = 1.0 / vec2(textureSize(uSrc, 0));
    if (uShadows > 0.0) {
      float lb = lin2lab(toLin(tone(toLin(textureLod(uBlur, uv, uLodShadow).rgb)))).x;
      // Shadows & Highlights (tonal width 30, radius 40): a proportional lift where the neighbourhood is dark.
      float m = 1.0 - smoothstep(0.0, uTune2.x, lb);
      lab.x = uTune2.y > 0.5 ? lab.x * (1.0 + uShadows * uTune.z / 100.0 * m) : lab.x + uShadows * uTune.z * m * (1.0 - lab.x / 100.0);
    }
    if (uPunch > 0.0) {
      vec3 bl = textureLod(uBlur, uv, uLodPunch).rgb * 0.4
        + (textureLod(uBlur, uv + vec2(d.x, 0.0) * exp2(uLodPunch), uLodPunch).rgb + textureLod(uBlur, uv - vec2(d.x, 0.0) * exp2(uLodPunch), uLodPunch).rgb
         + textureLod(uBlur, uv + vec2(0.0, d.y) * exp2(uLodPunch), uLodPunch).rgb + textureLod(uBlur, uv - vec2(0.0, d.y) * exp2(uLodPunch), uLodPunch).rgb) * 0.15;
      float lb = lin2lab(toLin(tone(toLin(bl)))).x;
      lab.x = clamp(lab.x + uPunch * (lab.x - lb), 0.0, 100.0);
    }
  }
  // Vibrance: low-chroma colours gain most ("pastels"), saturated ones less.
  if (uVib.x != 0.0 || uVib.y != 0.0) {
    float C = length(lab.yz);
    float w = 1.0 - smoothstep(0.0, 60.0, C);
    lab.yz *= 1.0 + uVib.x * w * 0.6 + uVib.y * (1.0 - w) * 0.35;
  }
  lab.yz += uAB;
  vec3 lin = lab2lin(lab);

  if (uVig > 0.0) {
    // PCVignette (feather 60, roundness 50): an ellipse with the frame's proportions through the corners,
    // full strength there, none inside (1 - feather) / sqrt 2 of the way out.
    float r = length((u - 0.5) * 2.0) / 1.41421356;
    float ri = (1.0 - 0.6) / 1.41421356;
    float t = clamp((r - ri) / (1.0 - ri), 0.0, 1.0);
    float f = uTune2.z < 0.5 ? t : uTune2.z < 1.5 ? t * t * (3.0 - 2.0 * t) : sin(t * 1.5707963);
    lin *= exp2(-uVig * uTune.w * f);
  }
  vec3 o = toGam(lin);
  if (uBalS != vec2(0.0) || uBalH != vec2(0.0)) {
    // Balance.swift, exactly: after everything else, before the grain, on the encoded result.
    vec3 bl = lin2lab(toLin(clamp(o, 0.0, 1.0)));
    float t = smoothstep(15.0, 85.0, bl.x);
    float ws = (1.0 - t) * smoothstep(0.0, 12.0, bl.x), wh = t * (1.0 - smoothstep(97.0, 100.0, bl.x));
    bl.yz += uBalS * ws + uBalH * wh;
    o = clamp(toGam(lab2lin(bl)), 0.0, 1.0);
  }
  if (uGrain > 0.0) {
    vec2 cells = vec2(uGrainCells) * (uAspect >= 1.0 ? vec2(1.0, 1.0 / uAspect) : vec2(uAspect, 1.0));
    float n = grainAt(s * cells);
    float Y = dot(o, vec3(0.2126, 0.7152, 0.0722));
    o += uGrain * (0.15 + 0.85 * 4.0 * Y * (1.0 - Y)) * n;
  }
  frag = vec4(clamp(o, 0.0, 1.0), 1.0);
}`;

const GRAIN_MIX = { coarse: [0.75, 4, 1.05], medium: [0.85, 2.8, 0.8], fine: [1, 2, 0.45] };

// ---- The same formulas as AutoEdit.swift (toneCurvePoints, pp3Sections) for fields a slider is moving ----
export function toneCurvePoints(contrast, blacks, highlights, shadows) {
  const hiLift = Math.max(0, -highlights) / 100, shDeep = Math.max(0, -shadows) / 100;
  if (contrast === 0 && blacks === 0 && hiLift === 0 && shDeep === 0) return null;
  const k = contrast / 100, bp = Math.max(0, -blacks) / 50 * 0.07, lift = Math.max(0, blacks) / 50 * 0.14;
  const s = x => {
    const amp = x < 0.5 ? 0.07 : 0.10;
    let y = x - k * amp * Math.sin(2 * Math.PI * x);
    if (hiLift > 0 && x > 0.5) { const t = Math.sin(Math.PI * (x - 0.5) / 0.5); y += hiLift * 0.06 * t * t; }
    if (shDeep > 0 && x < 0.5) { const t = Math.sin(Math.PI * x / 0.5); y -= shDeep * 0.07 * t * t; }
    return y;
  };
  let xs = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1];
  if (bp > 0) xs = [...xs.filter(x => x === 0 || x > bp + 0.02), bp].sort((a, b) => a - b);
  // pp3 writes 4 decimals
  return xs.map(x => { const xi = bp > 0 ? Math.max(0, (x - bp) / (1 - bp)) : x; return [+x.toFixed(4), +(lift + (1 - lift) * Math.min(1, Math.max(0, s(xi)))).toFixed(4)]; });
}
// Natural cubic spline sampled at n+1 steps (StudioPipeline.splineLUT).
export function splineLUT(pts, n = 255) {
  const out = new Float32Array(n + 1);
  if (!pts || pts.length < 2) { for (let i = 0; i <= n; i++) out[i] = i / n; return out; }
  const N = pts.length, x = pts.map(p => p[0]), y = pts.map(p => p[1]);
  const y2 = new Array(N).fill(0), u = new Array(N).fill(0);
  for (let i = 1; i < N - 1; i++) {
    const sig = (x[i] - x[i - 1]) / (x[i + 1] - x[i - 1]), p = sig * y2[i - 1] + 2;
    y2[i] = (sig - 1) / p;
    u[i] = (6 * ((y[i + 1] - y[i]) / (x[i + 1] - x[i]) - (y[i] - y[i - 1]) / (x[i] - x[i - 1])) / (x[i + 1] - x[i - 1]) - sig * u[i - 1]) / p;
  }
  for (let k = N - 2; k >= 0; k--) y2[k] = y2[k] * y2[k + 1] + u[k];
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    let lo = 0, hi = N - 1;
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (x[m] > t) hi = m; else lo = m; }
    const h = x[hi] - x[lo];
    if (!(h > 0)) { out[i] = Math.min(1, Math.max(0, y[lo])); continue; }
    const a = (x[hi] - t) / h, b = (t - x[lo]) / h;
    const v = a * y[lo] + b * y[hi] + ((a * a * a - a) * y2[lo] + (b * b * b - b) * y2[hi]) * h * h / 6;
    out[i] = Math.min(1, Math.max(0, v));
  }
  return out;
}

// The pipeline for params `p`, starting from the server's pipeline `base` (for `baseParams`): every
// field whose inputs are unchanged is the server's value as-is; the others use pp3Sections' formulas.
const same = (p, q, keys) => keys.every(k => (p[k] ?? 0) === (q[k] ?? 0));
export function pipelineFor(p, base, baseParams, filmUrl) {
  if (!base) return null;
  const q = baseParams || {};
  const out = { ...base };
  const scale = base.scale || 1;
  if (!same(p, q, ['exposure', 'saturation', 'highlights'])) {
    out.exposure = { ...base.exposure, compensation: p.exposure || 0, saturation: p.saturation || 0, highlightCompression: Math.max(0, Math.round(p.highlights || 0)) };
  }
  if (!same(p, q, ['contrast', 'blacks', 'highlights', 'shadows'])) {
    const pts = toneCurvePoints(p.contrast || 0, p.blacks || 0, p.highlights || 0, p.shadows || 0);
    out.curve = { mode: 'FilmLike', type: pts ? 'spline' : 'linear', points: pts || [], lut: null };
  }
  if (!same(p, q, ['shadows'])) {
    out.shadowsHighlights = p.shadows > 0 ? { shadows: Math.round(p.shadows), highlights: 0, shadowTonalWidth: 30, highlightTonalWidth: 70, radius: Math.round(Math.max(5, 40 * scale)) } : null;
  }
  if (!same(p, q, ['punch'])) {
    out.punch = p.punch > 0 ? { radius: Math.round(Math.max(20, 80 * scale)), amount: +(p.punch / 100 * 0.6).toFixed(3), darkness: 1, lightness: 1 } : null;
  }
  if (!same(p, q, ['vibrance'])) {
    out.vibrance = p.vibrance ? { pastels: Math.round(p.vibrance), saturated: Math.round(p.vibrance / 2), protectSkins: true, avoidColorShift: true, linked: true } : null;
  }
  if (!same(p, q, ['warmth', 'tint'])) out.lab = { ...base.lab, a: (p.tint || 0) * 0.3, b: (p.warmth || 0) * 0.3 };
  if (!same(p, q, ['shadowWarmth', 'shadowTint', 'highlightWarmth', 'highlightTint'])) {
    const on = p.shadowWarmth || p.shadowTint || p.highlightWarmth || p.highlightTint;
    out.balance = on ? { shadow: { a: (p.shadowTint || 0) * 0.3, b: (p.shadowWarmth || 0) * 0.3 }, highlight: { a: (p.highlightTint || 0) * 0.3, b: (p.highlightWarmth || 0) * 0.3 } } : null;
  }
  if ((p.film || '') !== (q.film || '') || (p.filmStrength ?? 0) !== (q.filmStrength ?? 0)) {
    out.film = p.film && p.filmStrength > 0 ? { path: p.film, url: filmUrl ? filmUrl(p.film) : null, strength: p.filmStrength, strengthFraction: p.filmStrength / 100 } : null;
  }
  if (!same(p, q, ['vignette'])) out.vignette = p.vignette > 0 ? { strength: +(p.vignette / 100 * 1.2).toFixed(2), feather: 60, roundness: 50 } : null;
  if (!same(p, q, ['grain']) || (p.grainSize || 'fine') !== (q.grainSize || 'fine')) {
    const g = base.grain, m = GRAIN_MIX[p.grainSize] || GRAIN_MIX.fine;
    out.grain = p.grain > 0 ? { ...(g || {}), amount: p.grain, size: p.grainSize || 'fine', sd: p.grain / 100 * 0.075, fineWeight: m[0], clumpCells: m[1], clumpWeight: m[2], cellsAcrossLongEdge: (g && g.cellsAcrossLongEdge) || 3000, seed: g?.seed ?? null } : null;
  }
  if (!same(p, q, ['rotate'])) {
    const G = base.geometry || {}, t = Math.abs(p.rotate || 0) * Math.PI / 180;
    const W = G.width || 3, H = G.height || 2;
    out.geometry = { ...G, rotate: p.rotate || 0, autofillScale: t ? Math.cos(t) + Math.max(W, H) / Math.min(W, H) * Math.sin(t) : 1 };
  }
  return out;
}

// Calibrated against server renders (see the measurement in the report).
export const TUNE = { gain: 0.985, hlc: 1, shadow: 140, vig: 1.4, vigMode: 1, filmLin: 1, shWidth: 60, shMode: 1, sat: 1.3, vib: 1, punch: 1, punchR: 1.5, ab: 1 };


export function createGPU(canvas) {
  const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, alpha: true, antialias: false, preserveDrawingBuffer: true });
  if (!gl) return null;
  const sh = (type, src) => {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  let prog;
  try {
    prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
  } catch (err) { console.warn('GPU preview unavailable:', err.message); return null; }
  gl.useProgram(prog);
  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'aPos');
  gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const U = {};
  for (const n of ['uSrc', 'uBlur', 'uCurve', 'uLut', 'uBox', 'uCanvas', 'uRegion', 'uAspect', 'uRot', 'uFill', 'uExpo', 'uHlc', 'uSat', 'uChroma', 'uFilm', 'uLutN', 'uVib', 'uAB', 'uBalS', 'uBalH', 'uPunch', 'uShadows', 'uLodPunch', 'uLodShadow', 'uVig', 'uGrain', 'uGrainMix', 'uGrainCells', 'uSeed', 'uTune', 'uTune2']) U[n] = gl.getUniformLocation(prog, n);
  gl.uniform1i(U.uSrc, 0); gl.uniform1i(U.uCurve, 1); gl.uniform1i(U.uLut, 2); gl.uniform1i(U.uBlur, 4);

  const srcTex = gl.createTexture(), blurTex = gl.createTexture(), curveTex = gl.createTexture(), lutTex = gl.createTexture();
  gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, curveTex);
  for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
  gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_3D, lutTex);
  for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_3D, k, v);
  gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGBA8, 2, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(32));

  const state = { src: null, srcW: 0, srcH: 0, lut: null, lutN: 2, curve: null };
  const luts = new Map();   // url -> Promise<{data, n}>

  async function loadImage(url) {
    const img = new Image(); img.decoding = 'async'; img.crossOrigin = 'anonymous'; img.src = url;
    await img.decode();
    return img;
  }
  // Source: the unedited proxy.
  async function setSource(url) {
    if (state.src === url) return true;
    const img = await loadImage(url);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, srcTex);
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE, img);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.activeTexture(gl.TEXTURE4); gl.bindTexture(gl.TEXTURE_2D, blurTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, img);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    state.src = url; state.srcW = img.naturalWidth; state.srcH = img.naturalHeight;
    return true;
  }
  // Film: a Hald CLUT PNG (level L: L³ × L³ pixels, a cube of L² per side). Pixel order = r, then g, then b.
  function loadLut(url) {
    if (!luts.has(url)) luts.set(url, (async () => {
      const img = await loadImage(url);
      const c = document.createElement('canvas'); c.width = img.naturalWidth; c.height = img.naturalHeight;
      const x = c.getContext('2d', { willReadFrequently: true }); x.drawImage(img, 0, 0);
      const data = x.getImageData(0, 0, c.width, c.height).data;
      const n = Math.round(Math.cbrt(c.width * c.height));
      return { data: new Uint8Array(data.buffer), n };
    })().catch(err => { luts.delete(url); throw err; }));
    return luts.get(url);
  }
  async function setFilm(url) {
    if (!url) { state.lut = null; return true; }
    if (state.lut === url) return true;
    const { data, n } = await loadLut(url);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_3D, lutTex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGBA8, n, n, n, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
    state.lut = url; state.lutN = n;
    return true;
  }
  // The pipeline's curve: its 256-step LUT as-is, or the spline through its points (while a slider moves).
  function setCurve(c) {
    if (state.curve === c) return;
    state.curve = c;
    const lut = c?.lut?.length ? Float32Array.from(c.lut) : splineLUT(c?.points?.length ? c.points : null);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, curveTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.R16F, lut.length, 1, 0, gl.RED, gl.FLOAT, lut);
  }

  // pl: a pipeline (server's, or pipelineFor() while editing). view: {box, region, aspect}.
  function render(pl, view, opts = {}) {
    const W = opts.width || canvas.width, H = opts.height || canvas.height;
    const T = { ...TUNE, ...(globalThis.__gpuTune || {}) };
    gl.viewport(0, 0, W, H);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, srcTex);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, curveTex);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_3D, lutTex);
    gl.activeTexture(gl.TEXTURE4); gl.bindTexture(gl.TEXTURE_2D, blurTex);
    setCurve(pl.curve);
    const G = pl.geometry || {};
    const A = state.srcW / state.srcH || view.aspect;
    const r = view.region;
    const ex = pl.exposure || {}, sh = pl.shadowsHighlights, pu = pl.punch, vb = pl.vibrance, lab = pl.lab || {}, vg = pl.vignette, gr = pl.grain;
    const lod = px => Math.max(0, Math.log2(Math.max(1, px) * state.srcW / (G.proxyW || state.srcW)));   // radius in proxy px -> mip level of this texture
    gl.uniform4f(U.uBox, view.box.x, view.box.y, view.box.w, view.box.h);
    gl.uniform2f(U.uCanvas, W, H);
    gl.uniform4f(U.uRegion, r.x, r.y, r.w, r.h);
    gl.uniform1f(U.uAspect, A);
    gl.uniform1f(U.uRot, (G.rotate || 0) * Math.PI / 180);
    gl.uniform1f(U.uFill, G.autofillScale || 1);
    gl.uniform1f(U.uExpo, Math.pow(2, ex.compensation || 0));
    gl.uniform1f(U.uHlc, (Math.max(0, ex.compensation || 0) + 1) * (ex.highlightCompression || 0) / 100);
    gl.uniform1f(U.uSat, 1 + (ex.saturation || 0) / 100 * T.sat);
    gl.uniform1f(U.uChroma, (pl.labChromaticity || 0) / 100);
    gl.uniform1f(U.uFilm, pl.film && state.lut ? (pl.film.strengthFraction ?? (pl.film.strength || 0) / 100) : 0);
    gl.uniform1f(U.uLutN, state.lutN);
    gl.uniform2f(U.uVib, vb ? vb.pastels / 100 * T.vib : 0, vb ? vb.saturated / 100 * T.vib : 0);
    gl.uniform2f(U.uAB, (lab.a || 0) * T.ab, (lab.b || 0) * T.ab);
    const bal = pl.balance;
    gl.uniform2f(U.uBalS, bal ? bal.shadow.a : 0, bal ? bal.shadow.b : 0);
    gl.uniform2f(U.uBalH, bal ? bal.highlight.a : 0, bal ? bal.highlight.b : 0);
    gl.uniform1f(U.uPunch, pu ? pu.amount * T.punch : 0);
    gl.uniform1f(U.uShadows, sh ? sh.shadows / 100 : 0);
    gl.uniform1f(U.uLodPunch, pu ? lod(pu.radius * T.punchR) : 0);
    gl.uniform1f(U.uLodShadow, sh ? lod(sh.radius) : 0);
    gl.uniform1f(U.uVig, vg ? vg.strength : 0);
    gl.uniform1f(U.uGrain, gr ? gr.sd ?? gr.amount / 100 * 0.075 : 0);
    gl.uniform3f(U.uGrainMix, gr?.fineWeight ?? 1, gr?.clumpCells ?? 2, gr?.clumpWeight ?? 0.45);
    gl.uniform1f(U.uGrainCells, gr?.cellsAcrossLongEdge || 3000);
    gl.uniform1f(U.uSeed, gr?.seed ? parseInt(String(gr.seed).slice(-4), 16) || 0 : 0);
    gl.uniform4f(U.uTune, T.gain, T.hlc, T.shadow, T.vig);
    gl.uniform4f(U.uTune2, T.shWidth, T.shMode, T.vigMode, T.filmLin);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  return {
    gl, canvas, state, setSource, setFilm, render,
    ready: () => !!state.src,
    // Render the whole (cropped) picture at w x h into a fresh RGBA buffer (for measuring against the server).
    snapshot(pl, view, w, h) {
      const fb = gl.createFramebuffer(), tex = gl.createTexture();
      gl.activeTexture(gl.TEXTURE3);          // never disturb the units the shader reads from
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      render(pl, { ...view, box: { x: 0, y: 0, w, h } }, { width: w, height: h });
      const px = new Uint8Array(w * h * 4);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.deleteFramebuffer(fb); gl.deleteTexture(tex);
      // readPixels returns the bottom row first: flip to top-down.
      const out = new Uint8Array(px.length), row = w * 4;
      for (let y = 0; y < h; y++) out.set(px.subarray((h - 1 - y) * row, (h - y) * row), y * row);
      return out;
    },
  };
}
