// Fleet dashboard app shell: live data, routes, the Linear sidebar and header (phone: title, tabs and dock),
// filters, the ask list, the Ship mount, the command palette and keys.
import { render } from './vendor/preact-htm-3.1.1.js'
import { html, useState, useEffect, useRef, now, dur, ACTIVE, STAGES, STATES, stuck, state, sid, total, hc, hname, mname, sorted, filterCards, I, IC, StageIcon, Av } from './ui.js'
import { TABS, inTab, Board, List, Detail } from './board.js'

const POLL_MS = 10000, STALE_S = 15 * 60, WIDE = '(min-width: 760px)'

const root = document.documentElement
let saved = null
try { saved = localStorage.getItem('fm-theme') } catch {}
root.dataset.theme = saved || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')

// board.json, polled with its ETag so an unchanged fleet costs one empty answer. The first pull is a plain
// fetch, so it takes the copy index.html preloads alongside the scripts.
function useBoard() {
  const [st, set] = useState({ data: null, err: null }), [tick, refresh] = useState(0)
  useEffect(() => {
    let tag = null, alive = true
    async function pull() {
      try {
        const r = await fetch('board.json', tag ? { cache: 'no-cache', headers: { 'If-None-Match': tag } } : {})
        if (r.status === 304) return alive && set(s => ({ ...s, err: null }))
        if (!r.ok) throw new Error(`the dashboard server answered ${r.status}`)
        tag = r.headers.get('ETag')
        const data = await r.json()
        if (alive) set({ data, err: null })
      } catch (e) { if (alive) set(s => ({ ...s, err: e.message || String(e) })) }
    }
    pull()
    const t = setInterval(pull, POLL_MS)
    return () => { alive = false; clearInterval(t) }
  }, [tick])
  return [st, () => refresh(x => x + 1)]
}
function useWide() {
  const [w, set] = useState(matchMedia(WIDE).matches)
  useEffect(() => { const m = matchMedia(WIDE), f = () => set(m.matches); m.addEventListener('change', f); return () => m.removeEventListener('change', f) }, [])
  return w
}
function useTick(ms) { const [, set] = useState(0); useEffect(() => { const t = setInterval(() => set(x => x + 1), ms); return () => clearInterval(t) }, []) }

// The view, tab, rows, filters and open card live in the URL hash.
const VIEWS = ['board', 'needs', 'ship']
function parseHash() {
  const [path, q] = location.hash.replace(/^#\/?/, '').split('?')
  const p = new URLSearchParams(q || ''), list = k => (p.get(k) || '').split(',').filter(Boolean)
  return { view: VIEWS.includes(path) ? path : 'board', tab: TABS.some(([t]) => t === p.get('tab')) ? p.get('tab') : 'active',
    rows: p.get('rows') === 'home' ? 'home' : '', home: list('home'), model: list('model'), state: list('state'), card: p.get('card') }
}
function toHash(r) {
  const p = new URLSearchParams()
  if (r.tab !== 'active') p.set('tab', r.tab)
  if (r.rows) p.set('rows', r.rows)
  for (const k of ['home', 'model', 'state']) if (r[k].length) p.set(k, r[k].join(','))
  if (r.card) p.set('card', r.card)
  return `#/${r.view}${p.size ? '?' + p.toString().replace(/%2C/g, ',').replace(/%2F/g, '/') : ''}`
}
function useRoute() {
  const [r, set] = useState(parseHash)
  useEffect(() => { const f = () => set(parseHash()); addEventListener('hashchange', f); return () => removeEventListener('hashchange', f) }, [])
  return [r, patch => set(cur => { const n = { ...cur, ...patch }; history[patch.view && patch.view !== cur.view ? 'pushState' : 'replaceState'](null, '', toHash(n)); return n })]
}

function Live({ d, st, refresh }) {
  useTick(15000)
  const a = now() - d.generated, bad = st.err || a > STALE_S
  return html`<button class=${'live' + (bad ? ' stale' : '')} onClick=${refresh} title=${st.err ? `Cannot refresh: ${st.err}` : 'Refresh now'}><i></i>${st.err ? 'Cannot refresh' : a < 60 ? 'Live' : `Updated ${dur(a)} ago`}</button>`
}

// One popover for the three filters; on a phone it is a bottom sheet.
function Pop({ label, icon, badge, children }) {
  const [open, setOpen] = useState(false), ref = useRef()
  useEffect(() => { if (!open) return; const f = e => e.key === 'Escape' && setOpen(false); addEventListener('keydown', f); return () => removeEventListener('keydown', f) }, [open])
  return html`<div class="anchor" ref=${ref}><button class=${label ? 'btn' : 'ib'} aria-expanded=${open} aria-label=${label ? null : 'Filter'} onClick=${() => setOpen(!open)}>${I(icon, label ? 14 : 18)}${label}${badge ? html`<b>${badge}</b>` : ''}</button>
    ${open && html`<div class="scrim" onClick=${() => setOpen(false)}></div><div class="pop">${children}</div>`}</div>`
}
const Opt = ({ on, icon, name, n, set }) => html`<button class=${'opt' + (n ? '' : ' dim')} aria-pressed=${on} onClick=${set}><span class="ck">${on ? I(IC.check, 11) : ''}</span>${icon || ''}<span class="lt">${name}</span><small class="num">${n}</small></button>`
function Filters({ d, r, go, label }) {
  const open = d.cards.filter(c => c.stage !== 'landed'), tog = (k, id) => go({ [k]: r[k].includes(id) ? r[k].filter(x => x !== id) : [...r[k], id] })
  const models = [...new Set(d.cards.map(c => c.model || 'none'))]
  const on = r.home.length + r.model.length + r.state.length
  return html`<${Pop} label=${label} icon=${IC.filter} badge=${on || ''}>
    <div class="pop-h">Home</div>${d.homes.map(h => html`<${Opt} on=${r.home.includes(h.id)} icon=${html`<span class="sq" style=${{ '--c': hc(d, h.id) }}></span>`} name=${h.name} n=${total(d, open.filter(c => c.home === h.id).length, 'open', h.id)} set=${() => tog('home', h.id)}/>`)}
    <div class="pop-h">Model</div>${models.map(m => html`<${Opt} on=${r.model.includes(m)} icon=${html`<${Av} m=${m === 'none' ? null : m}/>`} name=${mname(m === 'none' ? null : m, d)} n=${total(d, open.filter(c => (c.model || 'none') === m).length, 'open')} set=${() => tog('model', m)}/>`)}
    <div class="pop-h">State</div>${STATES.map(([id, name]) => html`<${Opt} on=${r.state.includes(id)} name=${name} n=${total(d, open.filter(c => sid(c) === id).length, 'open')} set=${() => tog('state', id)}/>`)}</${Pop}>`
}
function Chips({ d, r, go }) {
  const xs = [...r.home.map(v => ['home', v, 'Home', hname(d, v)]), ...r.model.map(v => ['model', v, 'Model', mname(v === 'none' ? null : v, d)]),
    ...r.state.map(v => ['state', v, 'State', STATES.find(s => s[0] === v)?.[1] || v])]
  return xs.length ? html`<div class="chips">${xs.map(([k, v, n, w]) => html`<span class="chip">${n} is <b>${w}</b><button aria-label=${`Remove ${w}`} onClick=${() => go({ [k]: r[k].filter(x => x !== v) })}>${I(IC.x, 12)}</button></span>`)}</div>` : ''
}

// The 3D ship view is its own module: ship/index.js exports mount(element, data) and may return { update(data), unmount() }.
function Ship({ d }) {
  const ref = useRef(), view = useRef(), [missing, setMissing] = useState(false)
  useEffect(() => {
    let gone = false
    import('./ship/index.js').then(m => { if (!gone) view.current = m.mount(ref.current, d) }).catch(() => setMissing(true))
    return () => { gone = true; view.current?.unmount?.() }
  }, [])
  useEffect(() => view.current?.update?.(d), [d])
  return html`<div id="ship-mount" ref=${ref}>${missing ? html`<div class="none">${I(IC.ship, 32)}<p>The 3D ship view mounts here.</p></div>` : ''}</div>`
}
// Needs you is the ask list and nothing else.
const Needs = ({ d }) => d.asks == null ? html`<div class="none"><p>The ask list could not be read.</p></div>`
  : !d.asks.length ? html`<div class="none">${I(IC.inbox, 32)}<p>Nothing needs you.</p></div>`
  : html`<ul class="inbox">${d.asks.map(a => html`<li><span>${a.text}</span><small class="num">${a.age == null ? '' : dur(a.age)}</small>${a.url ? html`<a class="pill" href=${a.url} target="_blank" rel="noreferrer">Open</a>` : ''}</li>`)}</ul>`

function Palette({ d, go, close, toggleTheme }) {
  const [q, setQ] = useState(''), [i, setI] = useState(0), input = useRef()
  useEffect(() => input.current?.focus(), [])  // autofocus is ignored while a card holds focus
  const groups = [
    ['Go to', [['board', 'Board'], ['needs', 'Needs you'], ['ship', 'Ship']].map(([v, n]) => ({ n, k: `G ${n[0]}`, run: () => go({ view: v, card: null }) }))],
    ['Actions', [
      { n: 'Show stuck lanes', run: () => go({ view: 'board', state: ['blocked', 'decision'], card: null }) },
      { n: 'Group rows by home', k: '⇧G', run: () => go({ view: 'board', rows: 'home' }) },
      { n: 'Clear filters', run: () => go({ home: [], model: [], state: [] }) },
      { n: 'Light or dark theme', k: 'T', run: toggleTheme }]],
    ['Homes', d.homes.map(h => ({ n: h.name, k: `${h.known ? h.open : '?'} open`, run: () => go({ view: 'board', home: [h.id], card: null }) }))],
    ['Lanes', [...ACTIVE, 'queued', 'landed'].flatMap(s => sorted(d.cards.filter(c => c.stage === s))).map(c => ({ n: c.title, i: html`<${StageIcon} s=${c.stage}/>`,
      k: state(c)?.[0] || hname(d, c.home), bad: stuck(c), run: () => go({ view: 'board', card: c.id }) }))],
  ]
  const ql = q.toLowerCase()
  const hits = groups.map(([g, xs]) => [g, xs.filter(a => a.n.toLowerCase().includes(ql)).slice(0, g === 'Lanes' ? 30 : 10)]).filter(([, xs]) => xs.length)
  const flat = hits.flatMap(([, xs]) => xs)
  const key = e => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setI(Math.min(i + 1, flat.length - 1)) }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setI(Math.max(i - 1, 0)) }
    else if (e.key === 'Enter' && flat[i]) { flat[i].run(); close() }
  }
  useEffect(() => document.querySelector('.pal [aria-selected=true]')?.scrollIntoView({ block: 'nearest' }), [i])
  let k = -1
  return html`<div class="scrim dim" onClick=${close}></div><div class="pal" role="dialog" aria-label="Search and jump">
    <input ref=${input} placeholder="Search a lane, a home or a command…" value=${q} onInput=${e => { setQ(e.target.value); setI(0) }} onKeyDown=${key}/>
    <ul>${hits.map(([g, xs]) => html`<li class="pop-h">${g}</li>${xs.map(a => { const j = ++k
      return html`<li class="opt" aria-selected=${i === j} onMouseMove=${() => i !== j && setI(j)} onClick=${() => { a.run(); close() }}>${a.i || ''}<span class="lt">${a.n}</span>${a.k ? html`<small class=${a.bad ? 'bad' : ''}>${a.k}</small>` : ''}</li>` })}`)}
      ${!flat.length && html`<li class="pop-h">Nothing matches</li>`}</ul></div>`
}
const KEYS = [['⌘K or /', 'Search and jump'], ['G then B, N, S', 'Board, Needs you, Ship'], ['H J K L or arrows', 'Move between cards'], ['Enter', 'Open the card'],
  ['J K in a card', 'Next and previous lane'], ['Esc', 'Close'], ['⇧G', 'Rows by home on or off'], ['T', 'Light or dark theme'], ['?', 'This list']]
function Shortcuts({ close }) {
  const ref = useRef(); useEffect(() => ref.current?.focus(), [])
  return html`<div class="scrim dim" onClick=${close}></div><div class="pal" role="dialog" aria-label="Keyboard shortcuts" tabindex="-1" ref=${ref}>
  <div class="pop-h" style="padding:14px 16px 8px">Keyboard shortcuts</div><dl class="keys">${KEYS.map(([k, v]) => html`<dt><kbd>${k}</kbd></dt><dd>${v}</dd>`)}</dl></div>`
}
// Board keys move on a grid: up and down inside a column, left and right across columns.
function moveFocus(dx, dy) {
  const cols = [...document.querySelectorAll('.col')].map(p => [...p.querySelectorAll('[data-card]')]).filter(p => p.length)
  const a = document.activeElement
  let ci = cols.findIndex(p => p.includes(a)), ri = ci < 0 ? -1 : cols[ci].indexOf(a)
  if (ci < 0) return cols[0]?.[0]?.focus()
  if (dx) { ci = Math.max(0, Math.min(cols.length - 1, ci + dx)); ri = Math.min(ri, cols[ci].length - 1) } else ri = Math.max(0, Math.min(cols[ci].length - 1, ri + dy))
  cols[ci][ri].focus(); cols[ci][ri].scrollIntoView({ block: 'nearest', inline: 'nearest' })
}
function useKeys(r, go, setPal, setKeys, toggleTheme, pal, keys) {
  const overlay = useRef(); overlay.current = [pal, keys]
  useEffect(() => {
    let g = false
    const f = e => {
      const [pal, keys] = overlay.current
      if (pal || keys) { if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); keys ? setKeys(false) : setPal(false) } return }
      if (e.target.closest?.('input') || e.altKey) return
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); return setPal(true) }
      if (e.metaKey || e.ctrlKey) return
      if (e.key === '/') { e.preventDefault(); return setPal(true) }
      if (e.key === '?') return setKeys(true)
      if (g) { g = false; const v = { b: 'board', n: 'needs', s: 'ship' }[e.key]; if (v) go({ view: v, card: null }); return }
      if (e.key === 'g') { g = true; setTimeout(() => g = false, 900); return }
      if (e.key === 'G') return go({ view: 'board', rows: r.rows ? '' : 'home' })
      if (e.key === 't') return toggleTheme()
      if (r.view !== 'board' || r.card) return
      const m = { j: [0, 1], ArrowDown: [0, 1], k: [0, -1], ArrowUp: [0, -1], h: [-1, 0], ArrowLeft: [-1, 0], l: [1, 0], ArrowRight: [1, 0] }[e.key]
      if (m) { e.preventDefault(); moveFocus(...m) }
    }
    addEventListener('keydown', f, true)
    return () => removeEventListener('keydown', f, true)
  }, [r])
}

function App() {
  const [st, refresh] = useBoard(), [r, go] = useRoute(), wide = useWide()
  const [pal, setPal] = useState(false), [keys, setKeys] = useState(false), [, setTheme] = useState(root.dataset.theme)
  // the button shows the theme a click turns on
  const themeIcon = () => root.dataset.theme === 'dark' ? IC.sun : IC.theme
  const toggleTheme = () => { const t = root.dataset.theme === 'dark' ? 'light' : 'dark'; root.dataset.theme = t; setTheme(t); try { localStorage.setItem('fm-theme', t) } catch {} }
  useKeys(r, go, setPal, setKeys, toggleTheme, pal, keys)
  const d = st.data
  useEffect(() => { document.title = d?.asks?.length ? `(${d.asks.length}) Fleet` : 'Fleet' }, [d])
  if (!d) return html`<div class="none" style="height:100vh">${st.err ? `Cannot load the fleet: ${st.err}` : ''}</div>`
  const cards = filterCards(d, r), open = d.cards.filter(c => ACTIVE.includes(c.stage)), stk = open.filter(stuck)
  const asks = d.asks?.length, today = total(d, d.landed.at(-1), 'landed'), opencard = id => go({ card: id })
  const count = t => t === 'all' ? null : total(d, d.cards.filter(c => inTab(t, c)).length, t)
  const shown = cards.filter(c => inTab(r.tab, c))
  const list = (r.tab === 'all' ? STAGES : r.tab === 'active' ? ACTIVE : [r.tab]).flatMap(s => sorted(shown.filter(c => c.stage === s)))
  const title = { board: 'Board', needs: 'Needs you', ship: 'Ship' }[r.view]
  const overlays = html`${r.card && html`<${Detail} d=${d} id=${r.card} go=${go} list=${list}/>`}
    ${pal && html`<${Palette} d=${d} go=${go} close=${() => setPal(false)} toggleTheme=${toggleTheme}/>`}${keys && html`<${Shortcuts} close=${() => setKeys(false)}/>`}`
  const body = r.view === 'ship' ? html`<${Ship} d=${d}/>` : r.view === 'needs' ? html`<${Needs} d=${d}/>` : null
  if (!wide) return html`<div class="phone">
    <div class="top"><h1>${title}</h1><div class="caps">${r.view === 'board' ? html`<${Filters} d=${d} r=${r} go=${go}/>` : ''}<button class="ib" onClick=${toggleTheme} aria-label="Light or dark theme">${I(themeIcon(), 18)}</button></div></div>
    <div class="sum"><${Live} d=${d} st=${st} refresh=${refresh}/></div>
    ${r.view === 'board' ? html`<div class="sum"><b>${asks == null ? 'Ask list unreadable' : asks ? `${asks} need${asks > 1 ? '' : 's'} you` : 'Nothing needs you'}</b> · <span>${total(d, open.length)} in flight</span> · <span class=${stk.length ? 'bad' : ''}>${total(d, stk.length)} stuck</span> · <span>${today} landed today</span></div>
      <div class="seg">${TABS.map(([t, n]) => html`<button aria-pressed=${r.tab === t} onClick=${() => go({ tab: t })}>${n === 'Landed today' ? 'Landed' : n}${count(t) != null ? html`<small class="num">${count(t)}</small>` : ''}</button>`)}</div>
      <${Chips} d=${d} r=${r} go=${go}/><${List} d=${d} cards=${shown} r=${r} open=${opencard}/>` : body}
    <div class="dock"><nav>${[['board', IC.board, 'Board'], ['needs', IC.inbox, 'Needs you'], ['ship', IC.ship, 'Ship'], ['metrics', IC.display, 'Metrics']].map(([v, ic, n]) =>
      html`<a href=${v === 'metrics' ? '/overview' : '#/' + v} aria-current=${r.view === v ? 'page' : null} aria-label=${n}>${I(ic, 20)}${v === 'needs' && asks ? html`<span class="badge">${asks}</span>` : ''}</a>`)}</nav>
      <button onClick=${() => setPal(true)} aria-label="Search">${I(IC.search, 20)}</button></div>${overlays}</div>`
  return html`<div class="app">
    <nav class="side">
      <div class="ws"><span class="logo">F</span><b>Fleet</b><span class="sp"></span><button class="ib" onClick=${() => setPal(true)} aria-label="Search" title="Search (⌘K)">${I(IC.search)}</button></div>
      <a class="nav" href="#/needs" aria-current=${r.view === 'needs' ? 'page' : null}>${I(IC.inbox)}Needs you${asks ? html`<span class="badge">${asks}</span>` : html`<span class="n num">${asks ?? '?'}</span>`}</a>
      <a class="nav" href="#/board" aria-current=${r.view === 'board' && !r.home.length ? 'page' : null} onClick=${() => go({ view: 'board', home: [] })}>${I(IC.board)}Board<span class="n num">${total(d, open.length)}</span></a>
      <a class="nav" href="#/ship" aria-current=${r.view === 'ship' ? 'page' : null}>${I(IC.ship)}Ship</a><a class="nav" href="/overview">${I(IC.display)}Metrics</a>
      <div class="sec">Homes</div>
      ${d.homes.map(h => { const cs = open.filter(c => c.home === h.id)
        return html`<button class="nav" aria-current=${r.view === 'board' && r.home.length === 1 && r.home[0] === h.id ? 'page' : null} onClick=${() => go({ view: 'board', home: [h.id], card: null })}>
          <span class="sq" style=${{ '--c': hc(d, h.id) }}></span>${h.name}${cs.some(stuck) ? html`<span class="dot" title="Stuck lanes"></span>` : ''}<span class="n num">${h.known ? cs.length : '?'}</span></button>` })}
      <div class="foot"><${Live} d=${d} st=${st} refresh=${refresh}/><span class="sp"></span><button class="ib" onClick=${toggleTheme} aria-label="Light or dark theme">${I(themeIcon())}</button></div>
    </nav>
    <main class="main">
      <header class="hd"><h1>${title}</h1>
        ${r.view === 'board' ? html`${TABS.map(([t, n]) => html`<button class="tab" aria-pressed=${r.tab === t} onClick=${() => go({ tab: t })}>${n}${count(t) != null ? html`<small class="num">${count(t)}</small>` : ''}</button>`)}
          <span class="sp"></span>
          <div class="kpi num"><a href="#/needs">Needs you <b>${asks ?? '?'}</b></a><button class=${stk.length ? 'bad' : ''} onClick=${() => go({ state: ['blocked', 'decision'] })}>Stuck <b>${total(d, stk.length)}</b></button>
            <button onClick=${() => go({ tab: 'landed' })}>Landed today <b>${today}</b></button><span title="Typical time from start to landed">Cycle p50 <b>${d.cycle_p50 == null ? '–' : dur(d.cycle_p50)}</b></span></div>
          <${Filters} d=${d} r=${r} go=${go} label="Filter"/>
          ${r.tab === 'active' || r.tab === 'all' ? html`<${Pop} label="Display" icon=${IC.display}><div class="pop-h">Rows</div>
            ${[['', 'No grouping'], ['home', 'Home']].map(([v, n]) => html`<button class="opt" aria-pressed=${r.rows === v} onClick=${() => go({ rows: v })}><span class="ck">${r.rows === v ? I(IC.check, 11) : ''}</span>${n}</button>`)}</${Pop}>` : ''}` : ''}
      </header>
      ${r.view === 'board' ? html`<${Chips} d=${d} r=${r} go=${go}/><${Board} d=${d} cards=${shown} r=${r} open=${opencard}/>` : body}
    </main>${overlays}</div>`
}
render(html`<${App}/>`, document.getElementById('app'))
