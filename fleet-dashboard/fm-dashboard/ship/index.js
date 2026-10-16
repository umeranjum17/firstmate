// The Ship tab: one home's flagship at night, its workers at a deck station per stage, and around it the home tabs,
// the home's lifecycle and crew by model, and a sheet with the fleet's key numbers and what is stuck and why.
// The app mounts it with mount(element, data, detail) and passes each new board to update(data); detail(id) shows a card's detail.
import { render } from '../vendor/preact-htm-3.1.1.js'
import { html, dur, ACTIVE, SNAME, stuck, state, reason, total, hname, mname, age, StageIcon, Av } from '../ui.js'

const open = d => d.cards.filter(c => ACTIVE.includes(c.stage))
const oldest = cs => [...cs].sort((a, b) => (age(b) ?? 0) - (age(a) ?? 0))
const tone = cs => cs.some(c => c.wait === 'blocked') ? 'bad' : cs.some(c => c.wait === 'decision') ? 'warn' : ''

function Spark({ vals, w = 72, h = 14 }) {
  if (!vals?.length) return ''
  const mx = Math.max(...vals, 1), step = w / Math.max(1, vals.length - 1), pts = vals.map((v, i) => [i * step, h - 2 - (v || 0) / mx * (h - 4)])
  const p = pts.map((q, i) => (i ? 'L' : 'M') + q[0].toFixed(1) + ' ' + q[1].toFixed(1)).join(' ')
  return html`<svg width=${w} height=${h} viewBox=${`0 0 ${w} ${h}`} aria-hidden="true"><path d=${`${p} L${w} ${h} L0 ${h}Z`} fill="var(--green)" opacity=".14"/>
    <path d=${p} fill="none" stroke="var(--green)" stroke-width="1.6" stroke-linejoin="round"/><circle cx=${pts.at(-1)[0]} cy=${pts.at(-1)[1]} r="2.4" fill="var(--green)"/></svg>`
}

// Home tabs, then the home's lifecycle stage by stage, its crew by model and what it landed today (the sheet below is the whole fleet).
function Top({ d, home, pick }) {
  const o = open(d), mine = o.filter(c => c.home === home), n = s => mine.filter(c => c.stage === s).length, known = d.homes.find(h => h.id === home)?.known
  const by = {}; for (const c of mine) by[c.model || ''] = (by[c.model || ''] || 0) + 1
  const landed = total(d, d.cards.filter(c => c.stage === 'landed' && c.home === home).length, 'landed', home)
  return html`<div class="sv-hd">
    <div class="sv-homes"><div class="seg" role="tablist">${d.homes.map(h => { const cs = o.filter(c => c.home === h.id), t = tone(cs)
      return html`<button role="tab" aria-pressed=${h.id === home} aria-selected=${h.id === home} onClick=${() => pick(h.id)}>${h.name}<small class="num">${h.known ? cs.length : '?'}</small>${t ? html`<i class=${t}></i>` : ''}</button>` })}</div></div>
    <div class="sv-flow">${ACTIVE.map(s => html`<div class=${known && !n(s) ? 'sv-z' : ''}><span class="sv-c"><${StageIcon} s=${s} size=${13}/><b class="num">${total(d, n(s), s, home)}</b></span><span class="sv-n">${SNAME[s]}</span></div>`)}</div>
    <div class="sv-crew">${Object.entries(by).sort((a, b) => b[1] - a[1]).map(([m, k]) => html`<span class="sv-chip"><${Av} m=${m || null} size=${18}/>${mname(m || null, d)} <b class="num">${total(d, k, 'active', home)}</b></span>`)}
      ${!known ? html`<span class="sv-chip">Crew unknown</span>` : !mine.length ? html`<span class="sv-chip">Nobody on deck</span>` : ''}<span class="sp"></span>
      <span class="sv-chip" aria-label=${`${hname(d, home)} landed ${landed} today`}><${StageIcon} s="landed" size=${16}/><b class="num">${landed}</b> landed today</span></div>
  </div>`
}

function Kpis({ d }) {
  const o = open(d), plan = d.homes.reduce((s, h) => s + (h.plan || 0), 0), stk = o.filter(stuck), known = d.homes.every(h => h.known), a = stk.length && stk.every(c => age(c) != null) ? age(oldest(stk)[0]) : null
  return html`<div class="sv-kpis">
    <div><span class="sv-l">Landed today</span><span class="sv-v num">${d.landed.length ? total(d, d.landed.at(-1), 'landed') : '–'}</span><${Spark} vals=${d.landed}/></div>
    <div><span class="sv-l">In flight</span><span class="sv-v num">${total(d, o.length)}<small>/${plan}</small></span><span class="sv-l">${d.homes.every(h => h.known) ? `${Math.max(0, plan - o.length)} free` : 'unknown'}</span></div>
    <div><span class="sv-l">Cycle p50</span><span class="sv-v num">${d.cycle_p50 == null ? '–' : dur(d.cycle_p50)}</span></div>
    <div><span class="sv-l">Stuck</span><span class=${'sv-v num' + (stk.length ? ' sv-bad' : '')}>${total(d, stk.length)}</span><span class="sv-l">${stk.length ? a == null ? 'oldest unknown' : `${known ? 'oldest' : 'oldest recorded'} ${dur(a)}` : known ? 'none' : 'unknown'}</span></div></div>`
}
// The app's phone rows: model, title, age, then the state word in its colour, the home and the reason; each opens its card.
function Row({ d, c, parked, detail }) {
  const st = state(c), a = age(c)
  return html`<article class="li" role="button" tabindex="0" data-card=${c.id} onClick=${() => detail(c.id)} onKeyDown=${e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); detail(c.id) } }}><${Av} m=${c.model} size=${20}/><div class="tx"><div class="t"><h3>${c.title}</h3>${a != null ? html`<span class="age num">${dur(a)}</span>` : ''}</div>
    <p>${parked ? '' : html`<i style=${{ '--c': st[1] }}></i><b>${st[0]}</b> · `}${hname(d, c.home)} · ${reason(c)}</p></div></article>`
}
// Fleet-wide, and labelled so beside the home's own numbers: the key numbers, what is stuck oldest first, and what the
// captain parked (grey, never counted as stuck).
// Folded, it keeps the oldest stuck row in view (on a short screen only the counts) and leaves the rest of the screen to the ship.
function Sheet({ d, folded, fold, short, detail }) {
  const o = open(d), stk = oldest(o.filter(stuck)), park = oldest(o.filter(c => c.wait === 'parked')), k = short ? 0 : 1
  const keep = folded ? k : Infinity, more = stk.length + park.length > k, known = d.homes.every(h => h.known)
  return html`<section class=${'sv-sheet' + (folded ? ' sv-folded' : '')}>
    <button class="sv-grab" aria-expanded=${!folded} aria-label=${folded ? 'Show all stuck work' : 'Show less'} onClick=${fold}><span>Whole fleet</span><i></i></button>
    <${Kpis} d=${d}/>
    <div class="sv-list">
      <button class="gh" aria-expanded=${!folded} onClick=${fold}>Stuck <span class="n num">${total(d, stk.length)}</span>${park.length || !known ? html`<span class="n">· Parked by captain</span><span class="n num">${total(d, park.length)}</span>` : ''}
        <span class="sp"></span>${more ? html`<span class="n">${folded ? 'Show all' : 'Show less'}</span>` : ''}</button>
      ${stk.length ? stk.slice(0, keep).map(c => html`<${Row} key=${c.id} d=${d} c=${c} detail=${detail}/>`) : html`<p class="sv-calm">${known ? 'Nothing is stuck.' : 'Stuck work unknown.'}</p>`}
      ${!folded && (park.length || !known) ? html`<div class="gh">Parked by captain <span class="n num">${total(d, park.length)}</span></div>${park.map(c => html`<${Row} key=${c.id} d=${d} c=${c} parked detail=${detail}/>`)}${!known ? html`<p class="sv-calm">Parked work unknown.</p>` : ''}` : ''}
    </div></section>`
}
const Still = () => html`<div class="sv-still"><svg width="120" height="80" viewBox="0 0 120 80" aria-hidden="true"><path d="M58 8v52M60 12l26 30H60zM56 18L34 44h22z" fill="currentColor" opacity=".5"/>
  <path d="M14 58h92l-12 14H28z" fill="currentColor"/></svg><p>This browser cannot draw the 3D ship. Everything else here is live.</p></div>`

export function mount(el, d, detail = () => {}) {
  const css = Object.assign(document.createElement('link'), { rel: 'stylesheet', href: new URL('ship.css', import.meta.url).href })
  const box = Object.assign(document.createElement('div'), { className: 'shipv' })
  const canvas = document.createElement('canvas'), tags = Object.assign(document.createElement('div'), { className: 'tags' }), hud = document.createElement('div')
  box.append(canvas, tags, hud); el.append(css, box)
  // folded on a phone so the ship gets the room; open where the screen has space for both
  let data = d, home = d.homes[0]?.id, folded = !matchMedia('(min-width: 760px)').matches, w = null, gone = false
  const short = matchMedia('(max-height: 760px)')
  // The ship sits in whatever the panels leave free: under the top block, beside or above the sheet.
  const fit = () => {
    if (!w) return
    const b = box.getBoundingClientRect(), t = hud.querySelector('.sv-hd').getBoundingClientRect(), s = hud.querySelector('.sv-sheet').getBoundingClientRect()
    const side = s.top - b.top < t.bottom - b.top
    w.fit({ l: 0, r: side ? s.left - b.left : b.width, t: t.bottom - b.top + 6, b: side ? b.height : s.top - b.top - 6 })
  }
  const draw = () => {
    render(html`<${Top} d=${data} home=${home} pick=${go}/>
      <${Sheet} d=${data} folded=${folded} short=${short.matches} detail=${detail} fold=${() => { folded = !folded; draw() }}/>${w === false ? html`<${Still}/>` : ''}`, hud)
    if (w) w.show(data, home)
  }
  // a new home's tab scrolls into view, and its ship sails in
  const go = id => { if (!id || id === home) return; home = id; draw(); hud.querySelector('.sv-homes [aria-selected=true]')?.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' }) }
  // On the sea, a tap on a worker, its tag or a station opens that card, and a sideways swipe sails to the next or previous home.
  let p0 = null
  const at = e => { const b = canvas.getBoundingClientRect(); return w ? w.pick(e.clientX - b.left, e.clientY - b.top) : null }
  canvas.addEventListener('pointerdown', e => { p0 = e })
  canvas.addEventListener('pointercancel', () => { p0 = null })
  canvas.addEventListener('pointerup', e => {
    if (!p0) return
    const dx = e.clientX - p0.clientX, dy = e.clientY - p0.clientY, quick = e.timeStamp - p0.timeStamp < 800; p0 = null
    if (quick && Math.abs(dx) > 48 && Math.abs(dx) > 1.5 * Math.abs(dy)) { const hs = data.homes, i = hs.findIndex(h => h.id === home); go(hs[i + (dx < 0 ? 1 : -1)]?.id) }
    else if (Math.hypot(dx, dy) < 10) { const id = at(e); if (id) detail(id) }
  })
  canvas.addEventListener('pointermove', e => { if (e.pointerType === 'mouse') canvas.style.cursor = at(e) ? 'pointer' : '' })
  draw()
  short.addEventListener('change', draw)
  const ro = new ResizeObserver(fit); ro.observe(box); ro.observe(hud.querySelector('.sv-hd')); ro.observe(hud.querySelector('.sv-sheet'))
  let gl = false
  try { gl = !!document.createElement('canvas').getContext('webgl2') } catch {}
  const still = () => { if (!gone) { w = false; draw() } }
  if (!gl) still()
  else import('./scene.js').then(m => { if (gone) return; w = m.world(canvas, tags); fit(); draw(); w.start() }).catch(still)
  return {
    update(n) { data = n; if (!n.homes.some(h => h.id === home)) home = n.homes[0]?.id; draw() },
    unmount() { gone = true; short.removeEventListener('change', draw); ro.disconnect(); w?.destroy?.(); render(null, hud); box.remove(); css.remove() },
  }
}
