// Tickets, in the owner-approved look: Your asks or System, a hero that counts what is done with one square per ticket
// (its legend picks the list: Moving, To do, On hold or Done), the list sorted by priority with each row's project icon,
// P0-P3 chip, how far its lane has got and its age; By release lays the open items in Next release, After and Later.
// On a computer a By project list sits beside it. A row opens the ticket page: its description, the captain's words it
// serves, its fields and its thread: the captain's comments with the lead's answers and, for a live lane, its status lines.
import { html, useState, useEffect, useRef, now, dur, hm, prNum, hc, hname, I, IC } from './ui.js'
import { squash, Entry } from './board.js'
import { Tile, Chip, Row, LIC } from './look.js'

export const IC_TICKET = html`<path d="M2.5 4.5a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v2a1.5 1.5 0 0 0 0 3v2a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1v-2a1.5 1.5 0 0 0 0-3zM10 5.5v1M10 9.5v1"/>`
const IC_RELEASE = html`<path d="M8 2.5l5.5 5.5L8 13.5 2.5 8z"/>`
const COLS = [['todo', 'To do'], ['progress', 'In progress'], ['review', 'In review'], ['captain', 'Waiting on captain'], ['done', 'Done'], ['hold', 'On hold']]
const CAP = 30
// The last update is an exact time from a lane's status line, or only the day the item was filed or closed.
const at = u => typeof u === 'number' ? u : u ? Date.parse(`${u}T12:00:00`) / 1000 : 0
const ago = u => typeof u === 'number' ? dur(now() - u) : u ? (k => k < 1 ? 'today' : `${k}d`)(Math.round((new Date().setHours(12, 0, 0, 0) / 1000 - at(u)) / 86400)) : ''
const order = (s, ts) => [...ts].sort(s === 'done' ? (a, b) => at(b.updated) - at(a.updated) : (a, b) => (a.priority ?? 9) - (b.priority ?? 9) || at(b.updated) - at(a.updated))
const PRIO = ['Urgent', 'High', 'Medium', 'Low']
// Release lanes: a project's open items by target release. Next, After and Later are their own lanes; of a project's
// named releases (v0.2.0, muxr 0.2.10) the lowest version is its Next release unless it already has items marked next.
const LANES = [['next', 'Next release'], ['after', 'After'], ['later', 'Later']]
const rel = t => t.release.toLowerCase(), cap = r => /^(?:next|after|later)$/i.test(r) ? r[0].toUpperCase() + r.slice(1).toLowerCase() : r
const nat = (a, b) => a.localeCompare(b, undefined, { numeric: true })
function laneOf(ts) {
  const first = {}
  for (const t of ts) { const r = rel(t), p = t.project || 'none'
    if (r === 'next') first[p] = r
    else if (r !== 'after' && r !== 'later' && first[p] !== 'next' && (first[p] == null || nat(r, first[p]) < 0)) first[p] = r }
  return t => { const r = rel(t); return r === 'after' || r === 'later' ? r : r === first[t.project || 'none'] ? 'next' : 'after' }
}
const relRank = r => ({ next: 0, after: 2, later: 3 })[r] ?? 1

// A comment goes to the ticket's lead as a steer. The server takes it only from a device that opened the owner's
// sign-off board link at this address, whose cookie this page never sees.
function Comment({ t, onSent }) {
  const [text, setText] = useState(''), [note, setNote] = useState(''), [busy, setBusy] = useState(false)
  async function send(e) {
    e.preventDefault()
    setBusy(true)
    try {
      const r = await fetch('comment', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ticket: t.id, text }) })
      const a = await r.json().catch(() => ({ error: `the dashboard server answered ${r.status}` }))
      if (!r.ok) return setNote(a.error || `the dashboard server answered ${r.status}`)
      onSent({ at: Math.floor(Date.now() / 1000), text: text.trim(), to: a.to }); setText(''); setNote('')
    } catch (err) { setNote(`Not sent: ${err.message || err}`) } finally { setBusy(false) }
  }
  return html`<form class="tk-say" onSubmit=${send}><textarea aria-label="Comment" placeholder=${t.home === 'main' ? 'Comment to Main…' : `Comment to the ${t.home} lead…`} maxlength="1000" rows="2" value=${text} onInput=${e => setText(e.target.value)}></textarea>
    <div class="row"><small role="status">${note || 'Goes to the owning lead as a steer'}</small><span class="sp"></span><button class="btn" type="submit" disabled=${busy || !text.trim()}>Send</button></div></form>`
}
const lead = (d, h) => h === 'main' ? 'Main' : `${hname(d, h)} lead`
function TicketPage({ d, t, go }) {
  const c = d.cards.find(x => x.id === t.id), n = prNum(t.pr), close = () => go({ ticket: null }), ref = useRef(), [sent, setSent] = useState([])
  // a comment shows at once; the build's copy replaces it on the next refresh
  const said = [...(t.comments || []), ...sent.filter(x => !(t.comments || []).some(y => y.text === x.text))]
  useEffect(() => { ref.current?.focus(); const f = e => e.key === 'Escape' && close(); addEventListener('keydown', f); return () => removeEventListener('keydown', f) }, [t.id])
  const P = (k, v) => v ? html`<dt>${k}</dt><dd>${v}</dd>` : ''
  return html`<div class="scrim dim" onClick=${close}></div><aside class="peek" role="dialog" aria-label=${t.title} tabindex="-1" ref=${ref}>
    <div class="bar"><span>${COLS.find(([s]) => s === t.state)[1]}</span><span class="sp"></span><button class="ib" onClick=${close} aria-label="Close">${I(IC.x)}</button></div>
    <div class="body"><div class="id">${t.project || 'No project'}</div><h2>${t.title}</h2>${t.desc ? html`<p class="why tk-desc">${t.desc}</p>` : ''}
      ${t.ask ? html`<blockquote class="tk-ask"><small>Serves your ask${t.ask.day ? ` of ${t.ask.day}` : ''}${t.ask.ref ? ` · ${t.ask.ref}` : ''}</small>“${t.ask.words}”</blockquote>` : ''}
      <dl class="props">${P('Priority', t.priority != null && html`<span class=${'pill prio p' + t.priority}>P${t.priority}</span>${PRIO[t.priority] || ''}`)}
        ${P('Release', html`${I(IC_RELEASE, 12)}${cap(t.release)}`)}
        ${P('Owner', html`<span class="pill"><span class="sq" style=${{ '--c': hc(d, t.home) }}></span>${hname(d, t.home)}</span>`)}
        ${P('Pull request', n && html`<a class="pill pr" href=${t.pr} target="_blank" rel="noreferrer">${I(IC.pr, 12)}#${n}</a>`)}
        ${P('Proof', t.proof && html`<span class=${'num ' + (t.proof.receipt === 'FAIL' || t.proof.check && t.proof.check !== 'pass' ? 'bad' : '')}>${[t.proof.receipt && `Receipt ${t.proof.receipt}`,
          t.proof.check && `done-done ${t.proof.check}`, t.proof.head].filter(Boolean).join(' · ')}</span>${t.proof.at ? html`<small>${hm(t.proof.at)}</small>` : ''}`)}
        ${P('Last update', html`<span class="num">${ago(t.updated)}</span>${typeof t.updated === 'number' ? html`<small>${hm(t.updated)}</small>` : ''}`)}</dl>
      <div class="h4">Activity</div><${Comment} t=${t} onSent=${x => setSent([...sent, x])}/>${c?.history.length || said.length ? html`<ul class="act">${[...said.flatMap(x => [{ ...x, mine: true }, ...(x.picked ? [{ at: x.picked, by: x.to, text: 'Picked up your comment', answer: true }] : []),
          ...(x.replies || []).map(y => ({ ...y, at: y.at || x.at, answer: true }))]), ...squash(c?.history || [])]
        .sort((a, b) => (b.at || 0) - (a.at || 0)).map(x => x.answer ? html`<li class="mine"><b class="ok"></b><div><div class="h"><strong>${lead(d, x.by)}</strong><span class="sp"></span><span class="num">${hm(x.at)}</span></div><p>${x.text}</p></div></li>`
          : x.mine ? html`<li class="mine"><b class=${x.error ? 'bad' : 'ok'}></b><div><div class="h"><strong>You</strong><span class="sp"></span><span class="num">${hm(x.at)}</span></div>
          <p>${x.text}</p><small>${x.error ? `Not delivered: ${x.error}` : x.to === 'main' ? 'Sent to Main' : `Sent to the ${lead(d, x.to)} as a steer`}</small></div></li>` : html`<${Entry} x=${x}/>`)}</ul>`
        : html`<p class="empty">No status lines yet: the thread starts when a lane works on it.</p>`}
    </div></aside>`
}
// How far a ticket's lane has got, from Queued to Landed; a ticket with no lane takes its state.
const STEP = { queued: 0, building: 17, review: 33, test: 50, ci: 67, merge: 83, landed: 100 }
const pct = (d, t) => t.state === 'done' ? 100 : (c => c ? STEP[c.stage] : { todo: 0, hold: 0, progress: 17, review: t.pr ? 67 : 33 }[t.state])(d.cards.find(x => x.id === t.id))
const SHOW = { done: ['Done', t => t.state === 'done', 'd'], moving: ['Moving', t => t.state === 'progress' || t.state === 'review', 'm'], todo: ['To do', t => t.state === 'todo', ''], hold: ['On hold', t => t.state === 'hold', 'h'] }
const weekDone = (ts, back) => ts.filter(t => t.state === 'done' && (s => s >= back * 604800 && s < (back + 1) * 604800)(now() - at(t.updated))).length
export const proj = (d, t) => t.project || hname(d, t.home)  // a ticket with no project line shows and filters under its lead's home
const mine = (d, all, r) => all.filter(t => (r.kind === 'system') !== !!t.asked && (!r.project.length || r.project.includes(proj(d, t))) && (!r.release.length || r.release.includes(rel(t))))
export const ticketsHead = (d, r) => { const ts = mine(d, d.tickets || [], r), k = f => ts.filter(f).length
  return { h: r.kind === 'system' ? 'Where the system work stands' : 'Where your asks stand', sub: `${k(SHOW.done[1])} done, ${k(SHOW.moving[1])} moving, ${k(SHOW.todo[1])} not started, ${k(SHOW.hold[1])} on hold · ${ts.length} tickets` } }
export const KindSeg = ({ d, r, go, counts }) => html`<div class="kseg" role="group" aria-label="Whose work">${[['', 'Your asks', t => t.asked], ['system', 'System', t => !t.asked]].map(([v, n, f]) =>
  html`<button aria-pressed=${(r.kind || '') === v} onClick=${() => go({ kind: v, ticket: null })}>${n}${counts ? html`<small class="num">${(d.tickets || []).filter(f).length}</small>` : ''}</button>`)}</div>`
function Hero({ ts, r, go, aside }) {
  const ord = { done: 0, review: 1, progress: 1, todo: 2, hold: 3 }, wk = weekDone(ts, 0), before = weekDone(ts, 1)
  const body = html`<div class="h"><div class="sp"><label>${r.kind === 'system' ? 'System work done' : 'Your asks done'}</label><div class="big num">${ts.filter(SHOW.done[1]).length}<small>of ${ts.length}</small></div></div>
      <div class="hside"><span class="delta num"><i>▲</i>${wk} this week</span>${before ? `${before} the week before` : 'none the week before'}</div></div>
    <div class="dots" aria-label=${`${ts.length} tickets, one square each`}>${[...ts].sort((a, b) => ord[a.state] - ord[b.state]).map(t => html`<i class=${Object.values(SHOW).find(([, f]) => f(t))?.[2] || ''}></i>`)}</div>
    <div class="legend" role="group" aria-label="Show in the list">${Object.entries(SHOW).map(([k, [n, f, c]]) => html`<button aria-pressed=${!r.by && (r.show || 'moving') === k} onClick=${() => go({ show: k === 'moving' ? '' : k, by: '' })}><i class=${c}></i>${n} <b class="num">${ts.filter(f).length}</b></button>`)}</div>`
  return aside ? html`<section class="soft hero hwide"><div>${body}</div><div class="side2">${aside}</div></section>` : html`<section class="soft hero">${body}</section>`
}
function List({ d, s, name, xs, go, wide, r, cap = wide ? 6 : 3 }) {
  const [all, setAll] = useState(false), more = xs.length > cap && html`<button class="all" onClick=${() => setAll(!all)}>${all ? 'Show fewer' : 'See all'}</button>`
  const rows = html`<div class="grp">${(all ? xs : xs.slice(0, cap)).map(t => html`<${Row} key=${t.id} onClick=${() => go({ ticket: t.id })} tile=${html`<${Tile} d=${d} name=${t.project || t.home}/>`} chip=${html`<${Chip} p=${t.priority}/>`}
    title=${t.title} value=${`${pct(d, t)}%`} pct=${pct(d, t)} note=${ago(t.updated)} two=${wide} cur=${r.ticket === t.id}/>`)}${!xs.length ? html`<p class="empty">Nothing here</p>` : ''}</div>`
  return wide ? html`<section class="soft lane" data-lane=${s}><div class="lhd"><h2>${name}</h2><small class="num">${xs.length}</small>${more}</div>${rows}</section>`
    : html`<div class="lane" data-lane=${s}><div class="lh"><h2>${name}</h2><small class="num">${xs.length}</small>${more}</div><div class="soft">${rows}</div></div>`
}
function ByProject({ d, ts, go }) {
  const ps = Object.entries(ts.reduce((m, t) => ((m[proj(d, t)] ||= []).push(t), m), {})).map(([p, xs]) => [p, xs.length, xs.filter(t => t.state === 'done').length]).sort((a, b) => (b[1] - b[2]) - (a[1] - a[2]) || b[1] - a[1])
  return html`<section class="soft"><div class="lhd"><h2>By project</h2><small class="num">${ps.length}</small></div><div class="grp">${ps.slice(0, 8).map(([p, n, k]) =>
    html`<${Row} key=${p} onClick=${() => go({ project: [p] })} tile=${html`<${Tile} d=${d} name=${p}/>`} title=${p} value=${`${k} of ${n}`} pct=${Math.round(100 * k / n)} note=${`${Math.round(100 * k / n)}%`}/>`)}</div></section>`
}
const Tiles = ({ d }) => html`<div class="stats"><a class="soft stat" href="#/needs">${I(LIC.q, 20)}<span>Waiting on you</span><b class="num">${d.asks == null ? '?' : d.asks.length}<small>${d.asks?.length === 1 ? 'question' : 'questions'}</small></b></a>
  <div class="soft stat" title=${`The median, over ${d.cycle_n ?? 'the'} recorded merges, of each one's time from the task's last dispatch to the merge`}>${I(LIC.glass, 20)}<span>Typical start to landed</span><b class="num">${d.cycle_p50 == null ? '–' : dur(d.cycle_p50)}</b></div></div>`
// The filters, in one sheet: project, release and whether the list goes by state or by release.
export function TicketFilter({ d, r, go, label }) {
  const all = d.tickets || [], [open, setOpen] = useState(false), n = r.project.length + r.release.length + !!r.by
  const opts = (k, vs) => vs.map(([v, name, c]) => html`<button class="opt" aria-pressed=${k === 'by' ? r.by === v : r[k].includes(v)} onClick=${() => go({ [k]: k === 'by' ? v : r[k].includes(v) ? r[k].filter(x => x !== v) : [...r[k], v] })}><span class="ck">${(k === 'by' ? r.by === v : r[k].includes(v)) ? I(IC.check, 11) : ''}</span><span class="lt">${name}</span>${c != null ? html`<small class="num">${c}</small>` : ''}</button>`)
  return html`<div class="anchor"><button class=${label ? 'btn' : 'ib'} aria-expanded=${open} aria-label="Filters" onClick=${() => setOpen(!open)}>${I(IC.filter, label ? 16 : 20)}${label}${n ? html`<b>${n}</b>` : ''}</button>
    ${open && html`<div class="scrim" onClick=${() => setOpen(false)}></div><div class="pop"><div class="pop-h">List</div>${opts('by', [['', 'By state'], ['release', 'By release']])}
      <div class="pop-h">Release</div>${opts('release', [...new Set(all.map(rel))].sort((a, b) => relRank(a) - relRank(b) || nat(a, b)).map(v => [v, cap(v), all.filter(t => rel(t) === v).length]))}
      <div class="pop-h">Project</div>${opts('project', [...new Set(all.map(t => proj(d, t)))].sort().map(p => [p, p, all.filter(t => proj(d, t) === p).length]))}</div>`}</div>`
}

export function Tickets({ d, r, go, wide }) {
  const all = d.tickets || [], unread = d.tickets_unread || [], lane = laneOf(all.filter(t => t.state !== 'done')), ts = mine(d, all, r), show = SHOW[r.show] ? r.show : 'moving'
  const lists = r.by ? LANES.map(([s, name]) => [s, name, order(s, ts.filter(t => t.state !== 'done' && lane(t) === s))]) : [[show, SHOW[show][0], order(show, ts.filter(SHOW[show][1]))]]
  const page = r.ticket && all.find(t => t.id === r.ticket)
  const body = lists.map(([s, name, xs]) => html`<${List} key=${s} d=${d} s=${s} name=${name} xs=${xs} go=${go} wide=${wide} r=${r}/>`)
  return html`<div class=${'tks' + (wide ? ' wide' : '')}>${unread.length ? html`<p class="sum"><span class="bad">Backlog not read: ${unread.map(h => hname(d, h)).join(', ')}</span></p>` : ''}
    ${wide ? html`<${Hero} ts=${ts} r=${r} go=${go} aside=${html`<${Tiles} d=${d}/>`}/><div class="kgrid"><div class="k8" style="display:flex;flex-direction:column;gap:16px">${body}</div><div class="k4"><${ByProject} d=${d} ts=${ts} go=${go}/></div></div>`
      : html`<${KindSeg} d=${d} r=${r} go=${go} counts/><div style="margin-top:16px"><${Hero} ts=${ts} r=${r} go=${go}/></div>${body}<${Tiles} d=${d}/>`}
    ${page ? html`<${TicketPage} d=${d} t=${page} go=${go}/>` : ''}</div>`
}
