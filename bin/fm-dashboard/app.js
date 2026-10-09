// Fleet dashboard app shell: live data, routes, the Linear sidebar and header (phone: title, tabs and dock),
// filters, the ask list, the Ship mount, the command palette and keys.
import { render } from './vendor/preact-htm-3.1.1.js'
import { html, useState, useEffect, useRef, now, dur, hm, ACTIVE, STAGES, SNAME, STATES, stuck, state, sid, total, hc, hname, mname, sorted, filterCards, I, IC, StageIcon, Av } from './ui.js'
import { TABS, inTab, Board, MobileKanban, Detail } from './board.js'

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
// data.json carries what the Overview needs beyond the board: queue reasons, quota and flow history.
function useData(active) {
  const [st, set] = useState({ data: null, err: null })
  useEffect(() => {
    if (!active) return
    let alive = true
    async function pull() {
      try {
        const r = await fetch('data.json', { cache: 'no-store' })
        if (!r.ok) throw new Error(`the dashboard server answered ${r.status}`)
        const data = await r.json()
        if (alive) set({ data, err: null })
      } catch (e) { if (alive) set(s => ({ data: s.data, err: e.message || String(e) })) }
    }
    pull()
    const t = setInterval(pull, POLL_MS)
    return () => { alive = false; clearInterval(t) }
  }, [active])
  return st
}
function useWide() {
  const [w, set] = useState(matchMedia(WIDE).matches)
  useEffect(() => { const m = matchMedia(WIDE), f = () => set(m.matches); m.addEventListener('change', f); return () => m.removeEventListener('change', f) }, [])
  return w
}
function useTick(ms) { const [, set] = useState(0); useEffect(() => { const t = setInterval(() => set(x => x + 1), ms); return () => clearInterval(t) }, []) }

// The view, tab, rows, filters and open card live in the URL hash.
const VIEWS = ['board', 'overview', 'needs', 'ship']
function parseHash() {
  const [path, q] = location.hash.replace(/^#\/?/, '').split('?')
  const p = new URLSearchParams(q || ''), list = k => (p.get(k) || '').split(',').filter(Boolean)
  return { view: VIEWS.includes(path) ? path : 'board', tab: TABS.some(([t]) => t === p.get('tab')) ? p.get('tab') : 'active',
    rows: p.get('rows') === 'home' ? 'home' : '', home: list('home'), model: list('model'), state: list('state'), card: p.get('card') }
}
// An old /overview link lands on the app and opens the native Overview, its address now hash-based.
function initialRoute() {
  const r = parseHash()
  if (location.pathname.replace(/\/+$/, '') === '/overview') { history.replaceState(null, '', '/#/overview'); return { ...r, view: 'overview' } }
  return r
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
  const [r, set] = useState(initialRoute)
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

// The 3D ship view is its own module: ship/index.js exports mount(element, data, open) and may return { update(data), unmount() };
// open(id) shows that card's detail.
function Ship({ d, open }) {
  const ref = useRef(), view = useRef(), [missing, setMissing] = useState(false)
  useEffect(() => {
    let gone = false
    import('./ship/index.js').then(m => { if (!gone) view.current = m.mount(ref.current, d, open) }).catch(() => setMissing(true))
    return () => { gone = true; view.current?.unmount?.() }
  }, [])
  useEffect(() => view.current?.update?.(d), [d])
  return html`<div id="ship-mount" ref=${ref}>${missing ? html`<div class="none">${I(IC.ship, 32)}<p>The 3D ship view mounts here.</p></div>` : ''}</div>`
}
// Needs you is the ask list and nothing else.
const Needs = ({ d }) => d.asks == null ? html`<div class="none"><p>The ask list could not be read.</p></div>`
  : !d.asks.length ? html`<div class="none">${I(IC.inbox, 32)}<p>Nothing needs you.</p></div>`
  : html`<ul class="inbox">${d.asks.map(a => html`<li><span>${a.text}</span><small class="num">${a.age == null ? '' : dur(a.age)}</small>${a.url ? html`<a class="pill" href=${a.url} target="_blank" rel="noreferrer">Open</a>` : ''}</li>`)}</ul>`

// Overview: the fleet's numbers as charts - each figure with its trend, the lifecycle as a rail of stages,
// colour that means something (stage colours for work in motion, orange and red only where it waits or is stuck).
const QTONE = ['--green', '--orange', '--accent', '--grey', '--grey']
const OV_STATES = [['building', 'Building', ''], ['validating', 'Validating or CI', 'v'], ['finished', 'Finished, not landed', 'f'],
  ['waiting', 'Waiting', 'w'], ['decision', 'On a decision', 'd'], ['blocked', 'Blocked', 'b']]
const sum = v => Object.values(v || {}).reduce((a, b) => a + (b || 0), 0)
const ts = v => typeof v === 'number' ? v : typeof v === 'string' ? Date.parse(v) / 1000 : null
const sign = n => n > 0 ? `+${n}` : `${n}`
// A day's trend from the 10-minute samples: the line, and the change since the sample nearest 24 hours ago.
function trend(hist, key, v) {
  const t = now(), day = (hist || []).filter(x => x.at >= t - 90000 && x[key] != null)
  if (day.length < 2 || v == null) return {}
  const ago = day.reduce((a, b) => Math.abs(b.at - (t - 86400)) < Math.abs(a.at - (t - 86400)) ? b : a)
  return { line: [...day.map(x => x[key]), v], delta: Math.abs(ago.at - (t - 86400)) < 7200 ? v - ago[key] : null }
}
function Line({ vals, c }) {
  const top = Math.max(1, ...vals), lo = Math.min(...vals), span = Math.max(1, top - lo), dx = 100 / Math.max(1, vals.length - 1)
  const pts = vals.map((v, k) => `${(k * dx).toFixed(1)},${(26 - (v - lo) / span * 22).toFixed(1)}`).join(' ')
  return html`<svg class="ov-line" viewBox="0 0 100 28" preserveAspectRatio="none" aria-hidden="true" style=${{ color: `var(${c})` }}>
    <polygon points=${`0,28 ${pts} 100,28`} fill="currentColor" fill-opacity=".12"/><polyline points=${pts} fill="none" stroke="currentColor" stroke-width="1.6" vector-effect="non-scaling-stroke" stroke-linejoin="round"/></svg>`
}
function Kpi({ name, v, sub, c, t, good, href, onClick }) {
  const tag = href ? 'a' : onClick ? 'button' : 'div', d = t?.delta
  const dc = !d || !good ? '' : (d > 0) === (good === 'up') ? 'up' : 'dn'
  return html`<${tag} class="ov-kpi" href=${href} onClick=${onClick} style=${{ '--c': `var(${c})` }}>
    <span><i></i>${name}${d != null ? html`<em class=${'num ' + dc} title="change since this time yesterday">${d ? sign(d) : '±0'}</em>` : ''}</span>
    <b class="num">${v}${sub ? html`<small>${sub}</small>` : ''}</b>${t?.line ? html`<${Line} vals=${t.line} c=${c}/>` : html`<div class="ov-line"></div>`}</${tag}>`
}
// 14 days of a daily count: today in the accent, earlier days muted, the period average dashed.
function Days({ rows, c, label }) {
  if (!rows?.length) return html`<p class="ov-tot">No days on record</p>`
  const known = rows.filter(r => r.value != null), top = Math.max(1, ...known.map(r => r.value)), w = 100 / rows.length
  const prior = rows.slice(0, -1).filter(r => r.value != null), avg = prior.length ? prior.reduce((a, r) => a + r.value, 0) / prior.length : null
  const day = s => new Date(`${s}T12:00:00`).toLocaleDateString([], { day: 'numeric', month: 'short' })
  return html`<div class="ov-days" style=${{ '--c': `var(${c})` }}><svg viewBox="0 0 100 60" preserveAspectRatio="none" role="img" aria-label=${`${label}, last ${rows.length} days`}>
    ${rows.map((r, k) => { if (r.value == null) return ''; const h = r.value / top * 56; return html`<rect class=${k === rows.length - 1 ? 'now' : ''} x=${(k * w + w * .14).toFixed(2)} y=${(60 - h).toFixed(2)} width=${(w * .72).toFixed(2)} height=${Math.max(.5, h).toFixed(2)} rx=".6"><title>${day(r.day)}: ${r.value}</title></rect>` })}
    ${avg != null ? html`<line x1="0" x2="100" y1=${(60 - avg / top * 56).toFixed(2)} y2=${(60 - avg / top * 56).toFixed(2)} vector-effect="non-scaling-stroke"/>` : ''}</svg>
    <div class="ov-axis"><span>${day(rows[0].day)}</span><span>today</span></div><small>${avg != null ? `avg ${Math.round(avg)} a day before today` : 'no known days to average'}</small></div>`
}
// The lifecycle rail: every open lane by stage, split into moving, waiting and stuck, then today's landings.
function Rail({ d, go }) {
  const cs = d.cards, col = s => cs.filter(c => c.stage === s)
  const top = Math.max(1, ...ACTIVE.map(s => col(s).length))
  return html`<div class="ov-rail">${[...ACTIVE, 'landed'].map(s => {
    const xs = col(s), n = xs.length, st = xs.filter(stuck).length, wt = xs.filter(c => c.wait && !stuck(c)).length
    const old = s === 'landed' ? null : Math.max(0, ...xs.map(c => c.since ? now() - c.since : 0))
    return html`<button class="ov-stage" key=${s} style=${{ '--c': `var(--st-${s})` }} onClick=${() => go({ view: 'board', tab: s === 'landed' ? 'landed' : 'active', card: null })}>
      <span class="ov-sh"><${StageIcon} s=${s}/>${SNAME[s]}</span><b class="num">${s === 'landed' ? total(d, n, 'landed') : n}</b>
      ${s === 'landed' ? html`<span class="ov-sbar done"></span>` : html`<span class="ov-sbar"><i style=${{ width: `${(n - st - wt) / top * 100}%` }}></i><i class="w" style=${{ width: `${wt / top * 100}%` }}></i><i class="s" style=${{ width: `${st / top * 100}%` }}></i></span>`}
      <small>${s === 'landed' ? 'merged today' : !n ? 'empty' : [st && html`<em class="s">${st} stuck</em>`, wt && `${wt} waiting`, old > 60 && `oldest ${dur(old)}`].filter(Boolean).flatMap((p, k) => k ? [' · ', p] : [p])}</small></button>` })}</div>`
}
function Overview({ d, od, go }) {
  const q = od.data
  if (!q) return html`<div class="ov"><div class="none"><p>${od.err ? `Cannot load the overview: ${od.err}` : 'Loading the overview…'}</p></div></div>`
  const m = q.metrics, asks = d.asks, openCards = d.cards.filter(c => ACTIVE.includes(c.stage)), hist = q.lane_history
  const stk = openCards.filter(stuck).length, toLand = openCards.filter(c => c.stage === 'merge').length
  const states = m.lane_states?.value, age = now() - ts(q.build_time)
  const qr = q.queue_reasons || [], qOk = m.queue?.value != null, qTop = Math.max(1, ...qr.map(x => sum(x.by_home)))
  const flow = (mid, label, foot, c) => { const r = m[mid]; return html`<div class="ov-flow"><span>${label}</span>
    <b class="num">${r?.status === 'unknown' ? 'unknown' : `${r?.status === 'lower_bound' && mid === 'landed' ? '≥' : ''}${r?.value ?? '–'}`}</b><small>${foot}</small>
    <${Days} rows=${r?.daily} c=${c} label=${label}/></div>` }
  return html`<div class="ov">
    <p class="ov-tot">${od.err ? html`<span class="bad">Refresh failed: ${od.err} · </span>` : ''}${age < 60 ? 'just updated' : `updated ${dur(age)} ago`}</p>
    <div class="ov-kpis">
      <${Kpi} name="Needs you" v=${asks == null ? '?' : asks.length} c=${asks?.length ? '--orange' : '--green'} href="#/needs"/>
      <${Kpi} name="Stuck" v=${stk} c=${stk ? '--red' : '--green'} t=${trend(hist, 'stuck', stk)} good="down" onClick=${() => go({ view: 'board', tab: 'active', state: ['blocked', 'decision'], card: null })}/>
      <${Kpi} name="To land" v=${toLand} c="--st-merge" onClick=${() => go({ view: 'board', tab: 'active', card: null })}/>
      <${Kpi} name="Lanes open" v=${m.lanes?.value ?? '–'} sub=${` of ${m.lane_plan?.value ?? '–'}`} c="--accent" t=${trend(hist, 'lanes', m.lanes?.value)} good="up"/>
      <${Kpi} name="Ready" v=${m.ready?.value ?? '–'} c="--h-2" t=${trend(hist, 'ready', m.ready?.value)}/>
    </div>
    <div class="ov-grid">
      ${asks?.length ? html`<section class="ov-card wide"><h3>Needs you</h3><div class="ov-asks">${asks.map((a, k) =>
        html`<a class="ov-ask" key=${k} href=${a.url || '#/needs'} target=${a.url ? '_blank' : null} rel="noreferrer"><span>${a.text}</span><small class="num">${a.age == null ? '' : dur(a.age)}</small></a>`)}</div></section>` : ''}
      <section class="ov-card wide"><h3>Lifecycle</h3><${Rail} d=${d} go=${go}/></section>
      <section class="ov-card w2"><h3>Flow</h3><div class="ov-flows">${flow('landed', 'Landed today', 'recorded merges', '--st-landed')}${flow('closed', 'Closed 7 d', 'backlog items', '--green')}</div></section>
      <section class="ov-card w1"><h3>Lanes by state</h3>
        <div class="ov-bar tall">${states ? OV_STATES.map(([k, , c]) => states[k] ? html`<i class=${c} key=${k} style=${{ flex: states[k] }}></i>` : '') : ''}</div>
        <div class="ov-legend">${OV_STATES.map(([k, nm, c]) => html`<span key=${k}><i class=${c}></i>${nm}<b class="num">${states ? states[k] : '–'}</b></span>`)}</div></section>
      <section class="ov-card w1"><h3>Why work is queued</h3>
        <div class="ov-ql">${qr.map((x, k) => { const n = sum(x.by_home); return html`<div class="ov-qrow" key=${k}><span>${x.reason}</span>
          <span class="ov-bar">${qOk && n > 0 ? html`<i style=${{ width: `${n / qTop * 100}%`, background: `var(${QTONE[k] || '--grey'})` }}></i>` : ''}</span><b class="num">${qOk ? n : '–'}</b></div>` })}</div>
        <p class="ov-tot">Total <b class="num">${qOk ? sum(m.queue.value) : '–'}</b> queued</p></section>
      <section class="ov-card wide"><h3>Quota runway</h3><div class="ov-ql ov-quota">${(q.quota_accounts || []).map((a, k) => {
        const w = a.limit || (a.windows || []).filter(x => x.used != null).sort((x, y) => y.used - x.used)[0]
        const tone = a.empty ? 'bad' : a.problem ? 'mut' : a.status === 'projected_exhaustion' ? 'warn' : ''
        const right = a.empty ? 'used up' : a.problem ? 'unknown' : a.runout ? `out in ${dur(ts(a.runout) - now())}` : w?.reset ? `resets ${hm(ts(w.reset))}` : 'lasts'
        return html`<div key=${k}><div class="ov-qrow"><span>${a.name}</span><span class=${'ov-bar ' + (w?.used == null ? 'unk' : '')}><i style=${{ width: `${w?.used != null ? Math.max(2, Math.min(100, w.used)) : 0}%`,
          background: `var(${{ bad: '--red', warn: '--orange', mut: '--grey' }[tone] || '--green'})` }}></i></span>
          <b class="num ${tone}">${w?.used != null ? `${Math.round(w.used)}%` : '–'}</b></div><small class="ov-qsub ${tone}">${right}</small></div>` })}</div>
        ${!q.quota_accounts?.length ? html`<p class="ov-tot">No account reported a window</p>` : ''}</section>
      <section class="ov-card wide"><h3>Homes</h3><div class="ov-homes">${(q.homes || []).map(h => {
        const n = h.lanes?.value, xs = openCards.filter(c => c.home === h.home), cap = Math.max(h.plan || 0, n || 0, 1)
        return html`<button class="ov-hrow" key=${h.home} onClick=${() => go({ view: 'board', tab: 'active', home: [h.home], card: null })}>
        <span class="sq" style=${{ '--c': hc(d, h.home) }}></span><b>${hname(d, h.home)}</b>
        <span class="ov-load" title=${`${n ?? '?'} of ${h.plan} lanes`}>${ACTIVE.map(s => { const k = xs.filter(c => c.stage === s).length; return k ? html`<i key=${s} style=${{ width: `${k / cap * 100}%`, background: `var(--st-${s})` }}></i>` : '' })}</span>
        <span class="num">${h.lanes?.status === 'unknown' ? '?' : n ?? '–'}<small>/${h.plan}</small></span>
        <span class="num">${h.ready?.value ?? '–'}<small> ready</small></span>
        <span class="num">${h.closed?.status === 'unknown' ? '–' : h.closed?.value}<small> closed</small></span></button>` })}</div></section>
      <section class="ov-card wide"><h3>Recently landed</h3><div class="ov-merges">${(q.recent_merges || []).map((x, k) =>
        html`<div class="ov-mrow" key=${k}><${StageIcon} s="landed"/><a href=${x.url} target="_blank" rel="noreferrer">${x.title}</a><span><span class="sq" style=${{ '--c': hc(d, x.home) }}></span>${hname(d, x.home)}</span><small class="num">${hm(x.at)}</small></div>`)}
        ${!q.recent_merges?.length ? html`<p class="ov-tot">No merge on record</p>` : ''}</div></section>
    </div></div>`
}

function Palette({ d, go, close, toggleTheme }) {
  const [q, setQ] = useState(''), [i, setI] = useState(0), input = useRef()
  useEffect(() => input.current?.focus(), [])  // autofocus is ignored while a card holds focus
  const groups = [
    ['Go to', [['board', 'Board'], ['overview', 'Overview'], ['needs', 'Needs you'], ['ship', 'Ship']].map(([v, n]) => ({ n, k: `G ${n[0]}`, run: () => go({ view: v, card: null }) }))],
    ['Actions', [
      { n: 'Show stuck lanes', run: () => go({ view: 'board', tab: 'active', state: ['blocked', 'decision'], card: null }) },
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
  const [st, refresh] = useBoard(), [r, go] = useRoute(), wide = useWide(), ov = useData(r.view === 'overview')
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
  const title = { board: 'Board', overview: 'Overview', needs: 'Needs you', ship: 'Ship' }[r.view]
  const overlays = html`${r.card && html`<${Detail} d=${d} id=${r.card} go=${go} list=${list}/>`}
    ${pal && html`<${Palette} d=${d} go=${go} close=${() => setPal(false)} toggleTheme=${toggleTheme}/>`}${keys && html`<${Shortcuts} close=${() => setKeys(false)}/>`}`
  const body = r.view === 'ship' ? html`<${Ship} d=${d} open=${opencard}/>` : r.view === 'overview' ? html`<${Overview} d=${d} od=${ov} go=${go}/>` : r.view === 'needs' ? html`<${Needs} d=${d}/>` : null
  if (!wide) return html`<div class="phone">
    <div class="top"><h1>${title}</h1><div class="caps">${r.view === 'board' ? html`<${Filters} d=${d} r=${r} go=${go}/>` : ''}<button class="ib" onClick=${toggleTheme} aria-label="Light or dark theme">${I(themeIcon(), 18)}</button></div></div>
    <div class="sum"><${Live} d=${d} st=${st} refresh=${refresh}/></div>
    ${r.view === 'board' ? html`<div class="sum"><b>${asks == null ? 'Ask list unreadable' : asks ? `${asks} need${asks > 1 ? '' : 's'} you` : 'Nothing needs you'}</b> · <span>${total(d, open.length)} in flight</span> · <span class=${stk.length ? 'bad' : ''}>${total(d, stk.length)} stuck</span> · <span>${today} landed today</span></div>
      <div class="seg">${TABS.map(([t, n]) => html`<button aria-pressed=${r.tab === t} onClick=${() => go({ tab: t })}>${n === 'Landed today' ? 'Landed' : n}${count(t) != null ? html`<small class="num">${count(t)}</small>` : ''}</button>`)}</div>
      <${Chips} d=${d} r=${r} go=${go}/><${MobileKanban} d=${d} cards=${shown} r=${r} open=${opencard}/>` : body}
    <div class="dock"><nav>${[['board', IC.board, 'Board'], ['overview', IC.display, 'Overview'], ['needs', IC.inbox, 'Needs you'], ['ship', IC.ship, 'Ship']].map(([v, ic, n]) =>
      html`<a href=${'#/' + v} aria-current=${r.view === v ? 'page' : null} aria-label=${n}>${I(ic, 20)}${v === 'needs' && asks ? html`<span class="badge">${asks}</span>` : ''}</a>`)}</nav>
      <button onClick=${() => setPal(true)} aria-label="Search">${I(IC.search, 20)}</button></div>${overlays}</div>`
  return html`<div class="app">
    <nav class="side">
      <div class="ws"><span class="logo">F</span><b>Fleet</b><span class="sp"></span><button class="ib" onClick=${() => setPal(true)} aria-label="Search" title="Search (⌘K)">${I(IC.search)}</button></div>
      <a class="nav" href="#/needs" aria-current=${r.view === 'needs' ? 'page' : null}>${I(IC.inbox)}Needs you${asks ? html`<span class="badge">${asks}</span>` : html`<span class="n num">${asks ?? '?'}</span>`}</a>
      <a class="nav" href="#/board" aria-current=${r.view === 'board' && !r.home.length ? 'page' : null} onClick=${() => go({ view: 'board', home: [] })}>${I(IC.board)}Board<span class="n num">${total(d, open.length)}</span></a>
      <a class="nav" href="#/overview" aria-current=${r.view === 'overview' ? 'page' : null}>${I(IC.display)}Overview</a>
      <a class="nav" href="#/ship" aria-current=${r.view === 'ship' ? 'page' : null}>${I(IC.ship)}Ship</a>
      <div class="sec">Homes</div>
      ${d.homes.map(h => { const cs = open.filter(c => c.home === h.id)
        return html`<button class="nav home-nav" aria-label=${h.name} title=${h.name} aria-current=${r.view === 'board' && r.home.length === 1 && r.home[0] === h.id ? 'page' : null} onClick=${() => go({ view: 'board', home: [h.id], card: null })}>
          <span class="sq" style=${{ '--c': hc(d, h.id) }}></span><span class="home-name">${h.name}</span><span class="home-short" aria-hidden="true">${Array.from(h.name).slice(0, 4).join('')}</span>${cs.some(stuck) ? html`<span class="dot" title="Stuck lanes"></span>` : ''}<span class="n num">${h.known ? cs.length : '?'}</span></button>` })}
      <div class="foot"><${Live} d=${d} st=${st} refresh=${refresh}/><span class="sp"></span><button class="ib" onClick=${toggleTheme} aria-label="Light or dark theme">${I(themeIcon())}</button></div>
    </nav>
    <main class="main">
      <header class="hd"><h1>${title}</h1>
        ${r.view === 'board' ? html`${TABS.map(([t, n]) => html`<button class="tab" aria-pressed=${r.tab === t} onClick=${() => go({ tab: t })}>${n}${count(t) != null ? html`<small class="num">${count(t)}</small>` : ''}</button>`)}
          <span class="sp"></span>
          <div class="kpi num"><a href="#/needs">Needs you <b>${asks ?? '?'}</b></a><button class=${stk.length ? 'bad' : ''} onClick=${() => go({ tab: 'active', state: ['blocked', 'decision'], card: null })}>Stuck <b>${total(d, stk.length)}</b></button>
            <button onClick=${() => go({ tab: 'landed' })}>Landed today <b>${today}</b></button><span title="Typical time from start to landed">Cycle p50 <b>${d.cycle_p50 == null ? '–' : dur(d.cycle_p50)}</b></span></div>
          <${Filters} d=${d} r=${r} go=${go} label="Filter"/>
          ${r.tab === 'active' || r.tab === 'all' ? html`<${Pop} label="Display" icon=${IC.display}><div class="pop-h">Rows</div>
            ${[['', 'No grouping'], ['home', 'Home']].map(([v, n]) => html`<button class="opt" aria-pressed=${r.rows === v} onClick=${() => go({ rows: v })}><span class="ck">${r.rows === v ? I(IC.check, 11) : ''}</span>${n}</button>`)}</${Pop}>` : ''}` : ''}
      </header>
      ${r.view === 'board' ? html`<${Chips} d=${d} r=${r} go=${go}/><${Board} d=${d} cards=${shown} r=${r} open=${opencard}/>` : body}
    </main>${overlays}</div>`
}
render(html`<${App}/>`, document.getElementById('app'))
