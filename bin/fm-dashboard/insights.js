// Native SVG over the shipped durable-record reader. Missing observations never become zero.
import { html, useState, hname } from './ui.js'
const DAY = 86400, number = n => n == null ? 'Unknown' : n.toLocaleString('en-US', { maximumFractionDigits: 12 })
const seconds = n => n == null ? 'Unknown' : `${number(n)} s`
const bytes = n => n == null ? 'Unknown' : `≈${(n / 2 ** 30).toFixed(2)} GiB`
const CAUSES = { captain: 'Your decision', lead: 'Lead reply', ci_queue: 'CI queue', memory_gate: 'Memory limit', credential_external: 'Login or external wait', review_merge: 'Review or merge', unknown: 'Unclassified' }
const STAGES = { working: 'Working', resolved: 'Working', blocked: 'Blocked', failed: 'Failed', paused: 'Waiting', 'needs-decision': 'Decision needed', 'captain-held': 'Held', done: 'Finished' }
const summary = rows => {
  const xs = rows.map(l => l.durations.time_to_merge).filter(v => v != null).sort((a, b) => a - b), n = xs.length
  return { known: n, unknown: rows.length - n, median_seconds: n ? (xs[Math.floor((n - 1) / 2)] + xs[Math.floor(n / 2)]) / 2 : null,
    p85_seconds: n ? xs[Math.ceil(.85 * n) - 1] : null }
}
const Card = ({ label, value, note, title }) => html`<div class="i-stat" title=${title}><span>${label}</span><b>${value}</b><small>${note}</small></div>`
const Rows = ({ title, children }) => html`<details class="i-panel"><summary>${title}</summary><div class="i-rows">${children}</div></details>`
const Row = ({ name, value, note, title }) => html`<div class="i-row" title=${title}><span>${name}${note && html`<small>${note}</small>`}</span><b>${value}</b></div>`
function Trend({ days }) {
  const max = Math.max(...days.flatMap(d => [d.median_seconds || 0, d.p85_seconds || 0]), 1)
  const y = v => 110 - v / max * 95, x = i => 68 + i * 85
  return html`<section class="i-panel"><h2>Time to merge · seven UTC days</h2><div class="i-key"><span>P50</span><span>P85</span><small>Seconds · gaps are unknown</small></div>
    <svg class="i-trend" viewBox="0 0 600 140" role="img" aria-label="Recorded median and P85 time to merge by UTC day">
      ${(days.some(d => d.known > 0) ? [0, max / 2, max] : []).map(v => html`<line x1="68" x2="578" y1=${y(v)} y2=${y(v)} stroke="var(--line)"/><text x="60" y=${y(v) + 4} text-anchor="end">${number(v)}</text>`)}
      ${['median_seconds', 'p85_seconds'].map((key, k) => html`<g class=${'i-series i-series-' + k}>
        <path d=${days.map((d, i) => d[key] == null ? '' : `${i && days[i - 1][key] != null ? 'L' : 'M'}${x(i)},${y(d[key])}`).join(' ')} fill="none"/>
        ${days.map((d, i) => d[key] == null ? '' : html`<circle cx=${x(i)} cy=${y(d[key])} r="3"><title>${d.day} ${k ? 'P85' : 'P50'}: ${seconds(d[key])}; ${d.known} timed, ${d.unknown} unknown</title></circle>`)}</g>`)}
      ${days.every(d => d.known === 0) ? html`<text x="320" y="60" text-anchor="middle">No recorded pickup-to-merge durations</text>` : ''}
      ${days.map((d, i) => html`<text x=${x(i)} y="134" text-anchor="middle">${d.day.slice(5)}</text>`)}</svg>
    <div class="i-days">${days.map(d => html`<span title=${`${d.day}: P50 ${seconds(d.median_seconds)}, P85 ${seconds(d.p85_seconds)}`}><b>${d.known + d.unknown}</b><small>${d.day.slice(5)} merged</small></span>`)}</div></section>`
}
function Lifecycle({ lane }) {
  if (!lane) return html`<p class="i-note">Choose a task to see its recorded lifecycle.</p>`
  const t = lane.times, before = lane.durations.pickup_to_working, total = lane.durations.time_to_merge
  const parts = before != null && (total == null || total >= before)
    ? [['Pickup → working', before], ['Working → merge (not split further)', total == null ? null : total - before]] : [['Pickup → merge (not split)', total]]
  const max = parts.reduce((n, [, v]) => n + (v || 0), 0)
  return html`<div class="i-stack" aria-label="Known pickup to merge intervals">${parts.filter(([, v]) => v != null && v > 0).map(([name, v], i) => html`<i class=${'i-series-' + i} style=${{ flex: v / (max || 1) }} title=${`${name}: ${seconds(v)}`}></i>`)}</div>
    <div class="i-rows">${parts.map(([name, v]) => html`<${Row} name=${name} value=${seconds(v)}/>`)}
    ${[['Picked up', 'dispatched'], ['First recorded work', 'working'], ['First commit', 'first_commit'], ['PR opened', 'pr_opened'], ['Checks green', 'checks_green'], ['Merged', 'merged'], ['Cleaned up', 'cleaned_up']].map(([name, key]) => html`<${Row} name=${name} value=${t[key] == null ? 'Unknown' : new Date(t[key] * 1000).toISOString().replace('T', ' ').replace('.000Z', ' UTC')}/>`)}
    <${Row} name="Merge → cleanup" value=${seconds(lane.durations.merge_to_cleanup)}/>
    ${lane.open_waits.map(w => html`<${Row} name=${CAUSES[w.cause]} value=${seconds(w.seconds)} note=${w.display_reason}/>`)}</div><p class="i-note">Unrecorded stage splits and past resolved wait intervals are unknown. Current wait ages overlap; they are not time lost.</p>`
}
export function Insights({ d }) {
  const [home, setHome] = useState(''), [chosen, choose] = useState('')
  const f = d.flow
  if (!f) return html`<div class="ins"><section class="i-panel"><h2>Observations unavailable</h2><p>${d.flow_error || 'No flow observation was collected.'}</p></section></div>`
  const mine = l => !home || l.home === home, lanes = f.lanes.filter(mine), open = lanes.filter(l => l.open), queue = f.queue.filter(mine)
  const merged = f.executed_7d.filter(mine), day = f.executed_24h.filter(mine), timed = home ? f.time_to_merge_by_home[home] : f.time_to_merge
  const title = l => l.display_title || d.cards.find(c => c.home === l.home && c.task === l.task)?.title || 'Task name not recorded'
  const displayWhy = l => l.display_reason || 'Reason not recorded'
  const waiting = open.filter(l => l.open_waits.length), late = open.filter(l => l.stage_clock.overdue === true)
  const ranked = f.bottlenecks.map(b => { const items = b.items.filter(mine), known = items.map(i => i.known_seconds).filter(v => v != null)
    return { ...b, items, age: known.reduce((n, v) => n + v, 0), unknown: items.filter(i => i.seconds == null).length }
  }).filter(b => b.items.length).sort((a, b) => b.age - a.age || a.cause.localeCompare(b.cause))
  const maxWait = Math.max(...ranked.map(b => b.age), 1)
  const days = home ? f.trend_7d.map(t => ({ day: t.day, ...summary(merged.filter(l => new Date(l.times.merged * 1000).toISOString().slice(0, 10) === t.day)) })) : f.trend_7d
  const picks = lanes.map(l => ({ l, key: `${l.home}/${l.task}` })), picked = picks.find(p => p.key === chosen)?.l
  const c = f.capacity, m = c?.memory_bytes, mac = c?.mac, tmp = c?.tmp
  const queueWhy = q => q.why.startsWith('dependency:') ? q.display_why : q.why.startsWith('hold:') ? q.display_why : q.why.startsWith('lane cap:') ? q.display_why : 'Start reason not recorded'
  const groups = ['dependency:', 'hold:', 'lane cap:', 'unknown:'].map((prefix, i) => [ ['Earlier work', 'Held', 'Lane limit', 'Reason unknown'][i], queue.filter(q => q.why.startsWith(prefix)).length ])
  return html`<div class="ins">
    <div class="i-scope"><label>Scope <select aria-label="Insights home" value=${home} onChange=${e => { setHome(e.target.value); choose('') }}><option value="">All registered homes</option>${f.homes.map(h => html`<option value=${h}>${hname(d, h)}</option>`)}</select></label><small>Retained records · ${new Date(f.at * 1000).toISOString().replace('T', ' ').replace('.000Z', ' UTC')}</small></div>
    <div class="i-stats"><${Card} label="Merged · 24 hours" value=${number(day.length)} note="Retained merge outcomes"/><${Card} label="Merged · 7 days" value=${number(merged.length)} note="Retained merge outcomes"/>
      <${Card} label="Time to merge · P50" value=${seconds(timed?.median_seconds)} note=${`${timed?.known ?? 0} timed · ${timed?.unknown ?? merged.length} unknown`}/><${Card} label="Time to merge · P85" value=${seconds(timed?.p85_seconds)} note="Nearest-rank percentile"/>
      <${Card} label="Open · recorded" value=${number(open.length)} note=${`${waiting.length} with waits · ${late.length} past stage clock`}/><${Card} label="Queued · recorded" value=${number(queue.length)} note=${`${groups[0][1]} dependencies · ${groups[1][1]} held`}/></div>
    <section class="i-panel i-waits"><h2>Why work waits now</h2><p class="i-note">Known recorded wait ages · causes overlap, not time lost · not proof of idle workers</p>
      ${ranked.length ? ranked.map(b => html`<div class="i-wait"><span>${CAUSES[b.cause]}</span><b title=${`${seconds(b.age)} known lower bound; ${b.items.length} ${b.items.length === 1 ? 'task' : 'tasks'}; ${b.unknown} unknown durations`}>${b.unknown ? '≥ ' : ''}${seconds(b.age)}</b><div><i style=${{ width: b.age / maxWait * 100 + '%' }}></i></div><small>${b.items.length} ${b.items.length === 1 ? 'task' : 'tasks'}${b.unknown ? ` · ${b.unknown} unknown` : ''}</small></div>`) : html`<p class="i-note">No open waits recorded. Missing sources do not prove that nothing is waiting.</p>`}
    </section>
    <div class="i-grid"><${Trend} days=${days}/><section class="i-panel"><h2>Why queued work has not started</h2>
      ${groups.map(([name, n]) => html`<${Row} name=${name} value=${number(n)}/>`)}<${Rows} title=${`${queue.length} queued ${queue.length === 1 ? 'item' : 'items'} · why-lines`}>${queue.map(q => html`<${Row} name=${title(q)} value=${hname(d, q.home)} note=${queueWhy(q)}/>`)}</${Rows}></section>
      <${Rows} title=${`${open.length} open ${open.length === 1 ? 'task' : 'tasks'} · stage and reason`}>${[...open].sort((a, b) => (b.seconds_in_stage ?? -1) - (a.seconds_in_stage ?? -1)).map(l => html`<${Row} name=${title(l)} value=${seconds(l.seconds_in_stage)} note=${`${hname(d, l.home)} · ${STAGES[l.stage] || 'Stage unknown'} · ${displayWhy(l)}${l.stage_clock.overdue === true ? ' · past recorded stage clock' : ''}`}/>`)}<p class="i-note">Recorded wait or overdue stage is not proof of a stopped worker. Worker availability is unknown.</p></${Rows}>
      <${Rows} title=${`${merged.length} merged ${merged.length === 1 ? 'task' : 'tasks'} · last seven days`}>${merged.map(l => html`<${Row} name=${title(l)} value=${seconds(l.durations.time_to_merge)} note=${hname(d, l.home)}/>`)}${merged.filter(l => l.pr).map(l => html`<a class="i-result" href=${l.pr} target="_blank" rel="noreferrer">${title(l)} · open result</a>`)}</${Rows}>
      <section class="i-panel"><h2>Task lifecycle</h2><label>Task <select aria-label="Lifecycle task" value=${chosen} onChange=${e => choose(e.target.value)}><option value="">Choose a task</option>${picks.map(p => html`<option value=${p.key}>${hname(d, p.l.home)} · ${title(p.l)}</option>`)}</select></label><${Lifecycle} lane=${picked}/></section>
      <section class="i-panel"><h2>Linux and Mac observations</h2><p class="i-note">Whole host, not scoped to a home · observations, not permission to start jobs</p>
        <${Row} name="Linux available memory" value=${bytes(m?.MemAvailable)} title=${`${number(m?.MemAvailable)} bytes (Linux MemAvailable)`}/><${Row} name="Memory pressure · last 10 s" value=${c?.memory_some_avg10_percent == null ? 'Unknown' : `${number(c.memory_some_avg10_percent)}%`}/>
        <${Row} name="Emulators" value=${number(c?.gate_counts.emulator)} note=${`${number(c?.slots_under_caps.emulator)} below cap ${number(c?.limits.FM_EMU_MAX)} · not free workers`}/><${Row} name="Gradle gate matches" value=${number(c?.gate_counts.gradle_gate_match)} note=${`${number(c?.slots_under_caps.gradle_gate_match)} below cap ${number(c?.limits.FM_GRADLE_MAX)}`}/>
        <${Row} name="Heavy-job memory" value=${bytes(c?.heavy_slice.MemoryCurrent)} title=${`${number(c?.heavy_slice.MemoryCurrent)} bytes; limit ${c?.heavy_slice.unlimited ? 'unlimited' : number(c?.heavy_slice.MemoryMax) + ' bytes'}`}/>
        <${Row} name="/tmp filesystem used" value=${bytes(tmp?.filesystem_used_bytes)} note=${tmp?.ram_backed == null ? 'Backing unknown' : tmp.ram_backed ? 'RAM-backed filesystem' : 'Not RAM-backed'} title=${`${number(tmp?.filesystem_used_bytes)} bytes`}/>
        <${Row} name="Mac connection" value=${mac?.reachable === true ? 'Observed' : 'Unknown'}/><${Row} name="Mac VM pages available" value=${bytes(mac?.available_bytes)} note="Free + inactive + speculative · not Linux MemAvailable" title=${`${number(mac?.available_bytes)} bytes`}/>
        <${Row} name="Mac root disk free" value=${bytes(mac?.free_disk_bytes)} title=${`${number(mac?.free_disk_bytes)} bytes`}/><${Row} name="Mac active simulators" value=${number(mac?.simulators?.length)}/><${Row} name="Mac Android emulator processes" value=${number(mac?.android_pids?.length)}/>
        <p class="i-note">Linux observed ${c?.observed_at ? new Date(c.observed_at * 1000).toISOString() : 'Unknown'} · Mac observed ${mac?.observed_at ? new Date(mac.observed_at * 1000).toISOString() : 'Unknown'}</p>
        <${Rows} title=${`${c?.jobs.length ?? 'Unknown'} observed emulator/Gradle processes · memory and recorded owner`}>${c?.jobs.map(j => html`<${Row} name=${({ emulator: 'Emulator', gradle_gate_match: 'Gradle gate match', gradle_daemon: 'Gradle daemon', gradle_client: 'Gradle client' })[j.kind] + ` · process ${j.pid}`} value=${bytes(j.rss_bytes)} title=${`${number(j.rss_bytes)} bytes`} note=${j.owner ? `${hname(d, j.owner.home)} · ${title(j.owner)}` : 'Owner unknown'}/>`)}<p class="i-note">Per-process RSS is not additive host memory. A Gradle daemon is not a build. Ownership requires a recorded folder match. Census ${c?.census_complete === true ? 'complete' : 'unknown or incomplete'}.</p></${Rows}>
        <${Rows} title=${`Observed /tmp folders · ${tmp?.top_folders_complete === true ? 'complete' : 'partial or unknown'}`}>${tmp?.top_folders?.map((p, i) => html`<${Row} name=${p.display_name || `Observed folder ${i + 1}`} value=${p.bytes == null ? `≥ ${bytes(p.known_bytes)}` : bytes(p.bytes)} title=${`${number(p.known_bytes)} readable bytes`} note=${p.bytes == null ? 'Readable lower bound; not a complete size or global rank' : 'Complete directory measurement'}/>`)}</${Rows}>
      </section></div>
    <p class="i-note">${f.limitations.length} coverage notices · retained records only; unavailable homes or sources can be missing from counts. First commit, actual PR-open and checks-green times remain unknown when not recorded. No worker availability, allocation or offload is inferred.</p>
  </div>`
}
