/**
 * T3 Bot demo server: the same HTTP API as server/t3bot.ts, answered from memory. No T3 Code, no config file,
 * no database, no pushes. It is what you point the app at to try it, and what the screenshots are made from.
 *
 *   bun server/demo.ts [--port 8810] [--host 0.0.0.0] [--frozen] [--no-banner]
 *
 * Token: `demo`. State lives in memory and comes back fresh on every start (or POST /v1/demo/reset).
 *
 * Live mode (default): bots that are working step through their activities, post their reply and pick up
 * background work again, so the app looks alive. Time only moves when a request comes in (no timers).
 * The scenario starts over at the first request, so whoever connects sees it from the beginning.
 *
 * --frozen: nothing changes by itself. Timestamps are fixed offsets from the start, working bots stay at the
 * same step, and a write (a message, an answer, a card button) shows its full result at once, so two captures
 * of the same screen match.
 */
import { existsSync, readFileSync } from 'fs'
import { networkInterfaces } from 'os'
import { join } from 'path'
import { answerScript, cardScript, decisionScript, scriptFor, type Script } from './demo-replies'
import { generated } from './demo-png'
import { VERSION } from './config'
import { preview, quickReplies, snippet } from './text'
import { CHIEF, DEFAULT_ACTIONS, USER, seed, type Action, type Bot, type Card, type Entry, type EntryImage, type Run, type Settings, type World } from './demo-world'

const ROOT = join(import.meta.dir, '..')
const AVATARS = join(ROOT, 'avatars')
const ASSETS = join(import.meta.dir, 'demo-assets')
const TOKEN = 'demo'

const args = process.argv.slice(2)
const flag = (name: string) => args.includes(`--${name}`)
const option = (name: string) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : undefined }
const PORT = Number(option('port') ?? process.env.T3BOT_DEMO_PORT ?? 8810)
const HOST = option('host') ?? '0.0.0.0'
const FROZEN = flag('frozen')

// The same answers as the real server for a request it would refuse.
class BadRequest extends Error {}
const HEX = /^[0-9a-f]{32,400}$/i

// ---------- skins ----------

type Skin = { n: string; title: string; series: string; color: string; smooth: boolean }
/** The skins the demo bots wear, in case tools/faces/skins.json is not there. */
const BUILT_IN: Skin[] = [
  { n: '902', title: 'Titanium Gold', series: 'Metal', color: '#d4a446', smooth: true },
  { n: '102', title: 'Blue', series: 'Glaze', color: '#2c98e2', smooth: true },
  { n: '103', title: 'Jade', series: 'Glaze', color: '#40c49b', smooth: true },
  { n: '304', title: 'Purple', series: 'Gummy', color: '#b561ff', smooth: true },
  { n: '305', title: 'Pink', series: 'Gummy', color: '#ff61b0', smooth: true },
  { n: '306', title: 'Orange', series: 'Gummy', color: '#ffa159', smooth: true },
  { n: '706', title: 'Aurora', series: 'Gradient', color: '#92c9f1', smooth: true },
  { n: '806', title: 'Ink', series: 'Frosted glass', color: '#7e97a8', smooth: true },
  { n: '303', title: 'Lime', series: 'Gummy', color: '#92ec55', smooth: true },
  { n: '311', title: 'Yellow', series: 'Gummy', color: '#ffd642', smooth: true },
  { n: '1005', title: 'Ruby', series: 'Gems', color: '#d0243f', smooth: true },
  { n: '912', title: 'Ultramarine', series: 'Metal', color: '#8ea0ff', smooth: true },
]
const SKINS: Skin[] = (() => {
  try {
    const list = (JSON.parse(readFileSync(join(ROOT, 'tools/faces/skins.json'), 'utf8')) as Skin[]).filter((s) => s.smooth)
    if (list.length) return list
  } catch {}
  return BUILT_IN
})()
const skin = (n: string) => SKINS.find((s) => s.n === n) ?? BUILT_IN.find((s) => s.n === n)
const isSkin = (n: string) => !!skin(n)

function hue(color: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(color.slice(i, i + 2), 16) / 255)
  const max = Math.max(r, g, b), min = Math.min(r, g, b)
  if (max === min) return 0
  const d = max - min
  return ((max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60) % 360
}
/** A skin nobody wears, as far in hue from the others as it gets. */
function freeSkin(): string {
  const used = new Set(world.bots.map((b) => b.skin))
  const hues = [...used].map((n) => hue(skin(n)?.color ?? '#888888'))
  const far = (h: number) => Math.min(...hues.map((u) => Math.min(Math.abs(h - u), 360 - Math.abs(h - u))), 360)
  return SKINS.filter((s) => !used.has(s.n)).sort((a, b) => far(hue(b.color)) - far(hue(a.color)))[0]?.n ?? SKINS[0].n
}

// ---------- state and time ----------

let world: World = seed(Date.now())
let started = false
const iso = (ms: number) => new Date(ms).toISOString()
/** The moment state is judged at: the real clock, or the start when frozen. */
const clock = () => (FROZEN ? world.base : Date.now())
const botById = (id: string) => world.bots.find((b) => b.id === id)
const nextId = (prefix: string) => `${prefix}-${++world.seq}`
const log = (m: string, x?: unknown) => console.log(new Date().toISOString(), m, x === undefined ? '' : JSON.stringify(x))

function splitSuggestions(text: string): { text: string; suggestions?: string[] } {
  const lines = text.trimEnd().split('\n')
  const last = lines[lines.length - 1] ?? ''
  if (!last.startsWith('» ')) return { text }
  const suggestions = last.slice(2).split(' · ').map((s) => s.trim()).filter((s) => s && s.length <= 60).slice(0, 4)
  return { text: lines.slice(0, -1).join('\n').trimEnd(), suggestions: suggestions.length ? suggestions : undefined }
}

// ---------- runs (a bot working on something) ----------

/** Where a run stands at `now`: the steps it finished, what it is doing, and whether it is over. */
function runState(run: Run, now: number) {
  const elapsed = (now - run.startedAt) / 1000
  const limit = run.askAfter ?? run.phases.length
  const steps: string[] = []
  let t = 0
  for (let i = 0; i < limit; i++) {
    const p = run.phases[i]
    if (elapsed < t + p.secs) return { steps, activity: p.activity, done: false, asking: false }
    t += p.secs
    steps.push(p.step)
  }
  if (run.askAfter !== undefined) return { steps, activity: 'asking', done: false, asking: true }
  return { steps, activity: null as string | null, done: true, asking: false }
}

const runLength = (run: Run) => run.phases.reduce((n, p) => n + p.secs, 0) * 1000

/** Post the run's reply and free the bot. */
function finish(b: Bot, at: number) {
  const run = b.run
  if (!run) return
  const split = splitSuggestions(run.reply)
  b.entries.push({
    id: run.workingId, type: 'agent', text: split.text, at: iso(at), steps: run.phases.map((p) => p.step),
    suggestions: run.auto ? undefined : split.suggestions, auto: !!run.auto, images: run.images,
  })
  if (b.entries.length > 200) b.entries.splice(0, b.entries.length - 200)
  b.run = null
  b.ambientAt = at + 25e3
  if (run.resolves) removeCard(run.resolves)
}

/** Start a turn. Frozen mode shows the whole result at once, live mode walks through the phases. */
function startRun(b: Bot, script: Script, more: Partial<Run> = {}) {
  const now = Date.now()
  if (b.run) {
    // A new turn takes over: a run that was waiting on an answer is dropped, any other one posts its reply first.
    if (runState(b.run, clock()).asking) b.run = null
    else finish(b, now - 1)
  }
  b.failed = false
  b.run = { startedAt: now, at: iso(now + 1), workingId: nextId('m'), phases: script.phases, reply: script.reply, images: script.images, ...more }
  if (FROZEN) finish(b, now + 2)
}

/** Sam's own bubble in a chat. */
function say(b: Bot, text: string, images?: EntryImage[]) {
  b.entries.push({ id: nextId('m'), type: 'me', text, at: iso(Date.now()), steps: [], images: images?.length ? images : undefined })
  b.sent++
}

/** Move the world forward to now (live mode only): finish runs that are over, start background work. */
function advance() {
  if (FROZEN) return
  const now = Date.now()
  for (const b of world.bots) {
    if (b.run) {
      if (runState(b.run, now).done) finish(b, Math.min(now, b.run.startedAt + runLength(b.run)))
    } else if (b.ambient.length && now >= b.ambientAt && !b.hidden) {
      const job = b.ambient[b.ambientIndex++ % b.ambient.length]
      b.entries.push({ id: nextId('m'), type: 'auto', text: job.prompt, at: iso(now), steps: [] })
      b.run = { startedAt: now, at: iso(now + 1), workingId: nextId('m'), phases: job.phases, reply: job.reply, auto: true }
    }
  }
  for (const [id, until] of world.snoozed) if (until <= now) world.snoozed.delete(id)
}

// ---------- cards ----------

function needs(): Card[] {
  const now = clock()
  return world.cards
    .filter((c) => !((world.snoozed.get(c.id) ?? 0) > now))
    .sort((a, b) => a.rank - b.rank || (b.customer ? 1 : 0) - (a.customer ? 1 : 0) || a.at.localeCompare(b.at))
}

function removeCard(id: string) {
  const i = world.cards.findIndex((c) => c.id === id)
  if (i < 0) return
  world.removed.set(id, world.cards[i])
  world.cards.splice(i, 1)
  world.snoozed.delete(id)
}

/** The next end of quiet hours (the "tomorrow morning" of snoozes). */
function morning(): number {
  const [h, m] = (world.settings.quiet.to || '08:00').split(':').map(Number)
  const d = new Date(); d.setHours(h, m, 0, 0)
  if (d.getTime() <= Date.now()) d.setDate(d.getDate() + 1)
  return d.getTime()
}

function cardAction(id: string, action: string, body: any): { ok: boolean; error?: string; agent?: string } {
  const card = world.cards.find((c) => c.id === id)
  if (!card) return { ok: false, error: 'card not found' }
  if (action === 'snooze') {
    const asked = body?.until ? new Date(String(body.until)).getTime() : NaN
    world.snoozed.set(id, asked > Date.now() + 60e3 ? asked : morning())
    return { ok: true }
  }
  if (action === 'done') {
    if (card.source === 'question') return { ok: false, error: 'answer the question instead' }
    removeCard(id)
    return { ok: true }
  }
  if (action === 'handle') {
    const b = botById(card.agent) ?? botById(CHIEF)!
    if (card.source === 'question') {
      say(b, `Help me with this question: "${card.title}"`)
      startRun(b, { phases: [{ activity: 'thinking', step: 'Read the question again', secs: 2 }], reply: `It is still open: "${card.title}". Answer it on the card and I carry on from there.\n\n» Ok` })
      return { ok: true, agent: b.id }
    }
    say(b, (body?.text ? `${body.text}\n\n` : '') + `Handle this for me: "${card.title}"`)
    startRun(b, cardScript(b, card.title, 'Handle it'), { resolves: id })
    return { ok: true, agent: b.id }
  }
  return { ok: false, error: `unknown action ${action}` }
}

/** Any button on a card. `text` is the card's edited text, when it has one. */
function act(id: string, actionId: string, body: any): { ok: boolean; error?: string; agent?: string; message?: string } {
  const card = world.cards.find((c) => c.id === id)
  if (!card) return { ok: false, error: 'card not found' }
  const a: Action = (card.actions ?? []).find((x) => x.id === actionId) ?? { id: actionId, label: actionId, kind: actionId as Action['kind'] }
  if (a.kind === 'done' || a.kind === 'snooze' || a.kind === 'handle') {
    const extra = a.kind === 'handle' && body?.text && card.edit ? `Use this text as I edited it:\n${body.text}` : undefined
    return cardAction(id, a.kind, { ...body, text: extra })
  }
  if (a.kind === 'message') {
    const b = botById(card.agent) ?? botById(CHIEF)!
    const edited = body?.text !== undefined && card.edit ? String(body.text) : undefined
    say(b, `${a.label}: "${card.title}"` + (edited !== undefined ? `\n\n${card.edit!.label}:\n${edited}` : ''))
    if (card.source === 'note') removeCard(id)
    startRun(b, cardScript(b, card.title, a.label, edited), card.source === 'note' ? {} : { resolves: id })
    return { ok: true, agent: b.id }
  }
  if (a.kind === 'command') return { ok: true, message: `Demo: the handler "${a.handler ?? a.id}" would run here.` }
  return { ok: false, error: `unknown action ${actionId}` }
}

/** A note from an agent (`t3bot notify`): a card on the list, or a line in the evening digest. */
function addNote(n: any): { id: string; agent: string; kind: string } {
  const kind = String(n.kind ?? 'know')
  if (!['alarm', 'approve', 'do', 'know', 'draft'].includes(kind)) throw new BadRequest('kind must be alarm, approve, do, know or draft')
  if (!n.title) throw new BadRequest('title is required')
  const agent = botById(String(n.agent ?? '')) ? String(n.agent) : CHIEF
  const id = n.key ? `${agent}:${n.key}` : crypto.randomUUID()
  const at = iso(Date.now())
  if (kind === 'know') {
    world.notes = world.notes.filter((x) => x.id !== id)
    world.notes.push({ id, agent, kind, title: String(n.title), body: n.body ? String(n.body) : null, created_at: at, link: n.link ? String(n.link) : null, key: n.key ? String(n.key) : null })
    return { id, agent, kind }
  }
  const actions: Action[] | undefined = kind === 'draft' ? undefined
    : Array.isArray(n.actions) && n.actions.length
      ? [...n.actions.map((a: any, i: number): Action => ({
        id: String(a.id ?? `a${i}`), label: String(a.label), kind: a.handler ? 'command' : 'message', style: i === 0 ? 'primary' : 'plain',
        faceId: !!(a.faceId ?? n.faceId), message: a.message ? String(a.message) : undefined, handler: a.handler ? String(a.handler) : undefined,
      })), { id: 'done', label: 'Done', kind: 'done' }, { id: 'snooze', label: 'Not now', kind: 'snooze' }]
      : DEFAULT_ACTIONS(!!n.faceId)
  const card: Card = {
    id: `note:${id}`, source: 'note', agent, rank: kind === 'alarm' ? 0 : kind === 'do' ? 2 : 1,
    title: String(n.title), detail: n.body ? String(n.body) : undefined, at, kind, link: n.link ? String(n.link) : undefined, key: n.key ? String(n.key) : undefined,
    draft: kind === 'draft' ? (n.draft ?? {}) : undefined,
    fields: kind !== 'draft' && Array.isArray(n.fields) ? n.fields : undefined,
    checks: kind !== 'draft' && Array.isArray(n.checks) ? n.checks : undefined,
    edit: kind !== 'draft' && n.edit?.text !== undefined ? { label: String(n.edit.label ?? 'Text'), text: String(n.edit.text) } : undefined,
    actions,
  }
  world.cards = world.cards.filter((c) => c.id !== card.id)
  world.removed.delete(card.id)
  world.snoozed.delete(card.id)
  world.cards.push(card)
  return { id, agent, kind }
}

// ---------- agents ----------

const WATCH_CYCLE = ['reading', 'thinking', 'writing', 'running']

function agentSummary(b: Bot, list: Card[]) {
  const now = clock()
  const mine = list.filter((c) => c.agent === b.id)
  const state = b.run ? runState(b.run, now) : null
  const ownWorking = !!b.run
  const watching = b.watching.length > 0
  const waiting = mine.some((c) => c.source === 'question' || c.rank <= 1)
  const askingNow = ownWorking && mine.some((c) => c.source === 'question' && c.threadId === b.threadId)
  const mood = askingNow ? 'waiting' : ownWorking ? 'working' : waiting ? 'waiting' : watching ? 'watching' : b.failed ? 'failed' : 'asleep'
  const activity = ownWorking ? state!.activity ?? 'thinking'
    : watching ? WATCH_CYCLE[FROZEN ? 0 : Math.floor((now - world.base) / 9000) % WATCH_CYCLE.length] : null
  const talk = b.entries.filter((e) => e.type === 'me' || (e.type === 'agent' && !e.auto))
  const last = talk[talk.length - 1]
  const lastReply = [...b.entries].reverse().find((e) => e.type === 'agent')
  return {
    id: b.id, name: b.name, role: b.role, avatar: `/v1/avatars/${b.id}.png?v=${b.skin}`, threadId: b.threadId,
    kind: b.kind, face: { skin: b.skin }, hidden: b.hidden, members: b.members,
    color: skin(b.skin)?.color ?? null,
    threadTitle: b.threadTitle, t3Link: null as string | null,
    status: waiting ? 'waiting' : ownWorking || watching ? 'working' : 'idle', mood, activity, lastReplyAt: lastReply?.at ?? null, needs: mine.length,
    // As the real server: a message that was only a photo reads "Photo".
    last: last ? { text: preview(last.text, 160, last.images?.length ?? 0), at: last.at, from: last.type === 'me' ? 'me' : 'agent' } : null,
    watching: b.watching,
  }
}

function home() {
  const list = needs()
  const now = clock()
  return {
    agents: world.bots.map((b) => agentSummary(b, list)),
    chief: CHIEF,
    user: USER,
    t3: { ok: true },
    phoneShared: !!world.phone,
    needs: list,
    badge: list.filter((c) => c.rank <= 1).length,
    doneToday: world.notes.filter((n) => Date.parse(n.created_at) > now - 24 * 3600e3).length,
    generatedAt: iso(now),
  }
}

function timeline(b: Bot) {
  const list = needs()
  const entries: Entry[] = [...b.entries]
  if (b.run) entries.push({ id: b.run.workingId, type: 'agent', text: '', at: b.run.at, steps: runState(b.run, clock()).steps, working: true, auto: !!b.run.auto })
  // As the real server: under the last answer, the bot's own suggestions, else the person's saved replies when it asks something.
  const tail = entries[entries.length - 1]
  if (tail && tail.type === 'agent' && !tail.working) entries[entries.length - 1] = { ...tail, suggestions: quickReplies(tail.text, tail.suggestions, world.settings.quickReplies) }
  return {
    agent: agentSummary(b, list),
    routines: b.routines,
    entries: entries.slice(-60),
    working: !!b.run,
    cards: list.filter((c) => c.agent === b.id),
    runs: b.runs,
    members: b.kind === 'group' ? b.members.map(botById).filter((m): m is Bot => !!m).map((m) => agentSummary(m, list)) : [],
  }
}

const slug = (name: string) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 24) || 'bot'

/** What a group's line says until someone writes another: who is in it. */
const groupRole = (members: string[]) => `Group: ${members.map((m) => botById(m)?.name ?? m).join(', ')}`.slice(0, 140)

function editAgent(id: string, body: any) {
  const b = botById(id)
  if (!b) return { ok: false, error: 'no such bot' }
  if (typeof body.hidden === 'boolean' && id === CHIEF && body.hidden) return { ok: false, error: 'the Chief stays visible' }
  // As the real server: checked before anything changes, so a refused edit leaves the group as it was.
  const members: string[] | null = Array.isArray(body.members) && b.kind === 'group'
    ? [...new Set<string>(body.members.filter((m: unknown): m is string => typeof m === 'string' && m !== id && !!botById(m) && botById(m)!.kind !== 'group'))]
    : null
  if (members && members.length < 2) return { ok: false, error: 'a group needs at least two bots' }
  const listed = b.kind === 'group' && b.role === groupRole(b.members)
  const roleBefore = b.role
  if (typeof body.name === 'string' && body.name.trim()) {
    b.name = body.name.trim().slice(0, 40)
    b.threadTitle = b.kind === 'group' ? `%BOT Group: ${b.name}` : `%BOT ${b.name}`
  }
  if (typeof body.role === 'string' && body.role.trim()) b.role = body.role.trim().slice(0, 140)
  if (typeof body.hidden === 'boolean') b.hidden = body.hidden
  if (body.face && isSkin(String(body.face.skin))) b.skin = String(body.face.skin)
  if (members) {
    b.members = members
    if (listed && b.role === roleBefore) b.role = groupRole(members)
  }
  let told = false
  if (typeof body.job === 'string' && body.job.trim()) {
    // The real server tells the bot its new job in its thread; here it shows as an automatic update.
    const now = Date.now()
    b.entries.push({ id: nextId('m'), type: 'auto', text: `Your job from now on: "${body.job.trim()}"`, at: iso(now), steps: [] })
    b.entries.push({ id: nextId('m'), type: 'agent', text: 'Understood. I updated my instructions and will work that way from now on.', at: iso(now + 1), steps: ['Updated my instructions'], auto: true })
    told = true
  }
  return { ok: true, told }
}

function newAgent(body: any) {
  const kind = body.kind === 'group' ? 'group' : 'bot'
  const name = String(body.name ?? '').trim().slice(0, 40)
  if (!name) return { ok: false, error: 'a name is required' }
  let id = slug(name)
  while (botById(id)) id = `${id}-2`
  const members: string[] = kind === 'group' ? (Array.isArray(body.members) ? body.members : []).filter((m: string) => botById(m) && botById(m)!.kind !== 'group') : []
  if (kind === 'group' && members.length < 2) return { ok: false, error: 'a group needs at least two bots' }
  const job = String(body.job ?? '').trim()
  const b: Bot = {
    id, name, kind, hidden: false, members,
    role: job ? job.slice(0, 140) : kind === 'group' ? groupRole(members) : 'New bot',
    skin: body.face && isSkin(String(body.face.skin)) ? String(body.face.skin) : freeSkin(),
    threadId: `demo-thread-${id}`, threadTitle: kind === 'group' ? `%BOT Group: ${name}` : `%BOT ${name}`,
    watching: [], failed: false, entries: [], routines: [], runs: [], run: null,
    ambient: [], ambientIndex: 0, ambientAt: 0, sent: 0,
  }
  world.bots.push(b)
  const hello = kind === 'group'
    ? `The group is ready: ${members.map((m) => botById(m)!.name).join(', ')}. Ask something and each of us answers for its part.\n\n» Where do we stand? · Plan the week`
    : `Ready. I am ${name}${job ? `, and my job is: ${job}` : ''}. Tell me what to start with.\n\n» What can you do? · Start now`
  startRun(b, { phases: [{ activity: 'reading', step: 'Read the house rules', secs: 2 }, { activity: 'writing', step: 'Wrote my own instructions', secs: 2 }], reply: hello })
  return { ok: true, id }
}

// ---------- uploads and pictures ----------

function saveImages(images: any[]): EntryImage[] {
  return images.slice(0, 6).map((b64: any) => {
    const bytes = new Uint8Array(Buffer.from(String(b64), 'base64'))
    const png = bytes[0] === 0x89
    const path = `/demo/uploads/${nextId('photo')}.${png ? 'png' : 'jpg'}`
    world.uploads.set(path, { bytes, type: png ? 'image/png' : 'image/jpeg' })
    // Photos only live in memory: keep the last 24.
    while (world.uploads.size > 24) world.uploads.delete(world.uploads.keys().next().value!)
    return { path, alt: '' }
  })
}

function picture(path: string): Response | null {
  const headers = { 'cache-control': 'private, max-age=86400' }
  const up = world.uploads.get(path)
  if (up) return new Response(up.bytes, { headers: { ...headers, 'content-type': up.type } })
  const m = path.match(/^\/demo\/assets\/([a-z0-9-]+\.png)$/)
  if (!m) return null
  const file = join(ASSETS, m[1])
  if (existsSync(file)) return new Response(Bun.file(file), { headers: { ...headers, 'content-type': 'image/png' } })
  const png = generated(m[1])
  return png ? new Response(png, { headers: { ...headers, 'content-type': 'image/png' } }) : null
}

/** A bot's face: its skin's picture from avatars/skins. */
function avatar(name: string): Response | null {
  const headers = { 'content-type': 'image/png', 'cache-control': 'max-age=3600' }
  const n = name.startsWith('skins/') ? name.slice(6) : botById(name)?.skin
  if (!n) return null
  const file = join(AVATARS, 'skins', `${n}.png`)
  return existsSync(file) ? new Response(Bun.file(file), { headers }) : null
}

// ---------- settings ----------

function saveSettings(b: any): Settings {
  const cur = world.settings
  const hhmm = (v: unknown, fallback: string) => (typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v) ? v : fallback)
  world.settings = {
    quiet: { enabled: typeof b.quiet?.enabled === 'boolean' ? b.quiet.enabled : cur.quiet.enabled, from: hhmm(b.quiet?.from, cur.quiet.from), to: hhmm(b.quiet?.to, cur.quiet.to), alarms: typeof b.quiet?.alarms === 'boolean' ? b.quiet.alarms : cur.quiet.alarms },
    brief: { enabled: typeof b.brief?.enabled === 'boolean' ? b.brief.enabled : cur.brief.enabled, at: b.brief?.at === 'quiet-end' ? 'quiet-end' : hhmm(b.brief?.at, cur.brief.at), agent: botById(String(b.brief?.agent ?? '')) ? String(b.brief.agent) : cur.brief.agent },
    quickReplies: Array.isArray(b.quickReplies) ? b.quickReplies.map(String).filter(Boolean).slice(0, 6) : cur.quickReplies,
  }
  return world.settings
}

// ---------- search ----------

function search(q: string) {
  if (q.length < 2) return { messages: [], cards: [] }
  const lower = q.toLowerCase()
  const messages = world.bots.flatMap((b) => b.entries.filter((e) => e.type !== 'auto' && e.text.toLowerCase().includes(lower)).map((e) => {
    return { agent: b.id, role: e.type === 'me' ? 'user' : 'assistant', at: e.at, id: e.id, snippet: snippet(e.text, q) }
  })).sort((a, b) => b.at.localeCompare(a.at)).slice(0, 40)
  const cards = world.cards.filter((c) => [c.title, c.why, c.steps, c.detail, ...(c.fields ?? []).map((f) => f.value)]
    .some((x) => x && String(x).toLowerCase().includes(lower))).slice(0, 20)
  return { messages, cards }
}

// ---------- HTTP ----------

const json = (x: unknown, status = 200) => new Response(JSON.stringify(x), { status, headers: { 'content-type': 'application/json' } })

async function gz(req: Request, res: Response): Promise<Response> {
  if (!(req.headers.get('accept-encoding') ?? '').includes('gzip')) return res
  if (!(res.headers.get('content-type') ?? '').startsWith('application/json')) return res
  const raw = new Uint8Array(await res.arrayBuffer())
  if (raw.length < 1500) return new Response(raw, { status: res.status, headers: res.headers })
  const headers = new Headers(res.headers)
  headers.set('content-encoding', 'gzip')
  return new Response(Bun.gzipSync(raw), { status: res.status, headers })
}

async function route(req: Request): Promise<Response> {
  const url = new URL(req.url)
  const path = url.pathname
  const GET = req.method === 'GET', POST = req.method === 'POST'
  if (path === '/health') return json({ ok: true })
  let m = path.match(/^\/v1\/avatars\/((?:skins\/)?[a-z0-9-]+)\.png$/)
  if (m && GET) return avatar(m[1]) ?? json({ error: 'no avatar' }, 404)
  if (req.headers.get('authorization') !== `Bearer ${TOKEN}`) return json({ error: 'unauthorized' }, 401)

  // The scenario starts when the first client connects, so nobody arrives after the opening work is over.
  if (!started) { started = true; if (!FROZEN) world = seed(Date.now()) }
  advance()

  const body: any = POST ? await req.json().catch(() => ({})) : {}
  try {
    if (path === '/v1/hello' && GET) return json({ ok: true, name: 'T3 Bot', version: VERSION, user: USER, demo: true, push: false, chief: CHIEF, bots: world.bots.length, t3: { ok: true } })
    if (path === '/v1/home' && GET) return json(home())
    if (path === '/v1/skins' && GET) return json({ skins: SKINS, used: world.bots.map((b) => b.skin) })
    if (path === '/v1/settings' && GET) return json(world.settings)
    if (path === '/v1/settings' && POST) return json(saveSettings(body))
    if (path === '/v1/search' && GET) return json(search((url.searchParams.get('q') ?? '').trim()))
    if (path === '/v1/know' && GET) {
      const since = clock() - 24 * 3600e3
      return json({ notes: world.notes.filter((n) => Date.parse(n.created_at) > since).sort((a, b) => b.created_at.localeCompare(a.created_at)) })
    }
    if (path === '/v1/file' && GET) return picture(url.searchParams.get('path') ?? '') ?? json({ error: 'not an image this app may show' }, 404)

    m = path.match(/^\/v1\/agents\/([a-z0-9-]+)$/)
    if (m && GET) {
      const b = botById(m[1])
      return b ? json(timeline(b)) : json({ error: 'no such agent' }, 404)
    }
    m = path.match(/^\/v1\/agents\/([a-z0-9-]+)\/send$/)
    if (m && POST) {
      const b = botById(m[1])
      if (!b) return json({ ok: false, error: 'no such agent or no thread' }, 404)
      const images = Array.isArray(body.images) ? saveImages(body.images) : []
      const text = String(body.text ?? '').trim()
      if (!text && !images.length) return json({ ok: false, error: 'empty message' }, 400)
      say(b, text, images)
      const script = images.length && !text
        ? { phases: [{ activity: 'reading', step: `Looked at the photo${images.length === 1 ? '' : 's'}`, secs: 2 }, { activity: 'thinking', step: 'Worked out what it shows', secs: 2 }], reply: `Got the photo${images.length === 1 ? '' : 's'}. Tell me what you want done with ${images.length === 1 ? 'it' : 'them'}.\n\n» File a bug from it · Just keep it` }
        : scriptFor(b, text, b.members.map((id) => botById(id)?.name).filter((n): n is string => !!n))
      startRun(b, script)
      return json({ ok: true })
    }
    m = path.match(/^\/v1\/agents\/([a-z0-9-]+)\/edit$/)
    if (m && POST) return json(editAgent(m[1], body))
    if (path === '/v1/agents' && POST) return json(newAgent(body))

    if (path === '/v1/answer' && POST) {
      const { threadId, requestId, answers, decision } = body
      if (!threadId || !requestId) return json({ ok: false, error: 'threadId and requestId are required' }, 400)
      const card = world.cards.find((c) => c.requestId === String(requestId))
      if (!card) return json({ ok: false, error: 'that question is no longer waiting for an answer' }, 404)
      const b = botById(card.agent) ?? botById(CHIEF)!
      removeCard(card.id)
      if (decision) {
        const script = decisionScript(decision === 'accept', card.title.replace(/^Approve: /, ''))
        // A bot busy with something else is not interrupted: the result lands as an automatic update.
        if (b.run && !runState(b.run, clock()).asking) {
          b.entries.push({ id: nextId('m'), type: 'agent', text: splitSuggestions(script.reply).text, at: iso(Date.now()), steps: script.phases.map((p) => p.step), auto: true })
        } else startRun(b, script)
      } else {
        const picked = Object.values(answers ?? {}).flat().map(String).filter(Boolean).join(', ')
        const script = answerScript(b, picked)
        const asked = b.run && runState(b.run, clock()).asking ? b.run : null
        if (asked) {
          // The run that asked carries on from where it stopped, in the same bubble.
          const before = asked.phases.slice(0, asked.askAfter)
          const done = before.reduce((n, p) => n + p.secs, 0) * 1000
          b.run = { ...asked, askAfter: undefined, startedAt: Date.now() - done, phases: [...before, ...script.phases], reply: script.reply }
          if (FROZEN) finish(b, Date.now())
        } else startRun(b, script)
      }
      return json({ ok: true })
    }

    m = path.match(/^\/v1\/cards\/(done|snooze|handle)$/)
    if (m && POST) {
      if (!body.id) return json({ ok: false, error: 'id required' }, 400)
      return json(cardAction(String(body.id), m[1], body))
    }
    if (path === '/v1/cards/act' && POST) {
      if (!body.id || !body.action) return json({ ok: false, error: 'id and action required' }, 400)
      const r = act(String(body.id), String(body.action), body)
      return json(r, r.ok ? 200 : 502)
    }
    // Demo only: bring back a card that was marked done or snoozed (the app's own undo never reaches the server).
    if (path === '/v1/cards/undo' && POST) {
      const id = String(body.id ?? '')
      if (!id) return json({ ok: false, error: 'id required' }, 400)
      const back = world.removed.get(id)
      if (back) { world.cards.push(back); world.removed.delete(id) }
      const wasSnoozed = world.snoozed.delete(id)
      return back || wasSnoozed || world.cards.some((c) => c.id === id) ? json({ ok: true }) : json({ ok: false, error: 'card not found' }, 404)
    }

    if (path === '/v1/notify' && POST) return json({ ok: true, ...addNote(body) })
    if (path === '/v1/notes/wrong' && POST) {
      const n = world.notes.find((x) => x.id === String(body.id ?? ''))
      if (!n) return json({ ok: false, error: 'no such note' }, 404)
      world.notes = world.notes.filter((x) => x !== n)
      const b = botById(n.agent) ?? botById(CHIEF)!
      say(b, `This was wrong: "${n.title}"` + (body.text ? `\n\n${body.text}` : ''))
      startRun(b, {
        phases: [{ activity: 'reading', step: 'Read what I did', secs: 2 }, { activity: 'running', step: 'Undid it', secs: 2 }, { activity: 'writing', step: 'Wrote down the lesson', secs: 2 }],
        reply: `Sorry about that. I undid "${n.title}" and wrote the lesson into my instructions so it does not happen again.\n\n» Thanks · What did you write down?`,
      })
      return json({ ok: true })
    }

    if (path === '/v1/share' && POST) {
      const b = botById(String(body.agent ?? '')) ?? botById(CHIEF)!
      const images = Array.isArray(body.images) ? saveImages(body.images) : []
      const parts = [body.note ? String(body.note) : '', body.url ? `Shared link: ${body.url}` : '', body.text ? `Shared text:\n${String(body.text).slice(0, 20000)}` : ''].filter(Boolean)
      if (!parts.length && !images.length) return json({ ok: false, error: 'nothing to share' }, 400)
      say(b, parts.join('\n\n'), images)
      const what = body.url ? 'the link' : images.length ? `the photo${images.length === 1 ? '' : 's'}` : 'the text'
      startRun(b, {
        phases: [{ activity: body.url ? 'web' : 'reading', step: `Opened ${what}`, secs: 2 }, { activity: 'thinking', step: 'Worked out what is useful in it', secs: 2 }, { activity: 'writing', step: 'Wrote the summary', secs: 2 }],
        reply: `I read ${what} you shared. Three things in it matter for us, and I saved them to my notes.\n\n- The main idea, in one line\n- What we could try this week\n- What does not apply to us\n\n» Give me the summary · Turn it into a task · Thanks`,
      })
      return json({ ok: true, agent: b.id })
    }

    if (path === '/v1/routines/enabled' && POST) {
      const r = world.bots.flatMap((b) => b.routines).find((x) => x.id === String(body.id ?? ''))
      if (!r) return json({ ok: false, error: 'no such routine' }, 404)
      r.enabled = !!body.enabled
      return json({ ok: true })
    }

    if (path === '/v1/devices' && POST) {
      if (!HEX.test(String(body.token ?? ''))) return json({ ok: false, error: 'token required (the hex push token of the device)' }, 400)
      world.devices.set(String(body.token), body.env === 'sandbox' ? 'sandbox' : 'production')
      return json({ ok: true })
    }
    if (path === '/v1/devices/remove' && POST) {
      if (!HEX.test(String(body.token ?? ''))) return json({ ok: false, error: 'token required (the hex push token of the device)' }, 400)
      world.devices.delete(String(body.token))
      return json({ ok: true })
    }
    if (path === '/v1/test-push' && POST) return json({ ok: true, devices: world.devices.size, push: false })
    if (path === '/v1/live' && POST) {
      if (!botById(String(body.agent ?? '')) || !HEX.test(String(body.token ?? ''))) return json({ ok: false, error: 'agent and token required' }, 400)
      world.live.set(String(body.agent), { token: String(body.token), startedAt: Number(body.startedAt) || Date.now() / 1000 })
      return json({ ok: true })
    }

    if (path === '/v1/phone/sync' && POST) {
      world.phone = { at: iso(Date.now()), calendar: Array.isArray(body.calendar) ? body.calendar : [], contacts: Array.isArray(body.contacts) ? body.contacts : [] }
      return json({ ok: true })
    }
    if (path === '/v1/phone/forget' && POST) { world.phone = null; return json({ ok: true }) }
    if (path === '/v1/phone/calendar' && GET) {
      return world.phone ? json({ at: world.phone.at, events: world.phone.calendar }) : json({ ok: false, error: 'the phone has not shared its calendar' }, 404)
    }
    if (path === '/v1/phone/contacts' && GET) {
      if (!world.phone) return json({ ok: false, error: 'the phone has not shared its contacts' }, 404)
      const q = (url.searchParams.get('q') ?? '').trim().toLowerCase()
      const contacts = q ? world.phone.contacts.filter((c) => JSON.stringify(c).toLowerCase().includes(q)) : world.phone.contacts
      return json({ at: world.phone.at, contacts: contacts.slice(0, 50), total: world.phone.contacts.length })
    }

    if (path === '/v1/demo/reset' && POST) {
      world = seed(Date.now())
      return json({ ok: true })
    }
    return json({ error: 'not found' }, 404)
  } catch (e) {
    if (e instanceof BadRequest) return json({ ok: false, error: e.message }, 400)
    log('request error', { path, e: String(e) })
    return json({ ok: false, error: String(e instanceof Error ? e.message : e) }, 500)
  }
}

Bun.serve({
  // Bun cuts a request after 10 s by default; making a bot waits longer than that for its face.
  idleTimeout: 60,
  port: PORT,
  hostname: HOST,
  maxRequestBodySize: 48 * 1024 * 1024,
  fetch: async (req) => (req.method === 'GET' ? gz(req, await route(req)) : route(req)),
})

if (!flag('no-banner')) {
  const lan = Object.values(networkInterfaces()).flat().find((i) => i && i.family === 'IPv4' && !i.internal)?.address
  const base = `http://${HOST === '0.0.0.0' ? lan ?? '127.0.0.1' : HOST}:${PORT}`
  console.log(`T3 Bot demo server ${VERSION}${FROZEN ? ' (frozen)' : ''}`)
  console.log(`  On this machine:  http://127.0.0.1:${PORT}`)
  if (HOST === '0.0.0.0' && lan) console.log(`  On your network:  ${base}`)
  console.log(`  Token:            ${TOKEN}`)
  console.log(`  Pairing link:     t3bot://connect?url=${encodeURIComponent(base)}&token=${TOKEN}`)
  console.log('  Everything is invented and kept in memory. Stop with Ctrl C.')
}
