// The Ship view's 3D world in the ship-or-die art direction: a night sea in hard colour bands with the moon's glints,
// rendered at half resolution with crisp pixels and ink outlines. One home's flagship carries its workers at a deck
// station per stage, each worker a chibi in its model's colour, and the lead stands at the wheel.
import * as THREE from './three-0.186.1.min.js'
import { render } from '../vendor/preact-htm-3.1.1.js'
import { html, dur, state, stuck, age, ACTIVE, StageIcon } from '../ui.js'

const P = {
  horizon: '#18233a', cream: '#f3e6c9',
  deep: '#0e1b28', mid: '#1c3546', crest: '#36606f', foam: '#dfe9ea',
  hull: '#6a4527', hull2: '#3a2616', wale: '#b07a40', bottom: '#2a1b12', deck: '#7d5634', rail: '#2b1c12', sail: '#e9dcc0',
  skin: '#f4dcc2', ink: '#06080e', key: '#dfe6f5', hemiSky: '#6f8fae', hemiGround: '#3a2616', lamp: '#e9b44c', crate: '#c08a4a',
  coat: '#4a5d8f', trim: '#e3c47a',
}
// Model and stage colours come from the app's tokens, so the deck and the panels agree.
const tok = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim() || '#8a8f98'
const MODEL = ['opus', 'sol', 'muse', 'qwen']
const modelCol = m => tok(`--m-${MODEL.includes(m) ? m : 'other'}`)
const GLYPH = {
  opus: 'M8 2.5v11M2.5 8h11M4.1 4.1l7.8 7.8M11.9 4.1l-7.8 7.8',
  sol: 'M8 5.6a2.4 2.4 0 1 1 0 4.8a2.4 2.4 0 1 1 0-4.8M8 2v1.3M8 12.7V14M2 8h1.3M12.7 8H14M3.8 3.8l.9.9M11.3 11.3l.9.9M12.2 3.8l-.9.9M4.7 11.3l-.9.9',
  muse: 'M8 2.2C8.4 5.9 10.1 7.6 13.8 8C10.1 8.4 8.4 10.1 8 13.8C7.6 10.1 5.9 8.4 2.2 8C5.9 7.6 7.6 5.9 8 2.2Z',
  qwen: 'M8 2.4l4.8 2.8v5.6L8 13.6l-4.8-2.8V5.2zM8 5.8v4.4',
}

// ---- toon materials and ink outlines
const grad = new THREE.DataTexture(new Uint8Array([150, 215, 255]), 3, 1, THREE.RedFormat)
grad.minFilter = grad.magFilter = THREE.NearestFilter; grad.needsUpdate = true
const mats = new Map()
const toon = (color, o = {}) => new THREE.MeshToonMaterial({ color, gradientMap: grad, ...o })
// Shared plain toon materials: workers come and go with the data, their materials stay.
const tc = (color, glow = 0) => { const k = color + glow; if (!mats.has(k)) mats.set(k, toon(color, { emissive: new THREE.Color(color).multiplyScalar(glow) })); return mats.get(k) }
function ink(w) {
  const k = 'ink' + w
  if (mats.has(k)) return mats.get(k)
  const m = new THREE.MeshBasicMaterial({ color: P.ink, side: THREE.BackSide })
  m.onBeforeCompile = s => { s.vertexShader = s.vertexShader.replace('#include <begin_vertex>', `vec3 transformed = position + normal * ${w.toFixed(4)};`) }
  m.customProgramCacheKey = () => k
  mats.set(k, m); return m
}
function mesh(geo, mat, outline = 0) {
  const m = new THREE.Mesh(geo, mat); m.castShadow = m.receiveShadow = true
  if (outline) { const o = new THREE.Mesh(geo, ink(outline)); o.castShadow = false; m.add(o) }
  return m
}
const canvasTex = (n, draw) => { const c = document.createElement('canvas'); c.width = c.height = n; draw(c.getContext('2d')); const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; return t }
// A soft additive halo for lantern light (the glow a bloom pass would give, for a sprite's cost).
let haloTex = null
function halo(col, size, k = 1.6) {
  haloTex ||= canvasTex(64, g => { const r = g.createRadialGradient(32, 32, 0, 32, 32, 32); r.addColorStop(0, '#fff'); r.addColorStop(0.25, 'rgba(255,255,255,.55)'); r.addColorStop(1, 'rgba(255,255,255,0)'); g.fillStyle = r; g.fillRect(0, 0, 64, 64) })
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color: new THREE.Color(col).multiplyScalar(k), blending: THREE.AdditiveBlending, depthWrite: false, transparent: true }))
  s.scale.setScalar(size); return s
}

// ---- water: one wave function on the GPU and here, so anything afloat rides the same swell
const WAVES = [[0.21, 0.13, 0.9, 0.16], [-0.17, 0.29, 1.3, 0.11], [0.53, -0.41, 2.1, 0.05], [0.9, 0.7, 2.9, 0.025]]
const FLOW = [-1.6, 0.2]  // the sea slides past the flagship under way
function wave(x, z, t) { x -= FLOW[0] * t; z -= FLOW[1] * t; let h = 0; for (const [a, b, s, amp] of WAVES) h += amp * Math.sin(a * x + b * z + s * t); return h }
const tilt = (x, z, t) => [(wave(x + 0.4, z, t) - wave(x - 0.4, z, t)) / 0.8, (wave(x, z + 0.4, t) - wave(x, z - 0.4, t)) / 0.8]
function water(scene, moonAz) {
  const H = WAVES.map(([a, b, s, amp]) => `h += ${amp.toFixed(4)} * sin(${a.toFixed(3)} * p.x + ${b.toFixed(3)} * p.y + ${s.toFixed(3)} * t);`).join('\n')
  const FL = `vec2(${FLOW[0].toFixed(3)}, ${FLOW[1].toFixed(3)})`
  const u = { t: { value: 0 }, deep: { value: new THREE.Color(P.deep) }, mid: { value: new THREE.Color(P.mid) }, crest: { value: new THREE.Color(P.crest) }, foam: { value: new THREE.Color(P.foam) },
    hor: { value: new THREE.Color(P.horizon) }, moon: { value: new THREE.Color(P.cream) }, md: { value: new THREE.Vector3(Math.cos(moonAz), 0.12, Math.sin(moonAz)).normalize() } }
  const m = new THREE.ShaderMaterial({
    uniforms: u, fog: false,
    vertexShader: `uniform float t; varying vec3 wp; varying vec3 n; varying float hh;
      float H(vec2 p){ p -= ${FL} * t; float h = 0.0; ${H} return h; }
      void main(){ vec4 w = modelMatrix * vec4(position, 1.0); float h = H(w.xz); w.y += h; hh = h;
        n = normalize(vec3(H(w.xz - vec2(0.3, 0.0)) - H(w.xz + vec2(0.3, 0.0)), 0.6, H(w.xz - vec2(0.0, 0.3)) - H(w.xz + vec2(0.0, 0.3))));
        wp = w.xyz; gl_Position = projectionMatrix * viewMatrix * w; }`,
    fragmentShader: `uniform float t; uniform vec3 deep, mid, crest, foam, hor, moon, md; varying vec3 wp; varying vec3 n; varying float hh;
      float hash(vec2 p){ return fract(sin(dot(p, vec2(12.99, 78.23))) * 43758.55); }
      float noise(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f); return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y); }
      void main(){
        vec2 q = wp.xz - ${FL} * t;
        float k = hh + (noise(q * 0.9 + t * 0.3) - 0.5) * 0.08;
        vec3 c = mix(deep, mid, step(0.02, k)); c = mix(c, crest, step(0.2, k) * step(0.55, noise(q * 1.3 + t * 0.2)));
        float fo = step(0.27, k + (noise(q * 2.2 - t * 0.5) - 0.5) * 0.08); c = mix(c, foam, fo);
        c = mix(c, crest, step(0.9, noise(vec2(q.x * 0.5 + t * 0.2, q.y * 2.4))) * step(0.08, k) * (1.0 - fo));
        vec3 v = normalize(cameraPosition - wp), r = reflect(-v, normalize(n));
        c = mix(c, moon, step(0.992, dot(r, md)) * step(0.5, noise(q * 1.6 + vec2(0.0, t * 0.6))) * 0.8);
        c = mix(c, hor, floor(smoothstep(48.0, 240.0, length(wp - cameraPosition)) * 4.0) / 4.0);
        gl_FragColor = vec4(c, 1.0);
        #include <colorspace_fragment>
      }`,
  })
  const g = new THREE.PlaneGeometry(520, 520, 160, 160); g.rotateX(-Math.PI / 2)
  scene.add(new THREE.Mesh(g, m))
  return u
}
// Foam where the hull meets the sea, wider at the bow, with a wake opening behind the stern.
function foamRing(len, beam, wake) {
  const pos = [], e = [], s = [], idx = [], n = 64, pts = []
  for (let i = 0; i < n; i++) { const a = i / n * Math.PI * 2, x = Math.cos(a) * len / 2; pts.push([x, Math.sin(a) * beam / 2 * (x > 0 ? Math.pow(1 - x / (len / 2), 0.55) : 1)]) }
  for (let i = 0; i < n; i++) {
    const [x, z] = pts[i], [x1, z1] = pts[(i + 1) % n], [x0, z0] = pts[(i + n - 1) % n]
    let nx = z1 - z0, nz = x0 - x1; const l = Math.hypot(nx, nz) || 1; nx /= l; nz /= l
    if (nx * x + nz * z < 0) { nx = -nx; nz = -nz }
    const grow = 0.7 + 1.4 * Math.max(0, x / (len / 2)) ** 3
    pos.push(x, 0, z, x + nx * grow, 0, z + nz * grow); e.push(0, 1); s.push(i / n * len * 2, i / n * len * 2)
    const j = (i + 1) % n; idx.push(i * 2, j * 2, i * 2 + 1, j * 2, j * 2 + 1, i * 2 + 1)
  }
  for (const side of [-1, 1]) {
    const b = pos.length / 3
    for (let k = 0; k <= 24; k++) {
      const f = k / 24, x = -len / 2 + 0.6 - f * wake, c = side * (beam * 0.32 + f * wake * 0.32), w = 0.35 + f * 1.6
      pos.push(x, 0, c - w / 2, x, 0, c + w / 2); e.push(0.15 + f * 0.85, 0.15 + f * 0.85); s.push(f * 14, f * 14 + 1.7)
    }
    for (let k = 0; k < 24; k++) { const a = b + k * 2; idx.push(a, a + 2, a + 1, a + 2, a + 3, a + 1) }
  }
  const g = new THREE.BufferGeometry()
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); g.setAttribute('e', new THREE.Float32BufferAttribute(e, 1)); g.setAttribute('s', new THREE.Float32BufferAttribute(s, 1)); g.setIndex(idx)
  const m = new THREE.ShaderMaterial({
    uniforms: { t: { value: 0 }, foam: { value: new THREE.Color(P.foam) } }, transparent: true, depthWrite: false, fog: false,
    vertexShader: 'attribute float e; attribute float s; varying float ve; varying float vs; void main(){ ve = e; vs = s; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }',
    fragmentShader: `uniform float t; uniform vec3 foam; varying float ve; varying float vs;
      void main(){ float k = 0.5 + 0.5 * sin(vs * 2.3 - t * 2.2) * sin(vs * 0.7 + t * 0.9);
        gl_FragColor = vec4(foam, smoothstep(1.0, 0.0, ve) * (0.35 + 0.65 * step(0.45 - 0.35 * (1.0 - ve), k)) * 0.85);
        #include <colorspace_fragment>
      }`,
  })
  const mm = new THREE.Mesh(g, m); mm.renderOrder = 2
  return mm
}

// ---- a ship: lofted hull with sheer, plank deck, rail, masts with billowing sails, rigging and lanterns
const planks = deck => {
  const t = canvasTex(256, g => {
    g.fillStyle = '#fff'; g.fillRect(0, 0, 256, 256)
    for (let i = 0; i < 16; i++) { g.fillStyle = `rgba(60,35,20,${deck ? 0.18 : 0.22})`; g.fillRect(0, i * 16, 256, 1.5); g.fillStyle = `rgba(255,240,220,${0.05 + (i % 3) * 0.03})`; g.fillRect(0, i * 16 + 2, 256, 13) }
    for (let i = 0; i < 40; i++) { g.fillStyle = 'rgba(60,35,20,.18)'; g.fillRect((i * 97) % 256, Math.floor(i * 16 / 2.5) % 256, 1.5, 14) }
  })
  t.wrapS = t.wrapT = THREE.RepeatWrapping; if (deck) { t.rotation = Math.PI / 2; t.repeat.set(0.5, 0.5) }
  return t
}
const BRACE = -0.75
function ship({ len, beam, depth = 2.3, draft = 1.1, masts = 2, flag = P.lamp, mark = null }) {
  const grp = new THREE.Group(), N = 40, K = 16
  const half = u => beam / 2 * (u < 0.12 ? 0.8 + 0.2 * u / 0.12 : u < 0.58 ? 1 : Math.pow(Math.max(0, Math.cos(Math.min(1, (u - 0.58) / 0.42) * Math.PI / 2)), 0.75))
  const top = u => depth + 1.1 * Math.pow(Math.abs(u - 0.45) / 0.55, 2.4) + (u > 0.9 ? (u - 0.9) * 3 : 0)
  const pos = [], col = [], uv = [], idx = []
  const cWood = new THREE.Color(P.hull), cWale = new THREE.Color(P.wale), cRail = new THREE.Color(P.rail), cBot = new THREE.Color(P.bottom)
  for (let i = 0; i <= N; i++) {
    const u = i / N, x = -len / 2 + u * len, w = half(u), tp = top(u)
    for (let k = 0; k <= 2 * K; k++) {
      const a = Math.abs(k - K) / K, side = k < K ? -1 : 1
      const y = -draft + (tp + draft) * Math.pow(a, 0.85), z = side * w * Math.sqrt(Math.max(0, 1 - Math.pow(1 - a, 2.6)))
      pos.push(x, y, z); uv.push(u * len / 2, y)
      const c = y > tp - 0.18 ? cRail : y > tp - 0.8 && y < tp - 0.42 ? cWale : y < 0.15 ? cBot : cWood
      col.push(c.r, c.g, c.b)
    }
  }
  for (let i = 0; i < N; i++) for (let k = 0; k < 2 * K; k++) { const a = i * (2 * K + 1) + k, b = a + 2 * K + 1; idx.push(a, b, a + 1, b, b + 1, a + 1) }
  const hg = new THREE.BufferGeometry()
  hg.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3)); hg.setAttribute('color', new THREE.Float32BufferAttribute(col, 3)); hg.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); hg.setIndex(idx); hg.computeVertexNormals()
  grp.add(mesh(hg, toon(0xffffff, { vertexColors: true, side: THREE.DoubleSide, map: planks() }), 0.05))
  const deckY = depth - 0.05, s = new THREE.Shape()
  for (let i = 0; i <= N; i++) { const u = i / N; (i ? s.lineTo : s.moveTo).call(s, -len / 2 + u * len, half(u) * 0.96) }
  for (let i = N; i >= 0; i--) { const u = i / N; s.lineTo(-len / 2 + u * len, -half(u) * 0.96) }
  const dg = new THREE.ShapeGeometry(s); dg.rotateX(Math.PI / 2); dg.translate(0, deckY, 0)
  const deck = mesh(dg, toon(P.deck, { map: planks(true), side: THREE.DoubleSide })); deck.castShadow = false; grp.add(deck)
  for (const side of [-1, 1]) {
    const pts = []; for (let i = 0; i <= N; i++) { const u = i / N; pts.push(new THREE.Vector3(-len / 2 + u * len, top(u) + 0.04, side * half(u))) }
    grp.add(mesh(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 60, 0.09, 6), tc(P.rail), 0.03))
  }
  const sails = [], mastX = masts === 1 ? [len * 0.08] : [-len * 0.18, len * 0.13], mastH = depth + 7.5
  for (const [i, mx] of mastX.entries()) {
    const h = mastH - i * 0.8, mast = mesh(new THREE.CylinderGeometry(0.13, 0.2, h, 10), tc(P.rail), 0.03); mast.position.set(mx, deckY + h / 2, 0); grp.add(mast)
    // the yards are braced round so the sails show their face to a viewer abeam
    for (const [k, sy] of [[0, 0.55], [1, 0.84]]) {
      const sw = (k ? 3.2 : 4.6) * (beam / 5), sh = k ? 2.0 : 2.7, yy = deckY + h * sy
      const yard = mesh(new THREE.CylinderGeometry(0.07, 0.07, sw + 0.6, 6), tc(P.rail)); yard.rotation.set(Math.PI / 2, BRACE, 0, 'YXZ'); yard.position.set(mx, yy + sh / 2 + 0.1, 0); grp.add(yard)
      const sg = new THREE.PlaneGeometry(sw, sh, 10, 8); sg.rotateY(Math.PI / 2)
      const own = k === 0 && mark
      const sm = mesh(sg, toon(own ? '#ffffff' : P.sail, { side: THREE.DoubleSide, map: own ? mark : null, emissive: new THREE.Color(P.sail).multiplyScalar(0.22) })); sm.rotation.y = BRACE; sm.position.set(mx + 0.25 * Math.cos(BRACE), yy, -0.25 * Math.sin(BRACE)); grp.add(sm)
      sails.push({ m: sm, base: sg.attributes.position.array.slice(), w: sw, h: sh })
    }
    const fl = mesh(new THREE.PlaneGeometry(1.4, 0.7, 8, 1), toon(flag, { side: THREE.DoubleSide })); fl.castShadow = false; fl.geometry.translate(0.7, 0, 0); fl.position.set(mx, deckY + h + 0.2, 0); grp.add(fl)
    sails.push({ m: fl, base: fl.geometry.attributes.position.array.slice(), flag: true })
  }
  const bs = mesh(new THREE.CylinderGeometry(0.06, 0.12, 3.2, 6), tc(P.rail)); bs.rotation.z = -1.25; bs.position.set(len / 2 + 0.9, top(1) - 0.3, 0); grp.add(bs)
  const mtop = i => new THREE.Vector3(mastX[i], deckY + mastH - i * 0.8, 0), rig = [mtop(mastX.length - 1), new THREE.Vector3(len / 2 + 2.3, top(1) + 0.2, 0)]
  for (const [i] of mastX.entries()) for (const side of [-1, 1]) rig.push(mtop(i), new THREE.Vector3(mastX[i] - 1.2, top(0.45) + 0.05, side * beam / 2), mtop(i), new THREE.Vector3(mastX[i] + 1.4, top(0.55) + 0.05, side * beam / 2))
  if (mastX.length > 1) rig.push(mtop(0), mtop(1))
  rig.push(mtop(0), new THREE.Vector3(-len / 2 + 0.3, top(0) + 0.2, 0))
  grp.add(new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(rig), new THREE.LineBasicMaterial({ color: P.ink, transparent: true, opacity: 0.45 })))
  grp.add(lantern(-len / 2 - 0.2, top(0) + 1.0, 0))
  // the outline the camera frames: stern castle, the waterline, the bowsprit tip and the flags
  const hull = [[-len / 2 - 0.4, top(0) + 1.2, half(0)], [-len / 2, 0, half(0)], [0, 0, beam / 2], [len / 2, 0, 0.3], [len / 2 + 2.3, top(1) + 0.2, 0.3]].flatMap(([x, y, z]) => [-1, 1].map(k => new THREE.Vector3(x, y, k * z)))
  const outline = [...hull, ...mastX.map((mx, i) => new THREE.Vector3(mx + 1.4, deckY + mastH - i * 0.8 + 0.6, 0))]
  grp.userData = { len, beam, deckY, top, half, sails, outline }
  billow(grp, 0)
  return grp
}
function billow(s, t, seed = 0) {
  for (const sl of s.userData.sails) {
    const a = sl.m.geometry.attributes.position, b = sl.base
    for (let i = 0; i < a.count; i++) {
      const x = b[i * 3], y = b[i * 3 + 1], z = b[i * 3 + 2]
      if (sl.flag) { a.array[i * 3 + 2] = z + Math.sin(t * 6 + x / 1.4 * 5 + seed) * 0.18 * x / 1.4; continue }
      a.array[i * 3] = x + (0.55 + 0.08 * Math.sin(t * 1.3 + seed)) * (1 - (z / (sl.w / 2)) ** 2) * (0.4 + 0.6 * (1 - (y / (sl.h / 2)) ** 2))
    }
    a.needsUpdate = true; sl.m.geometry.computeVertexNormals()
  }
}
function lantern(x, y, z) {
  const g = new THREE.Group(); g.position.set(x, y, z)
  g.add(new THREE.Mesh(new THREE.SphereGeometry(0.16, 10, 8), new THREE.MeshBasicMaterial({ color: new THREE.Color(P.lamp).multiplyScalar(2.2) })), halo(P.lamp, 2.4, 0.9))
  const cap = new THREE.Mesh(new THREE.ConeGeometry(0.2, 0.18, 6), tc(P.rail)); cap.position.y = 0.2; g.add(cap)
  return g
}
// The home's emblem on the main sails: its initial on a patch in the home's colour, 64 px so nearest sampling stays crisp.
function emblem() {
  const c = document.createElement('canvas'); c.width = c.height = 64
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.magFilter = t.minFilter = THREE.NearestFilter; t.generateMipmaps = false
  t.draw = (letter, col) => {
    const g = c.getContext('2d'); g.fillStyle = P.sail; g.fillRect(0, 0, 64, 64)
    g.fillStyle = 'rgba(80,55,30,.22)'; for (let i = 1; i < 4; i++) g.fillRect(i * 16, 0, 2, 64)
    g.fillStyle = col; g.beginPath(); g.arc(32, 32, 19, 0, 7); g.fill()
    g.fillStyle = '#fff'; g.font = '800 26px Inter, system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillText(letter, 32, 33)
    t.needsUpdate = true
  }
  return t
}

// ---- crew: chibi figures; a worker wears its model's colour head to toe with the model's mark on its chest,
// the lead wears a navy coat and a tricorn at the wheel (Main a bicorne), since the data names no model for a lead.
const G = {}
function geos() {
  if (G.body) return G
  G.body = new THREE.CapsuleGeometry(0.3, 0.34, 6, 14); G.body.translate(0, 0.47, 0)
  G.head = new THREE.SphereGeometry(0.36, 20, 14); G.head.translate(0, 1.2, 0)
  G.arm = new THREE.CapsuleGeometry(0.085, 0.3, 4, 8); G.arm.translate(0, -0.2, 0)
  G.leg = new THREE.CapsuleGeometry(0.1, 0.16, 4, 8); G.leg.translate(0, -0.12, 0)
  G.eye = new THREE.SphereGeometry(0.062, 8, 6)
  G.band = new THREE.CylinderGeometry(0.37, 0.37, 0.14, 20, 1, true); G.band.translate(0, 1.32, 0)
  G.cap = new THREE.SphereGeometry(0.38, 20, 10, 0, Math.PI * 2, 0, Math.PI / 2.1); G.cap.translate(0, 1.27, 0)
  G.brim = new THREE.CylinderGeometry(0.22, 0.22, 0.04, 16, 1, false, -Math.PI / 2, Math.PI); G.brim.translate(0, 1.32, 0.3)
  G.tricorn = new THREE.CylinderGeometry(0.62, 0.62, 0.1, 3); G.tricorn.rotateY(Math.PI); G.tricorn.translate(0, 1.5, 0)
  G.crown = new THREE.CylinderGeometry(0.3, 0.36, 0.3, 14); G.crown.translate(0, 1.6, 0)
  G.bicorne = new THREE.CylinderGeometry(0.75, 0.75, 0.22, 20, 1, false, 0, Math.PI); G.bicorne.rotateZ(Math.PI / 2); G.bicorne.rotateY(Math.PI / 2); G.bicorne.translate(0, 1.5, 0)
  G.sun = new THREE.CylinderGeometry(0.64, 0.64, 0.05, 24); G.sun.translate(0, 1.36, 0)
  G.cone = new THREE.ConeGeometry(0.4, 0.8, 16); G.cone.translate(0, 1.72, 0)
  G.pom = new THREE.SphereGeometry(0.13, 10, 8); G.pom.translate(0, 1.68, 0)
  G.badge = new THREE.CircleGeometry(0.17, 20)
  G.lap = new THREE.BoxGeometry(0.5, 0.035, 0.34); G.lid = new THREE.BoxGeometry(0.5, 0.32, 0.025); G.lid.translate(0, 0.16, 0)
  G.crate = new THREE.BoxGeometry(0.62, 0.5, 0.5); G.crate.translate(0, 0.25, 0)
  return G
}
const badges = new Map()
function badge(m) {
  if (!badges.has(m)) badges.set(m, new THREE.MeshBasicMaterial({ map: canvasTex(64, g => {
    g.fillStyle = modelCol(m); g.beginPath(); g.arc(32, 32, 30, 0, 7); g.fill(); g.lineWidth = 3; g.strokeStyle = '#fff'; g.stroke()
    g.translate(9, 9); g.scale(46 / 16, 46 / 16); g.lineWidth = 1.8; g.lineCap = g.lineJoin = 'round'; g.strokeStyle = g.fillStyle = '#fff'
    if (GLYPH[m]) { const p = new Path2D(GLYPH[m]); m === 'muse' ? g.fill(p) : g.stroke(p) } else { g.font = '700 9px Inter, sans-serif'; g.textAlign = 'center'; g.fillText((m || '?')[0].toUpperCase(), 8, 11) }
  }) }))
  return badges.get(m)
}
// Each model also has its own hat, so two models never look alike even at phone size or without colour.
function hat(m, o, d) {
  const g = geos(), cap = mesh(g.cap, o)
  if (m === 'sol') return [cap, mesh(g.sun, o, 0.02)]
  if (m === 'muse') return [mesh(g.cone, o, 0.03), mesh(g.band, d)]
  if (m === 'qwen') return [cap, mesh(g.band, d), mesh(g.pom, d)]
  return [cap, mesh(g.band, d), mesh(g.brim, o)]
}
function crew(m, role = 'crew') {
  const g = geos(), c = role === 'crew' ? modelCol(m) : P.coat, root = new THREE.Group(), body = new THREE.Group(); root.add(body)
  const outfit = tc(c, 0.28), dark = tc('#' + new THREE.Color(c).multiplyScalar(0.55).getHexString()), head = new THREE.Group()
  body.add(mesh(g.body, outfit, 0.03), head)
  head.add(mesh(g.head, tc(P.skin), 0.03))
  for (const sx of [-0.13, 0.13]) { const e = new THREE.Mesh(g.eye, tc(P.ink)); e.position.set(sx, 1.16, 0.33); head.add(e) }
  if (role === 'crew') head.add(...hat(m, outfit, dark))
  else {
    head.add(mesh(g.cap, dark))
    if (role === 'lead') head.add(mesh(g.tricorn, tc('#1e1a2a'), 0.03), mesh(g.crown, tc('#1e1a2a')))
    else { head.add(mesh(g.bicorne, tc('#1e1a2a'), 0.035)); const b = mesh(new THREE.TorusGeometry(0.2, 0.04, 6, 16), tc(P.trim)); b.position.set(0, 1.58, 0.13); head.add(b) }
  }
  if (role === 'crew') { const b = new THREE.Mesh(g.badge, badge(m)); b.position.set(0, 0.62, 0.305); body.add(b) }
  const arms = [-1, 1].map(sx => { const a = mesh(g.arm, outfit, 0.02); a.position.set(sx * 0.36, 0.78, 0); body.add(a); return a })
  const legs = [-1, 1].map(sx => { const l = mesh(g.leg, dark); l.position.set(sx * 0.13, 0.2, 0); body.add(l); return l })
  let lap = null
  if (role === 'crew') {
    lap = new THREE.Group(); lap.position.set(0, 0.42, 0.52); lap.add(mesh(g.lap, tc('#2b2b33')))
    // the lid faces the viewer with the model's mark
    const lid = new THREE.Group(); lid.position.set(0, 0.02, 0.16); lid.rotation.x = 0.25
    const mk = new THREE.Mesh(g.badge, badge(m)); mk.scale.setScalar(0.75); mk.position.set(0, 0.16, 0.014)
    lid.add(mesh(g.lid, dark, 0.02), mk); lap.add(lid); root.add(lap)
  }
  root.userData = { body, head, arms, legs, lap, phase: Math.random() * 10 }
  return root
}
// Poses, each a two- or three-beat loop with its own offset so the crew never moves in sync.
function pose(f, s, t) {
  const u = f.userData, ph = u.phase, [aL, aR] = u.arms, b = u.body, beat = (p, n) => Math.floor(((t + ph) % p) / p * n)
  b.position.y = 0; b.rotation.set(0, 0, 0); u.head.rotation.set(0, 0, 0); aL.rotation.set(0, 0, 0); aR.rotation.set(0, 0, 0)
  if (u.lap) u.lap.visible = s !== 'waiting' && s !== 'parked' && s !== 'finished'
  if (s === 'working' || s === 'validating') {
    const k = beat(0.62, 2); aL.rotation.x = -1.15 + (k ? 0.18 : 0); aR.rotation.x = -1.15 + (k ? 0 : 0.18); u.head.rotation.x = 0.06; b.position.y = k * 0.025
    if (s === 'validating') u.head.rotation.y = Math.sin(t * 0.8 + ph) * 0.25
  } else if (s === 'blocked') {
    aL.rotation.z = 0.5; aR.rotation.z = -0.5; aL.rotation.x = aR.rotation.x = -0.3; u.head.rotation.x = 0.35; b.rotation.x = 0.08
  } else if (s === 'decision') {
    const k = beat(0.9, 2); aR.rotation.z = -2.7 + k * 0.25; aR.rotation.x = -0.2; u.head.rotation.z = 0.12; b.position.y = k * 0.04
  } else if (s === 'waiting') {
    b.position.y = -0.14; u.head.rotation.y = Math.sin(t * 0.5 + ph) * 0.5; aL.rotation.x = aR.rotation.x = -0.4
  } else if (s === 'parked') {  // sat down with the laptop shut until the captain releases it
    b.position.y = -0.22; u.head.rotation.x = 0.3; aL.rotation.x = aR.rotation.x = -0.6
  } else if (s === 'finished') {
    const k = beat(1.2, 2); aR.rotation.z = -2.4; aL.rotation.z = 0.25; b.position.y = k * 0.05
  } else { u.head.rotation.y = Math.sin(t * 0.4 + ph) * 0.4; b.position.y = Math.sin(t * 1.2 + ph) * 0.015 }
}
const poseOf = c => ({ blocked: 'blocked', decision: 'decision', waiting: 'waiting', parked: 'parked' })[c.wait]
  || (c.stage === 'merge' ? 'finished' : c.state === 'validating' ? 'validating' : 'working')

// ---- the world
const LEN = 17, BEAM = 6, YAW = -0.16, SCALE = 1.8
// One deck station per stage, stern to bow.
// The masts stand in the gaps between them and the landed crates wait at the bow.
const SX = { building: -4.3, review: -1.6, test: 0.9, ci: 3.6, merge: 5.9 }
// up to six crates stacked three, two, one
const STACK = [[0, -0.52], [0, 0], [0, 0.52], [1, -0.26], [1, 0.26], [2, 0]]
const PARK = 'Parked by captain', DIR = new THREE.Vector3(0.12, 0.84, 1).normalize()
export function world(canvas, tagLayer) {
  const r = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' })
  r.setPixelRatio(0.5); r.toneMapping = THREE.NoToneMapping
  r.shadowMap.enabled = true; r.shadowMap.type = THREE.PCFShadowMap
  const scene = new THREE.Scene(), cam = new THREE.PerspectiveCamera(34, 1, 0.5, 1200)
  scene.fog = new THREE.Fog(P.horizon, 60, 260)
  const moonAz = -2.2, sun = new THREE.DirectionalLight(P.key, 1.9)
  sun.position.set(-34, 22, 22); sun.castShadow = true; sun.shadow.mapSize.set(1024, 1024); sun.shadow.bias = -0.0006
  Object.assign(sun.shadow.camera, { left: -14, right: 14, top: 14, bottom: -14, near: 1, far: 120 })
  const lamp = new THREE.PointLight(P.lamp, 14, 14, 1.6); lamp.position.set(0.5, 5.2, 2.2)
  scene.add(sun, sun.target, new THREE.HemisphereLight(P.hemiSky, P.hemiGround, 1.25))
  const sea = water(scene, moonAz), foam = foamRing(LEN + 0.4, BEAM + 0.4, 22); foam.rotation.y = YAW; scene.add(foam)
  const mark = emblem(), S = ship({ len: LEN, beam: BEAM, mark }); S.rotation.y = YAW; S.add(lamp); scene.add(S)
  const deckY = S.userData.deckY
  for (const k of ACTIVE) {
    const col = tok(`--st-${k}`), disc = new THREE.Mesh(new THREE.CircleGeometry(1.15, 32), new THREE.MeshBasicMaterial({ color: new THREE.Color(col).multiplyScalar(0.5), transparent: true, opacity: 0.5, depthWrite: false }))
    disc.rotation.x = -Math.PI / 2; disc.position.set(SX[k], deckY + 0.02, 0); S.add(disc)
    const ring = new THREE.Mesh(new THREE.RingGeometry(1.08, 1.18, 40), new THREE.MeshBasicMaterial({ color: new THREE.Color(col).multiplyScalar(1.5) })); ring.rotation.x = -Math.PI / 2; ring.position.set(SX[k], deckY + 0.025, 0); S.add(ring)
  }
  // the helm on the stern castle, with the lead at the wheel
  const cab = mesh(new THREE.BoxGeometry(LEN * 0.17, 1.2, BEAM * 0.78), tc(P.hull2), 0.04); cab.position.set(-LEN / 2 + LEN * 0.1, deckY + 0.6, 0); S.add(cab)
  for (const z of [-0.9, 0, 0.9]) { const w = new THREE.Mesh(new THREE.PlaneGeometry(0.42, 0.42), new THREE.MeshBasicMaterial({ color: new THREE.Color(P.lamp).multiplyScalar(1.4) })); w.rotation.y = -Math.PI / 2; w.position.set(-LEN / 2 + LEN * 0.015 - 0.01, deckY + 0.65, z * BEAM * 0.25); S.add(w) }
  const helm = new THREE.Group(); helm.position.set(-LEN / 2 + 2.4, deckY + 1.2, 0); S.add(helm)
  const wheel = mesh(new THREE.TorusGeometry(0.45, 0.06, 6, 18), tc(P.rail), 0.02); wheel.position.set(0.7, 0.95, 0); wheel.rotation.y = Math.PI / 2; helm.add(wheel)
  const post = mesh(new THREE.CylinderGeometry(0.08, 0.1, 0.95, 6), tc(P.rail)); post.position.set(0.7, 0.47, 0); helm.add(post)
  let lead = null
  // landed work today waits in crates at the bow
  const crates = new THREE.Group(); crates.position.set(7.3, deckY, 0); S.add(crates)
  S.add(lantern(8.2, deckY + 1.5, 0), lantern(-2.8, deckY + 5.6, 0))
  const figs = new Map(), tags = new Map(), V = new THREE.Vector3(), clock = new THREE.Clock()
  let home = null, alive = true, raf = 0, roof = 0, bottom = Infinity, first = true, cw = 1, ch = 1
  const still = matchMedia('(prefers-reduced-motion: reduce)')

  // A label pinned to a point in the scene; it is measured only when its words change.
  function tag(key, cls, rank, words, view = words) {
    let t = tags.get(key)
    if (!t) { t = { el: document.createElement('div') }; tagLayer.append(t.el); tags.set(key, t) }
    if (t.cls !== cls) t.el.className = 'sv-tag ' + (t.cls = cls)
    t.rank = rank; t.on = true
    if (t.words !== words) { t.words = words; render(view, t.el); t.w = t.el.offsetWidth; t.h = t.el.offsetHeight }
    return t
  }
  // Tags keep apart and off the lead: trouble goes first, a tag over a worker steps up out of the way, a station marker only shows where it fits.
  function placeTags() {
    const placed = []
    if (lead) { const p = lead.getWorldPosition(new THREE.Vector3()), [x, y] = toScreen(p); p.y += 4; const [, top] = toScreen(p); placed.push({ l: x - 20, r: x + 20, t: top, b: y }) }
    for (const t of [...tags.values()].filter(t => t.on).sort((a, b) => a.rank - b.rank)) {
      const x = Math.max(6, Math.min(cw - t.w - 6, t.x - t.w / 2)), m = t.below ? 1 : 4; let y = t.below ? t.y : t.y - t.h
      const hit = () => placed.find(p => x < p.r + m && x + t.w > p.l - m && y < p.b + m && y + t.h > p.t - m)
      if (!t.below) for (let k = 0; k < 6; k++) { const h = hit(); if (!h) break; y = h.t - t.h - 4 }
      // a tag that would crowd another or slip under the panels stays hidden; the stage strip and the sheet still name it
      const off = t.below ? !!hit() || y + t.h > bottom : y < roof; t.el.style.visibility = off ? 'hidden' : ''; if (off) continue
      placed.push({ l: x, r: x + t.w, t: y, b: y + t.h }); t.el.style.transform = `translate(${Math.round(x)}px,${Math.round(y)}px)`; t.el.style.zIndex = Math.round(y)
      // a stem from a lifted tag down to its worker; lower tags stack on top, so a stem passes behind them
      if (!t.below) { t.el.style.setProperty('--x', Math.round(t.x - x) + 'px'); t.el.style.setProperty('--s', Math.max(0, Math.round(t.y - y - t.h)) + 'px') }
    }
  }
  const toScreen = p => { V.copy(p).project(cam); return [(V.x + 1) / 2 * cw, (1 - V.y) / 2 * ch] }

  function show(d, id) {
    if (id !== home) {
      home = id; const i = d.homes.findIndex(h => h.id === id), h = d.homes[i]
      const col = tok(`--h-${(i % 8 + 8) % 8 + 1}`); mark.draw((h?.name || id)[0].toUpperCase(), col)
      for (const sl of S.userData.sails) if (sl.flag) sl.m.material.color.set(col)
      if (lead) S.remove(lead)
      lead = crew(null, id === 'main' ? 'main' : 'lead'); lead.scale.setScalar(SCALE * 1.1); lead.rotation.y = Math.PI / 2; helm.add(lead)
    }
    const mine = d.cards.filter(c => c.home === id && ACTIVE.includes(c.stage))
    for (const [k, f] of figs) if (!mine.some(c => c.id === k)) { S.remove(f.f); figs.delete(k) }
    for (const s of ACTIVE) mine.filter(c => c.stage === s).forEach((c, i, all) => {
      let f = figs.get(c.id)
      if (!f || f.m !== c.model) { if (f) S.remove(f.f); f = { f: crew(c.model), m: c.model }; f.f.scale.setScalar(SCALE); S.add(f.f); figs.set(c.id, f) }
      // pairs stand on a diagonal, one a step behind and aside, rows from the near rail inward, so every face shows
      const n = all.length, rows = Math.ceil(n / 2), row = Math.floor(i / 2), pair = n - row * 2 > 1, back = pair && i % 2
      const x = SX[s] + (pair ? (back ? 0.65 : -0.65) : 0), w = S.userData.half((x + LEN / 2) / LEN) * 0.75
      f.f.position.set(x, deckY, Math.max(-w, Math.min(w, (rows - 1) * 0.9 - row * 1.8 + 0.8 - (back ? 1.1 : 0))))
      f.f.rotation.y = 0.15
      f.c = c; f.pose = poseOf(c)
    })
    const landed = d.landed_by_home?.[id]?.at(-1) || 0
    crates.clear()
    for (const [i, [y, z]] of STACK.slice(0, landed).entries()) { const c = mesh(geos().crate, tc(i % 2 ? '#b07a40' : '#c99555'), 0.03); c.position.set(0, y * 0.5, z); crates.add(c) }
    if (still.matches) frame()
  }

  function fit(box) {
    const w = canvas.clientWidth, h = canvas.clientHeight
    if (!w || !h) return
    roof = box.t; bottom = box.b
    // chunky pixels on a big screen, finer on a phone so a worker stays readable
    cw = w; ch = h; r.setPixelRatio(w < 600 ? 1 : 0.5); r.setSize(w, h, false); cam.aspect = w / h; cam.clearViewOffset()
    // frame the ship's outline in the free part of the screen: find the distance at which it just fits, then shift the lens onto the box
    S.updateMatrixWorld(); const pts = S.userData.outline.map(p => S.localToWorld(p.clone())), aim = new THREE.Box3().setFromPoints(pts).getCenter(new THREE.Vector3())
    const pad = 12, bw = box.r - box.l - 2 * pad, bh = box.b - box.t - 2 * pad - 24, ext = () => {
      cam.updateMatrixWorld(); let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9
      for (const p of pts) { const [x, y] = toScreen(p); x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y) }
      return [x0, x1, y0, y1]
    }
    let lo = 5, hi = 400
    for (let k = 0; k < 22; k++) {
      const dd = (lo + hi) / 2; cam.position.copy(aim).addScaledVector(DIR, dd); cam.lookAt(aim); cam.updateProjectionMatrix()
      const [x0, x1, y0, y1] = ext(); x1 - x0 <= bw && y1 - y0 <= bh ? hi = dd : lo = dd
    }
    cam.position.copy(aim).addScaledVector(DIR, hi); cam.lookAt(aim); cam.updateProjectionMatrix()
    const [x0, x1, y0, y1] = ext()
    cam.setViewOffset(w, h, (x0 + x1) / 2 - (box.l + box.r) / 2, (y0 + y1) / 2 - (box.t + box.b - 24) / 2, w, h); cam.updateProjectionMatrix()
    if (still.matches) frame()
  }

  function frame() {
    const t = clock.getElapsedTime()
    sea.t.value = t; foam.material.uniforms.t.value = t
    const h = wave(0, 0, t), [sx, sz] = tilt(0, 0, t)
    S.position.y = h * 0.7 - 0.15; S.rotation.z = -sx * 0.5 + Math.sin(t * 0.7) * 0.012; S.rotation.x = sz * 0.6; foam.position.y = h * 0.7 + 0.02
    billow(S, t)
    if (lead) { pose(lead, 'idle', t); lead.userData.arms.forEach(a => a.rotation.x = -1.3); wheel.rotation.x = Math.sin(t * 0.5) * 0.4 }
    for (const f of figs.values()) pose(f.f, f.pose, t)
    r.render(scene, cam)
    if (first) { first = false; performance.mark('ship-first-frame') }  // the first-paint measure reads this
    for (const g of tags.values()) g.on = false
    for (const [id, f] of figs) {
      if (!stuck(f.c) && f.c.wait !== 'parked') continue
      f.f.getWorldPosition(V); V.y += 3.0; const [x, y] = toScreen(V), a = age(f.c)
      const st = state(f.c)[0], ag = a == null ? '' : dur(a)
      const tg = f.c.wait === 'parked' ? tag(id, 'sv-park', 1, PARK) : tag(id, f.c.wait === 'blocked' ? 'sv-bad' : 'sv-warn', 0, st + ag, html`${st} <b class="num">${ag}</b>`)
      tg.x = x; tg.y = y
    }
    for (const k of ACTIVE) {
      V.set(SX[k], deckY + 0.05, 2.2); S.localToWorld(V); const [x, y] = toScreen(V), tg = tag('st' + k, 'sv-ico', 2, k, html`<${StageIcon} s=${k}/>`)
      tg.x = x; tg.y = y + 16; tg.below = true
    }
    for (const [k, g] of tags) if (!g.on) { g.el.remove(); tags.delete(k) }
    placeTags()
  }
  // 30 frames a second: the motion is stepped by design, and a tab left open all day stays cool
  let last = 0
  function loop(ts = 0) { if (!alive) return; raf = requestAnimationFrame(loop); if (ts - last < 32) return; last = ts; frame() }
  const motion = () => { cancelAnimationFrame(raf); still.matches ? frame() : loop() }
  still.addEventListener('change', motion)
  return {
    show, fit, start: motion,
    destroy() { alive = false; cancelAnimationFrame(raf); still.removeEventListener('change', motion); r.dispose(); tagLayer.textContent = '' },
  }
}
