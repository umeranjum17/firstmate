// Tickets: every backlog item across the homes on one Jira-like board - To do, In progress, In review, Waiting on
// captain, Done, On hold - filtered by project and release, or the open items in release lanes (Next release, After,
// Later); a phone shows one column at a time. Waiting on captain is the ask list
// and nothing else, so its count is the Needs you count everywhere. A card opens the ticket page: its description, the
// captain's words it serves, its fields and its thread: the captain's comments with the lead's answers and, for a live
// lane, the lane's status lines.
import { html, useState, useEffect, useRef, now, dur, hm, prNum, toCol, hc, hname, I, IC, ASK_TAG, askType, askOrder } from './ui.js'
import { squash, Entry } from './board.js'

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

const open = (go, id) => e => { if (e.type === 'click' || e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go({ ticket: id }) } }
function Ticket({ d, t, go }) {
  const n = prNum(t.pr)
  return html`<article class="card tk" role="button" tabindex="0" onClick=${open(go, t.id)} onKeyDown=${e => e.target === e.currentTarget && open(go, t.id)(e)}>
    <div class="r1"><span class="id">${t.project || 'No project'}</span><span class="num age" title="Last update">${ago(t.updated)}</span>
      <span class="sq" style=${{ '--c': hc(d, t.home) }} title=${`Owner: ${hname(d, t.home)}`}></span></div>
    <h3>${t.title}</h3>
    <div class="r3">${t.priority != null ? html`<span class=${'pill prio p' + t.priority} title=${PRIO[t.priority] || ''}>P${t.priority}</span>` : ''}
      ${t.asked ? html`<span class="pill asked">Your ask</span>` : ''}<span class="pill" title="Target release">${I(IC_RELEASE, 11)}${cap(t.release)}</span>
      ${n ? html`<a class="pill pr" href=${t.pr} target="_blank" rel="noreferrer" onClick=${e => e.stopPropagation()}>${I(IC.pr, 12)}${n}</a>` : ''}</div></article>`
}

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
const Ask = ({ a }) => html`<article class="card tk ask"><div class="r1"><span class="id">${ASK_TAG[askType(a.text, a.type)]}</span>${a.age != null ? html`<span class="num age">${dur(a.age)}</span>` : ''}</div>
  <h3>${a.text}</h3>${a.url ? html`<div class="r3"><a class="pill" href=${a.url} target="_blank" rel="noreferrer">Open</a></div>` : ''}</article>`

function Col({ d, s, name, xs, asks, n, go }) {
  const [all, setAll] = useState(false)
  return html`<section class=${'col tkc' + (s === 'captain' ? ' you' : '')}><header class="ch"><b>${name}</b><span class="n num">${n}</span></header>
    ${asks ? asks.map(a => html`<${Ask} key=${a.id} a=${a}/>`) : (all ? xs : xs.slice(0, CAP)).map(t => html`<${Ticket} key=${t.id} d=${d} t=${t} go=${go}/>`)}
    ${!asks && xs.length > CAP && !all ? html`<button class="more" onClick=${() => setAll(true)}>${xs.length - CAP} more</button>` : ''}
    ${n === '?' ? html`<p class="empty">The ask list could not be read</p>` : !n ? html`<p class="empty">Nothing here</p>` : ''}</section>`
}

export function Tickets({ d, r, go, wide }) {
  const all = d.tickets || [], unread = d.tickets_unread || [], lane = laneOf(all.filter(t => t.state !== 'done'))
  const ts = all.filter(t => (!r.project.length || r.project.includes(t.project || 'none')) && (!r.release.length || r.release.includes(rel(t))))
  const projects = [...new Set(all.map(t => t.project || 'none'))].sort((a, b) => (a === 'none') - (b === 'none') || a.localeCompare(b))
  const releases = [...new Set(all.map(rel))].sort((a, b) => relRank(a) - relRank(b) || nat(a, b))
  const cols = r.by ? LANES.map(([s, name]) => { const xs = order(s, ts.filter(t => t.state !== 'done' && lane(t) === s)); return { s, name, xs, n: xs.length } })
    : COLS.map(([s, name]) => { const xs = s === 'captain' ? [] : order(s, ts.filter(t => t.state === s)), asks = s === 'captain' ? askOrder(d.asks || []) : null
      return { s, name, xs, asks, n: !asks ? xs.length : d.asks == null ? '?' : asks.length } })
  const page = r.ticket && all.find(t => t.id === r.ticket)
  const start = r.by ? 0 : COLS.findIndex(([s]) => s === 'captain'), [i, setI] = useState(start), ref = useRef()
  useEffect(() => { setI(start); if (!wide) toCol(ref.current, start) }, [wide, r.by])
  useEffect(() => { if (!wide) document.querySelector('.mseg [aria-selected=true]')?.scrollIntoView({ inline: 'center', block: 'nearest' }) }, [i, wide])
  const jump = k => { setI(k); toCol(ref.current, k, 'smooth') }
  const onScroll = () => { const el = ref.current; if (el) { const k = Math.round(el.scrollLeft / el.clientWidth); if (k !== i) setI(k) } }
  return html`<div class="tks">
    <div class="seg tkp" role="group" aria-label="Project">${[['', 'All projects', all.length], ...projects.map(p => [p, p === 'none' ? 'No project' : p, all.filter(t => (t.project || 'none') === p).length])]
      .map(([v, n, k]) => html`<button aria-pressed=${v ? r.project.length === 1 && r.project[0] === v : !r.project.length} onClick=${() => go({ project: v ? [v] : [] })}>${n}<small class="num">${k}</small></button>`)}</div>
    <div class="seg tkp"><span class="seg" role="group" aria-label="Columns">${[['', 'By state'], ['release', 'By release']].map(([v, n]) =>
      html`<button aria-pressed=${r.by === v} onClick=${() => go({ by: v })}>${n}</button>`)}</span><span class="seg" role="group" aria-label="Release">${[['', 'All releases', all.length], ...releases.map(v => [v, cap(v), all.filter(t => rel(t) === v).length])]
      .map(([v, n, k]) => html`<button aria-pressed=${v ? r.release.length === 1 && r.release[0] === v : !r.release.length} onClick=${() => go({ release: v ? [v] : [] })}>${n}<small class="num">${k}</small></button>`)}</span></div>
    ${unread.length ? html`<p class="sum"><span class="bad">Backlog not read: ${unread.map(h => hname(d, h)).join(', ')}</span></p>` : ''}
    ${wide ? '' : html`<div class="mseg" role="tablist">${cols.map((c, k) => html`<button role="tab" aria-selected=${i === k} onClick=${() => jump(k)}>${c.name}<small class="num">${c.n}</small></button>`)}</div>`}
    <div class=${wide ? 'tkb' : 'mcols'} ref=${ref} onScroll=${wide ? null : onScroll}>${cols.map(c => html`<${Col} key=${c.s} d=${d} go=${go} ...${c}/>`)}</div>
    ${page ? html`<${TicketPage} d=${d} t=${page} go=${go}/>` : ''}</div>`
}
