// Tickets: every backlog item across the homes on one Jira-like board - To do, In progress, In review, Waiting on
// captain, Done, On hold - filtered by project; a phone shows one column at a time. Waiting on captain is the ask list
// and nothing else, so its count is the Needs you count everywhere.
import { html, useState, useEffect, useRef, now, dur, prNum, hc, hname, I, IC, ASK_TAG, askType, askOrder } from './ui.js'

export const IC_TICKET = html`<path d="M2.5 4.5a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v2a1.5 1.5 0 0 0 0 3v2a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1v-2a1.5 1.5 0 0 0 0-3zM10 5.5v1M10 9.5v1"/>`
const IC_RELEASE = html`<path d="M8 2.5l5.5 5.5L8 13.5 2.5 8z"/>`
const COLS = [['todo', 'To do'], ['progress', 'In progress'], ['review', 'In review'], ['captain', 'Waiting on captain'], ['done', 'Done'], ['hold', 'On hold']]
const CAP = 30
// The last update is an exact time from a lane's status line, or only the day the item was filed or closed.
const at = u => typeof u === 'number' ? u : u ? Date.parse(`${u}T12:00:00`) / 1000 : 0
const ago = u => typeof u === 'number' ? dur(now() - u) : u ? (k => k < 1 ? 'today' : `${k}d`)(Math.round((new Date().setHours(12, 0, 0, 0) / 1000 - at(u)) / 86400)) : ''
const order = (s, ts) => [...ts].sort(s === 'done' ? (a, b) => at(b.updated) - at(a.updated) : (a, b) => (a.priority ?? 9) - (b.priority ?? 9) || at(b.updated) - at(a.updated))
const PRIO = ['Urgent', 'High', 'Medium', 'Low']

function Ticket({ d, t }) {
  const n = prNum(t.pr)
  return html`<article class="card tk">
    <div class="r1"><span class="id">${t.project || 'No project'}</span><span class="num age" title="Last update">${ago(t.updated)}</span>
      <span class="sq" style=${{ '--c': hc(d, t.home) }} title=${`Owner: ${hname(d, t.home)}`}></span></div>
    <h3>${t.title}</h3>
    <div class="r3">${t.priority != null ? html`<span class=${'pill prio p' + t.priority} title=${PRIO[t.priority] || ''}>P${t.priority}</span>` : ''}
      ${t.asked ? html`<span class="pill asked">Your ask</span>` : ''}<span class="pill" title="Target release">${I(IC_RELEASE, 11)}${t.release[0].toUpperCase() + t.release.slice(1)}</span>
      ${n ? html`<a class="pill pr" href=${t.pr} target="_blank" rel="noreferrer">${I(IC.pr, 12)}${n}</a>` : ''}</div></article>`
}
const Ask = ({ a }) => html`<article class="card tk ask"><div class="r1"><span class="id">${ASK_TAG[askType(a.text, a.type)]}</span>${a.age != null ? html`<span class="num age">${dur(a.age)}</span>` : ''}</div>
  <h3>${a.text}</h3>${a.url ? html`<div class="r3"><a class="pill" href=${a.url} target="_blank" rel="noreferrer">Open</a></div>` : ''}</article>`

function Col({ d, s, name, xs, asks, n }) {
  const [all, setAll] = useState(false)
  return html`<section class=${'col tkc' + (s === 'captain' ? ' you' : '')}><header class="ch"><b>${name}</b><span class="n num">${n}</span></header>
    ${asks ? asks.map(a => html`<${Ask} key=${a.id} a=${a}/>`) : (all ? xs : xs.slice(0, CAP)).map(t => html`<${Ticket} key=${t.id} d=${d} t=${t}/>`)}
    ${!asks && xs.length > CAP && !all ? html`<button class="more" onClick=${() => setAll(true)}>${xs.length - CAP} more</button>` : ''}
    ${n === '?' ? html`<p class="empty">The ask list could not be read</p>` : !n ? html`<p class="empty">Nothing here</p>` : ''}</section>`
}

export function Tickets({ d, r, go, wide }) {
  const all = d.tickets || [], ts = all.filter(t => !r.project.length || r.project.includes(t.project || 'none')), unread = d.tickets_unread || []
  const projects = [...new Set(all.map(t => t.project || 'none'))].sort((a, b) => (a === 'none') - (b === 'none') || a.localeCompare(b))
  const cols = COLS.map(([s, name]) => { const xs = s === 'captain' ? [] : order(s, ts.filter(t => t.state === s)), asks = s === 'captain' ? askOrder(d.asks || []) : null
    return { s, name, xs, asks, n: !asks ? xs.length : d.asks == null ? '?' : asks.length } })
  const [i, setI] = useState(COLS.findIndex(([s]) => s === 'captain')), ref = useRef()
  useEffect(() => { if (!wide) ref.current?.children[i]?.scrollIntoView({ inline: 'start', block: 'nearest' }) }, [wide])
  useEffect(() => { if (!wide) document.querySelector('.mseg [aria-selected=true]')?.scrollIntoView({ inline: 'center', block: 'nearest' }) }, [i, wide])
  const jump = k => { setI(k); ref.current?.children[k]?.scrollIntoView({ behavior: 'smooth', inline: 'start', block: 'nearest' }) }
  const onScroll = () => { const el = ref.current; if (el) { const k = Math.round(el.scrollLeft / el.clientWidth); if (k !== i) setI(k) } }
  return html`<div class="tks">
    <div class="seg tkp" role="group" aria-label="Project">${[['', 'All projects', all.length], ...projects.map(p => [p, p === 'none' ? 'No project' : p, all.filter(t => (t.project || 'none') === p).length])]
      .map(([v, n, k]) => html`<button aria-pressed=${v ? r.project.length === 1 && r.project[0] === v : !r.project.length} onClick=${() => go({ project: v ? [v] : [] })}>${n}<small class="num">${k}</small></button>`)}</div>
    ${unread.length ? html`<p class="sum"><span class="bad">Backlog not read: ${unread.map(h => hname(d, h)).join(', ')}</span></p>` : ''}
    ${wide ? '' : html`<div class="mseg" role="tablist">${cols.map((c, k) => html`<button role="tab" aria-selected=${i === k} onClick=${() => jump(k)}>${c.name}<small class="num">${c.n}</small></button>`)}</div>`}
    <div class=${wide ? 'tkb' : 'mcols'} ref=${ref} onScroll=${wide ? null : onScroll}>${cols.map(c => html`<${Col} key=${c.s} d=${d} ...${c}/>`)}</div></div>`
}
