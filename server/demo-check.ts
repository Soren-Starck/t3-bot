/**
 * Checks a running demo server against what the app decodes (ios/T3Bot/API.swift): every GET answer field by
 * field (required keys present, right types, optional ones right when present), then every write the app can make.
 *
 *   bun server/demo.ts --port 8812 &
 *   bun server/demo-check.ts [--url http://127.0.0.1:8812] [--token demo] [--read-only]
 *
 * The write checks only run against a server that says `"demo": true` in /v1/hello. Such a server is reset
 * before the first check and after the last one, unless --read-only is given. Exit code 0 when everything passed, 1 otherwise.
 */
import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'fs'
import { networkInterfaces, tmpdir } from 'os'
import { dirname, join } from 'path'
import { asks, oneLine, preview, quickReplies, snippet } from './text'
import { BadInput, bodyLimit, inQuiet, kindOf, minutesSince, overLimit, readBody, safeLink, servableImage, storedNote, tidyNote, wrongMethod } from './guard'
import { CURL_ARGS, curlConfig, post as apnsPost, token as apnsToken } from './push'

const args = process.argv.slice(2)
const option = (name: string) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : undefined }
const BASE = (option('url') ?? 'http://127.0.0.1:8812').replace(/\/+$/, '')
const TOKEN = option('token') ?? 'demo'
// A push token as a phone sends it: hex, and long enough for the server to take it.
const DEVICE = 'ab12'.repeat(16)
const READ_ONLY = args.includes('--read-only')

let passed = 0
const failures: string[] = []
function ok(cond: unknown, what: string) {
  if (cond) passed++
  else { failures.push(what); console.log(`  FAIL ${what}`) }
}
const section = (name: string) => console.log(`\n${name}`)

// ---------- a small schema language, mirroring the Swift models ----------
// 'string' | 'bool' | 'int' | 'number' | 'date', with a trailing '?' when Swift has an Optional (absent or null
// is fine, a wrong type is not); [spec] for arrays; { key: spec } for structs.

type Spec = string | [Spec] | { [key: string]: Spec }
const opt = (s: Spec): [Spec, boolean] => (typeof s === 'string' && s.endsWith('?') ? [s.slice(0, -1), true] : [s, false])
const ISO = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/

function check(value: any, spec: Spec, at: string): void {
  if (Array.isArray(spec)) {
    if (!Array.isArray(value)) return ok(false, `${at}: expected an array, got ${JSON.stringify(value)?.slice(0, 60)}`)
    value.forEach((v, i) => check(v, spec[0], `${at}[${i}]`))
    return
  }
  if (typeof spec === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return ok(false, `${at}: expected an object, got ${JSON.stringify(value)?.slice(0, 60)}`)
    for (const [key, raw] of Object.entries(spec)) {
      const optionalKey = key.endsWith('?')
      const name = optionalKey ? key.slice(0, -1) : key
      const [inner, optionalType] = opt(raw)
      const v = value[name]
      if (v === undefined || v === null) { ok(optionalKey || optionalType, `${at}.${name}: missing, and the app needs it`); continue }
      check(v, inner, `${at}.${name}`)
    }
    return
  }
  const [type] = opt(spec)
  const good = type === 'string' ? typeof value === 'string'
    : type === 'bool' ? typeof value === 'boolean'
    : type === 'int' ? Number.isInteger(value)
    : type === 'number' ? typeof value === 'number'
    : type === 'date' ? typeof value === 'string' && ISO.test(value)
    : false
  ok(good, `${at}: expected ${type}, got ${JSON.stringify(value)?.slice(0, 60)}`)
}

const Agent: Spec = {
  id: 'string', name: 'string', role: 'string', avatar: 'string', kind: 'string', face: { skin: 'string' }, hidden: 'bool',
  members: ['string'], threadId: 'string', threadTitle: 'string', t3Link: 'string?', status: 'string', mood: 'string?',
  activity: 'string?', lastReplyAt: 'date?', needs: 'int', 'last?': { text: 'string', at: 'date', from: 'string' },
  watching: ['string'], color: 'string?',
}
const Question: Spec = { id: 'string', question: 'string', header: 'string?', multiSelect: 'bool', options: [{ label: 'string', description: 'string?' }] }
const Draft: Spec = { to: 'string?', text: 'string?', via: 'string?', subject: 'string?', event: 'string?', start: 'date?', end: 'date?', location: 'string?' }
const Card: Spec = {
  id: 'string', source: 'string', agent: 'string', rank: 'int', title: 'string', detail: 'string?', why: 'string?', steps: 'string?',
  urgency: 'string?', customer: 'bool?', minutes: 'number?', desk: 'string?', deskName: 'string?', key: 'string?', at: 'date',
  threadId: 'string?', threadTitle: 'string?', requestId: 'string?', requestKind: 'string?', 'questions?': [Question],
  kind: 'string?', link: 'string?', 'draft?': Draft, 'fields?': [{ label: 'string', value: 'string' }],
  'checks?': [{ label: 'string', state: 'string' }], 'edit?': { label: 'string', text: 'string' },
  'actions?': [{ id: 'string', label: 'string', kind: 'string', style: 'string?', faceId: 'bool?' }],
}
const Home: Spec = { agents: [Agent], phoneShared: 'bool?', needs: [Card], badge: 'int', doneToday: 'int', chief: 'string?', user: 'string?', 't3?': { ok: 'bool', error: 'string?' }, generatedAt: 'date' }
// Swift keeps every field of Hello optional so it can talk to old servers; the contract makes them all required.
const Hello: Spec = { ok: 'bool', name: 'string', version: 'string', user: 'string', demo: 'bool', push: 'bool', chief: 'string?', bots: 'int?', 't3?': { ok: 'bool', error: 'string?' } }
const Routine: Spec = { id: 'string', title: 'string', enabled: 'bool', when: 'string', nextRunAt: 'date?', lastRunAt: 'date?', lastRunStatus: 'string?', own: 'bool' }
const Entry: Spec = { id: 'string', type: 'string', text: 'string', at: 'date', steps: ['string'], working: 'bool?', 'suggestions?': ['string'], auto: 'bool?', 'images?': [{ path: 'string', alt: 'string' }] }
const RunInfo: Spec = { threadId: 'string', title: 'string', status: 'string', at: 'date', text: 'string' }
const Timeline: Spec = { agent: Agent, routines: [Routine], entries: [Entry], working: 'bool', cards: [Card], runs: [RunInfo], 'members?': [Agent] }
const AppSettings: Spec = { quiet: { enabled: 'bool', from: 'string', to: 'string', alarms: 'bool' }, brief: { enabled: 'bool', at: 'string', agent: 'string' }, quickReplies: ['string'] }
const SkinList: Spec = { skins: [{ n: 'string', title: 'string', series: 'string' }], used: ['string?'] }
const KnowList: Spec = { notes: [{ id: 'string', agent: 'string', kind: 'string', title: 'string', body: 'string?', created_at: 'date' }] }
const Search: Spec = { messages: [{ id: 'string', agent: 'string?', role: 'string', at: 'date', snippet: 'string' }], cards: [Card] }
const Reply: Spec = { ok: 'bool?', error: 'string?', agent: 'string?', id: 'string?', devices: 'int?', push: 'bool?' }

// ---------- HTTP ----------

const auth = { authorization: `Bearer ${TOKEN}` }
async function get(path: string, headers: Record<string, string> = auth) {
  const res = await fetch(BASE + path, { headers })
  const type = res.headers.get('content-type') ?? ''
  const bytes = new Uint8Array(await res.arrayBuffer())
  let body: any = null
  if (type.startsWith('application/json')) { try { body = JSON.parse(new TextDecoder().decode(bytes)) } catch {} }
  return { status: res.status, type, bytes, body, raw: new TextDecoder().decode(bytes) }
}
async function post(path: string, payload: unknown = {}, headers: Record<string, string> = auth) {
  const res = await fetch(BASE + path, { method: 'POST', headers: { ...headers, 'content-type': 'application/json' }, body: JSON.stringify(payload) })
  let body: any = null
  try { body = await res.json() } catch {}
  return { status: res.status, body }
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const isPng = (b: Uint8Array) => b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47
const home = async () => (await get('/v1/home')).body
const timeline = async (id: string) => (await get(`/v1/agents/${id}`)).body
/** Waits until the bot has stopped working and returns its timeline (frozen servers answer at once). */
async function settled(id: string, seconds = 30) {
  for (let i = 0; i < seconds * 2; i++) {
    const t = await timeline(id)
    if (!t.working) return t
    await sleep(500)
  }
  return timeline(id)
}

// ---------- read checks ----------

const MOODS = ['working', 'waiting', 'watching', 'failed', 'asleep']
const CARD_KINDS = ['alarm', 'approve', 'do', 'draft']

async function reads() {
  section('Open routes and auth')
  const health = await get('/health', {})
  ok(health.status === 200 && health.body?.ok === true, 'GET /health answers {ok:true} without a token')
  ok((await get('/v1/home', {})).status === 401, 'GET /v1/home without a token is 401')
  ok((await get('/v1/home', { authorization: 'Bearer wrong' })).status === 401, 'GET /v1/home with a wrong token is 401')
  ok((await get('/v1/nothing-here')).status === 404, 'an unknown route is 404')

  section('GET /v1/hello')
  const hello = await get('/v1/hello')
  ok(hello.status === 200, 'GET /v1/hello is 200')
  check(hello.body, Hello, 'hello')
  ok(/^\d+\.\d+\.\d+/.test(hello.body?.version ?? ''), 'hello.version is a semver')
  ok(hello.body?.name === 'T3 Bot', 'hello.name is "T3 Bot"')

  section('GET /v1/home')
  const h = await home()
  check(h, Home, 'home')
  const ids: string[] = h.agents.map((a: any) => a.id)
  ok(new Set(ids).size === ids.length, 'agent ids are unique')
  ok(ids.every((id) => /^[a-z0-9-]+$/.test(id)), 'agent ids match [a-z0-9-]+')
  ok(h.agents.every((a: any) => MOODS.includes(a.mood)), 'every mood is one the app knows')
  ok(h.agents.every((a: any) => ['bot', 'group'].includes(a.kind)), 'every kind is bot or group')
  ok(h.agents.every((a: any) => /^#[0-9a-f]{6}$/i.test(a.color ?? '')), 'every bot has a color')
  ok(new Set(h.agents.map((a: any) => a.face.skin)).size === h.agents.length, 'every bot wears a different skin')
  ok(ids.includes(h.chief), 'home.chief names a bot')
  const cardIds: string[] = h.needs.map((c: any) => c.id)
  ok(new Set(cardIds).size === cardIds.length, 'card ids are unique')
  ok(h.needs.every((c: any) => ids.includes(c.agent)), 'every card belongs to a bot')
  ok(h.needs.every((c: any, i: number) => i === 0 || h.needs[i - 1].rank <= c.rank), 'needs are sorted by rank')
  ok(h.badge === h.needs.filter((c: any) => c.rank <= 1).length, 'badge counts the cards of rank 0 and 1')
  ok(h.needs.every((c: any) => c.source !== 'note' || CARD_KINDS.includes(c.kind)), 'every note card has a kind the app knows')
  ok(h.needs.every((c: any) => (c.checks ?? []).every((k: any) => ['pass', 'fail', 'pending'].includes(k.state))), 'check states are pass, fail or pending')
  ok(h.needs.every((c: any) => c.source !== 'question' || (c.requestId && c.threadId && ['user_input', 'command'].includes(c.requestKind))), 'question cards carry requestId, threadId and requestKind')
  for (const a of h.agents) ok(a.needs === h.needs.filter((c: any) => c.agent === a.id).length, `${a.id}.needs matches its cards`)

  // Only right after the reset: on a live demo the bots finish their work and start again as time passes.
  if (hello.body?.demo && !READ_ONLY) {
    section('The demo world shows every state')
    for (const m of MOODS) ok(h.agents.some((a: any) => a.mood === m), `a bot is ${m}`)
    ok(h.agents.some((a: any) => a.kind === 'group' && a.members.length >= 2), 'there is a group with members')
    ok(h.agents.some((a: any) => a.hidden), 'there is a hidden bot')
    ok(h.agents.filter((a: any) => a.mood === 'working' && a.activity).length >= 2, 'two bots work with a live activity')
    const has = (what: string, f: (c: any) => unknown) => ok(h.needs.some(f), `the needs list has ${what}`)
    has('a question with options', (c) => c.requestKind === 'user_input' && c.questions?.some((q: any) => q.options.length))
    has('a multi select question', (c) => c.questions?.some((q: any) => q.multiSelect))
    has('a command approval', (c) => c.requestKind === 'command')
    for (const k of CARD_KINDS) has(`a ${k} card`, (c) => c.kind === k)
    has('a mail draft', (c) => c.draft?.via === 'mail' && c.draft.subject)
    has('a message draft', (c) => c.draft && c.draft.via !== 'mail' && !c.draft.event)
    has('an event draft', (c) => c.draft?.event && c.draft.start)
    has('a card with fields', (c) => c.fields?.length)
    has('a card with checks', (c) => c.checks?.length)
    has('a card with editable text', (c) => c.edit)
    has('a card with custom buttons', (c) => c.actions?.some((a: any) => a.kind === 'message'))
    has('a Face ID button', (c) => c.actions?.some((a: any) => a.faceId))
    has('a desk card for a customer', (c) => c.source === 'desk' && c.customer)
    has('a card with a link', (c) => c.link)
    ok(h.doneToday > 0, 'the evening digest has items')
  }

  section('GET /v1/agents/<id> (every bot)')
  const pictures = new Set<string>()
  const texts = new Map<string, string>()
  let rich = { code: false, table: false, list: false, link: false, image: false, suggestions: false, auto: false, runs: false, routines: false, working: false }
  for (const id of ids) {
    const r = await get(`/v1/agents/${id}`)
    ok(r.status === 200, `GET /v1/agents/${id} is 200`)
    const t = r.body
    check(t, Timeline, `timeline(${id})`)
    ok(t.agent.id === id, `timeline(${id}).agent is that bot`)
    ok(t.entries.length <= 60, `timeline(${id}) has at most 60 entries`)
    ok(new Set(t.entries.map((e: any) => e.id)).size === t.entries.length, `timeline(${id}) entry ids are unique`)
    ok(t.entries.every((e: any) => ['me', 'agent', 'auto'].includes(e.type)), `timeline(${id}) entry types are me, agent or auto`)
    ok(t.entries.every((e: any, i: number) => i === 0 || t.entries[i - 1].at <= e.at), `timeline(${id}) entries are in time order`)
    ok(t.entries.every((e: any) => !/^» /m.test(e.text)), `timeline(${id}) has no raw suggestions line in a text`)
    const last = t.entries[t.entries.length - 1]
    ok(t.working === !!last?.working, `timeline(${id}).working matches its last entry`)
    if (t.agent.kind === 'group') ok(t.members.length === t.agent.members.length && t.members.length >= 2, `timeline(${id}) lists the group's members`)
    // Only the last answer can carry the person's saved replies, and a working bubble carries none.
    ok(t.entries.every((e: any) => !e.working || !e.suggestions?.length), `timeline(${id}) shows no quick replies while the bot works`)
    for (const e of t.entries) {
      texts.set(e.id, e.text)
      for (const img of e.images ?? []) pictures.add(img.path)
      if (/```/.test(e.text)) rich.code = true
      if (/^\|.*\|$/m.test(e.text)) rich.table = true
      if (/^- /m.test(e.text)) rich.list = true
      if (/\[[^\]]+\]\(https?:/.test(e.text)) rich.link = true
      if (e.images?.length) rich.image = true
      if (e.suggestions?.length) rich.suggestions = true
      if (e.auto || e.type === 'auto') rich.auto = true
      if (e.working) rich.working = true
    }
    if (t.runs.length) rich.runs = true
    if (t.routines.length) rich.routines = true
  }
  if (hello.body?.demo) for (const [k, v] of Object.entries(rich)) ok(v, `some chat shows: ${k}`)
  ok((await get('/v1/agents/nobody-here')).status === 404, 'GET /v1/agents/<unknown> is 404')

  section('Pictures')
  for (const a of h.agents) {
    const r = await get(a.avatar, {})
    ok(r.status === 200 && r.type === 'image/png' && isPng(r.bytes), `GET ${a.avatar} is a PNG, open without a token`)
  }
  const skins = await get('/v1/skins')
  check(skins.body, SkinList, 'skins')
  ok(skins.body.skins.length >= 8, 'GET /v1/skins lists skins to pick from')
  ok(h.agents.every((a: any) => skins.body.used.includes(a.face.skin)), 'skins.used holds every bot skin')
  let badSkins = 0
  for (const s of skins.body.skins) { const r = await get(`/v1/avatars/skins/${s.n}.png`, {}); if (!(r.status === 200 && isPng(r.bytes))) badSkins++ }
  ok(badSkins === 0, `every listed skin has a picture (${skins.body.skins.length} checked, ${badSkins} missing)`)
  ok((await get('/v1/avatars/skins/0000.png', {})).status === 404, 'an unknown skin is 404')
  for (const p of pictures) {
    const r = await get(`/v1/file?path=${encodeURIComponent(p)}`)
    ok(r.status === 200 && r.type.startsWith('image/') && r.bytes.length > 500, `GET /v1/file?path=${p} is an image`)
  }
  ok((await get('/v1/file?path=/etc/hosts')).status === 404, 'GET /v1/file refuses a path outside the demo')
  ok((await get(`/v1/file?path=${encodeURIComponent('/demo/assets/../demo.ts')}`)).status === 404, 'GET /v1/file refuses a path with ..')

  section('Settings, digest, search, phone')
  const s = await get('/v1/settings')
  check(s.body, AppSettings, 'settings')
  ok(ids.includes(s.body.brief.agent), 'settings.brief.agent names a bot')
  const know = await get('/v1/know')
  check(know.body, KnowList, 'know')
  ok(know.body.notes.length === h.doneToday, 'know lists as many notes as home.doneToday')
  ok(know.body.notes.every((n: any, i: number) => i === 0 || know.body.notes[i - 1].created_at >= n.created_at), 'know is newest first')
  for (const q of ['pricing', 'refund', 'rate limit']) {
    const r = await get(`/v1/search?q=${encodeURIComponent(q)}`)
    check(r.body, Search, `search(${q})`)
    if (hello.body?.demo) ok(r.body.messages.length + r.body.cards.length > 0, `search for "${q}" finds something`)
    ok(r.body.messages.every((m: any) => ['user', 'assistant'].includes(m.role) && ids.includes(m.agent)), `search(${q}) hits name a bot and a role`)
  }
  // Snippets: one clean line, cut on whole words, with an ellipsis at each cut end.
  for (const q of ['pricing', 'refund', 'rate limit', '610', 'speed score', 'the']) {
    const hits: any[] = (await get(`/v1/search?q=${encodeURIComponent(q)}`)).body.messages
    ok(hits.every((m) => m.snippet.length > 0 && m.snippet.length <= 204 && !/\n/.test(m.snippet)), `search(${q}) snippets are one line of at most about 200 characters`)
    ok(hits.every((m) => !/[|*`]|^[\s·]|[\s·]$|…\s|\s…/.test(m.snippet)), `search(${q}) snippets carry no table pipes, no markdown marks and no loose separators`)
    let cut = 0
    for (const m of hits) {
      const raw = texts.get(m.id)
      if (raw === undefined) continue
      const flat = oneLine(raw)
      const body = m.snippet.replace(/^…/, '').replace(/…$/, '')
      const at = flat.indexOf(body)
      ok(at >= 0, `search(${q}) snippet of ${m.id} is a piece of the message`)
      if (at < 0) continue
      const starts = m.snippet.startsWith('…'), ends = m.snippet.endsWith('…')
      if (starts || ends) cut++
      ok(starts === at > 0, `search(${q}) snippet of ${m.id} has a leading ellipsis exactly when its start was cut`)
      ok(ends === at + body.length < flat.length, `search(${q}) snippet of ${m.id} has a trailing ellipsis exactly when its end was cut`)
      // A cut never lands inside a word: the character just outside each end is not a letter or a digit.
      const before = flat[at - 1] ?? ' ', after = flat[at + body.length] ?? ' '
      ok(!/[A-Za-z0-9]/.test(before) || !/^[A-Za-z0-9]/.test(body), `search(${q}) snippet of ${m.id} starts on a whole word`)
      ok(!/[A-Za-z0-9]/.test(after) || !/[A-Za-z0-9]$/.test(body), `search(${q}) snippet of ${m.id} ends on a whole word`)
      if (flat.toLowerCase().includes(q)) ok(m.snippet.toLowerCase().includes(q), `search(${q}) snippet of ${m.id} shows the match`)
    }
    if (hello.body?.demo && q === 'the') ok(cut > 0, 'some snippets are cut, so the ellipsis rule was exercised')
  }
  if (hello.body?.demo) {
    const table = (await get('/v1/search?q=610')).body.messages.find((m: any) => m.agent === 'web')
    ok(table && table.snippet.includes('Page weight: 2.6 MB, 610 KB · Speed score: 61, 97'), `a table row keeps its cells apart and its rows apart (${table?.snippet})`)
  }
  const none = await get('/v1/search?q=a')
  ok(none.body.messages.length === 0 && none.body.cards.length === 0, 'a one letter search is empty')
  const empty = await get('/v1/search?q=zzqqxxyy')
  ok(empty.body.messages.length === 0 && empty.body.cards.length === 0, 'a search with no match is empty')

  section('gzip')
  const big = await fetch(BASE + '/v1/home', { headers: { ...auth, 'accept-encoding': 'gzip' }, decompress: false } as any)
  ok(big.headers.get('content-encoding') === 'gzip', 'a large JSON answer is gzipped when the client accepts it')
  return hello.body
}

// ---------- write checks (demo servers only) ----------

async function writes() {
  const reset = async () => ok((await post('/v1/demo/reset')).body?.ok === true, 'POST /v1/demo/reset')
  const replied = (t: any, after: number) => {
    const last = t.entries[t.entries.length - 1]
    return t.entries.length > after && last.type === 'agent' && !last.working && last.text.length > 20
  }

  section('Send a message and get a reply')
  await reset()
  let before = (await timeline('support')).entries.length
  let r = await post('/v1/agents/support/send', { text: 'Any refunds waiting?' })
  check(r.body, Reply, 'send')
  ok(r.status === 200 && r.body.ok === true, 'POST /v1/agents/support/send')
  let t = await timeline('support')
  ok(t.entries.some((e: any) => e.type === 'me' && e.text === 'Any refunds waiting?'), 'the message shows in the chat exactly as sent')
  const frozen = !t.working
  console.log(`  (server is ${frozen ? 'frozen: replies land at once' : 'live: replies take a few seconds'})`)
  if (!frozen) {
    const last = t.entries[t.entries.length - 1]
    ok(last.working === true && last.text === '', 'while it works, the last entry is an empty working bubble')
    const a = (await home()).agents.find((x: any) => x.id === 'support')
    ok(a.mood === 'working' && typeof a.activity === 'string', 'home shows the bot working with an activity')
    await sleep(2600)
    ok((await timeline('support')).entries.at(-1).steps.length >= 1, 'steps appear while it works')
  }
  t = await settled('support')
  check(t, Timeline, 'timeline(support) after the reply')
  ok(replied(t, before + 1), 'the bot replied')
  ok(t.entries.at(-1).suggestions?.length >= 1, 'the reply carries quick replies')
  const saved: string[] = (await get('/v1/settings')).body.quickReplies
  ok(saved.length > 0 && !t.entries.at(-1).suggestions.some((x: string) => saved.includes(x)), 'a reply with its own suggestions shows only those, not the saved replies')
  ok(t.entries.at(-1).steps.length >= 2, 'the reply keeps its steps')
  ok((await home()).agents.find((x: any) => x.id === 'support').last.from === 'agent', 'home shows the reply as the last message')
  r = await post('/v1/agents/support/send', { text: '   ' })
  ok(r.status === 400 && r.body.ok === false, 'an empty message is refused with 400')
  ok((await post('/v1/agents/nobody-here/send', { text: 'hi' })).status === 404, 'a message to an unknown bot is 404')

  section('Quick replies only where the answer asks')
  await post('/v1/agents/support/send', { text: 'Thanks' })
  t = await settled('support')
  ok(t.entries.at(-1).type === 'agent' && !asks(t.entries.at(-1).text), 'the answer to "Thanks" asks nothing')
  ok(!t.entries.at(-1).suggestions?.length, `an answer that asks nothing carries no quick replies (${JSON.stringify(t.entries.at(-1).suggestions)})`)
  await post('/v1/agents/support/send', { text: 'Not now' })
  t = await settled('support')
  ok(/\?$/.test(t.entries.at(-1).text), 'the answer to "Not now" ends with a question')
  ok(t.entries.at(-1).suggestions?.join('|') === saved.join('|'), `an answer that asks, with no suggestions of its own, carries the saved replies (${JSON.stringify(t.entries.at(-1).suggestions)})`)
  ok(t.entries.slice(0, -1).every((e: any) => !e.suggestions?.some((x: string) => saved.includes(x))), 'the saved replies never show under an older answer')

  section('Send a photo')
  const png = (await get('/v1/avatars/chief.png', {})).bytes
  r = await post('/v1/agents/chief/send', { text: 'What is this?', images: [Buffer.from(png).toString('base64')] })
  ok(r.body.ok === true, 'POST /v1/agents/chief/send with an image')
  t = await settled('chief')
  const mine = [...t.entries].reverse().find((e: any) => e.type === 'me')
  ok(mine?.images?.length === 1, 'the photo shows on the sent message')
  const photo = await get(`/v1/file?path=${encodeURIComponent(mine.images[0].path)}`)
  ok(photo.status === 200 && isPng(photo.bytes), 'the photo comes back from /v1/file')
  r = await post('/v1/agents/finance/send', { images: [Buffer.from(png).toString('base64')] })
  ok(r.body.ok === true, 'POST /v1/agents/finance/send with only a photo')
  if (!frozen) {
    // A frozen server shows the reply at once, so the photo is only the last message on a live one.
    const mineLast = (await home()).agents.find((x: any) => x.id === 'finance').last
    ok(mineLast.from === 'me' && mineLast.text === 'Photo', `home shows a message that was only a photo as "Photo" (${JSON.stringify(mineLast)})`)
  }
  t = await settled('finance')
  ok([...t.entries].reverse().find((e: any) => e.type === 'me')?.text === '', 'the chat shows the photo with no text')
  ok(!/\[Image from /.test(JSON.stringify(await home())), 'no "[Image from" line reaches home')

  section('Group chat')
  r = await post('/v1/agents/launch-crew/send', { text: 'Are we ready for Thursday?' })
  t = await settled('launch-crew')
  const names: string[] = t.members.map((m: any) => m.name)
  ok(names.every((n) => t.entries.at(-1).text.includes(`**${n}:**`)), 'every member of the group answers in its own paragraph')

  section('Answer a question')
  let h = await home()
  const q = h.needs.find((c: any) => c.requestKind === 'user_input')
  ok((await post('/v1/cards/done', { id: q.id })).body.ok === false, 'a question cannot be marked done')
  before = (await timeline(q.agent)).entries.length
  ok((await post('/v1/answer', { threadId: q.threadId })).status === 400, 'an answer without requestId is 400')
  const answers = Object.fromEntries(q.questions.map((x: any) => [x.id, x.multiSelect ? [x.options[0].label] : x.options[0].label]))
  r = await post('/v1/answer', { threadId: q.threadId, requestId: q.requestId, answers })
  ok(r.body.ok === true, 'POST /v1/answer with answers')
  h = await home()
  ok(!h.needs.some((c: any) => c.id === q.id), 'the question left the needs list')
  t = await settled(q.agent)
  ok(replied(t, before - 1) && t.entries.at(-1).text.includes(q.questions[0].options[0].label), 'the bot carried on with the answer')
  ok((await post('/v1/answer', { threadId: q.threadId, requestId: q.requestId, answers })).status === 404, 'answering twice is 404')

  section('Approve a command')
  const cmd = h.needs.find((c: any) => c.requestKind === 'command')
  r = await post('/v1/answer', { threadId: cmd.threadId, requestId: cmd.requestId, decision: 'accept' })
  ok(r.body.ok === true, 'POST /v1/answer with a decision')
  ok(!(await home()).needs.some((c: any) => c.id === cmd.id), 'the approval left the needs list')
  await settled(cmd.agent)

  section('Cards: snooze, done, undo, handle, buttons')
  await reset()
  h = await home()
  const total = h.needs.length
  const doCard = h.needs.find((c: any) => c.kind === 'do')
  ok((await post('/v1/cards/snooze', {})).status === 400, 'a card action without id is 400')
  ok((await post('/v1/cards/snooze', { id: doCard.id })).body.ok === true, 'POST /v1/cards/snooze')
  ok((await home()).needs.length === total - 1, 'the snoozed card left the list')
  ok((await post('/v1/cards/undo', { id: doCard.id })).body.ok === true, 'POST /v1/cards/undo after a snooze')
  ok((await home()).needs.length === total, 'undo brought the snoozed card back')
  ok((await post('/v1/cards/snooze', { id: doCard.id, until: new Date(Date.now() + 3600e3).toISOString() })).body.ok === true, 'POST /v1/cards/snooze with until')
  await post('/v1/cards/undo', { id: doCard.id })
  ok((await post('/v1/cards/done', { id: doCard.id })).body.ok === true, 'POST /v1/cards/done')
  ok(!(await home()).needs.some((c: any) => c.id === doCard.id), 'the done card left the list')
  ok((await post('/v1/cards/undo', { id: doCard.id })).body.ok === true, 'POST /v1/cards/undo after done')
  ok((await home()).needs.some((c: any) => c.id === doCard.id), 'undo brought the done card back')
  ok((await post('/v1/cards/done', { id: 'note:nothing' })).body.ok === false, 'done on an unknown card says so')

  const desk = h.needs.find((c: any) => c.source === 'desk')
  r = await post('/v1/cards/handle', { id: desk.id })
  check(r.body, Reply, 'handle')
  ok(r.body.ok === true && r.body.agent === desk.agent, 'POST /v1/cards/handle returns the bot that took it')
  t = await settled(desk.agent)
  ok(t.entries.at(-1).type === 'agent' && t.entries.some((e: any) => e.type === 'me' && e.text.includes(desk.title)), 'the bot got the card and reported back')
  ok(!(await home()).needs.some((c: any) => c.id === desk.id), 'the handled card left the list')

  const ship = h.needs.find((c: any) => c.edit && c.actions?.some((a: any) => a.kind === 'message'))
  const button = ship.actions.find((a: any) => a.kind === 'message')
  ok((await post('/v1/cards/act', { id: ship.id })).status === 400, 'a button press without action is 400')
  r = await post('/v1/cards/act', { id: ship.id, action: button.id, text: 'Edited on the phone.' })
  ok(r.status === 200 && r.body.ok === true && r.body.agent === ship.agent, 'POST /v1/cards/act with a custom button and edited text')
  t = await settled(ship.agent)
  ok(t.entries.some((e: any) => e.type === 'me' && e.text.includes('Edited on the phone.')), 'the edited text reached the bot')
  ok(!(await home()).needs.some((c: any) => c.id === ship.id), 'the card left the list after its button')
  const other = (await home()).needs.find((c: any) => c.kind === 'do')
  ok((await post('/v1/cards/act', { id: other.id, action: 'snooze' })).body.ok === true, 'POST /v1/cards/act with snooze')
  ok((await post('/v1/cards/act', { id: (await home()).needs.find((c: any) => c.kind === 'draft').id, action: 'done' })).body.ok === true, 'POST /v1/cards/act with done (a draft)')
  ok((await post('/v1/cards/act', { id: 'note:nothing', action: 'done' })).status === 502, 'a button on an unknown card is 502')

  section('Notify (what `t3bot notify` posts)')
  await reset()
  for (const kind of ['alarm', 'approve', 'do', 'draft', 'know']) {
    r = await post('/v1/notify', {
      kind, title: `Check ${kind}`, body: 'Made by demo-check', agent: 'web', key: `check-${kind}`,
      ...(kind === 'draft' ? { draft: { to: 'dana@example.com', via: 'mail', subject: 'Hello', text: 'Hi Dana' } } : {}),
      ...(kind === 'approve' ? { fields: [{ label: 'Amount', value: '$12' }], checks: [{ label: 'Tests', state: 'pass' }], edit: { label: 'Note', text: 'As planned' }, actions: [{ id: 'go', label: 'Go' }], faceId: true } : {}),
    })
    ok(r.body.ok === true && r.body.id === `web:check-${kind}` && r.body.agent === 'web' && r.body.kind === kind, `POST /v1/notify kind ${kind}`)
  }
  h = await home()
  check(h, Home, 'home after notify')
  for (const kind of ['alarm', 'approve', 'do', 'draft']) ok(h.needs.some((c: any) => c.id === `note:web:check-${kind}`), `the ${kind} note is a card`)
  const made = h.needs.find((c: any) => c.id === 'note:web:check-approve')
  ok(made.actions[0].style === 'primary' && made.actions[0].faceId === true && made.actions.at(-1).kind === 'snooze', 'custom actions get Done and Not now appended')
  ok(!h.needs.find((c: any) => c.id === 'note:web:check-draft').actions, 'a draft card has no actions')
  await post('/v1/notify', { kind: 'do', title: 'Check do, again', agent: 'web', key: 'check-do' })
  h = await home()
  ok(h.needs.filter((c: any) => c.id === 'note:web:check-do').length === 1 && h.needs.find((c: any) => c.id === 'note:web:check-do').title === 'Check do, again', 'a note with the same key replaces the old one')
  let know = (await get('/v1/know')).body
  ok(know.notes[0].id === 'web:check-know', 'the know note leads the digest')
  ok((await post('/v1/notify', { kind: 'nope', title: 'x' })).status === 400, 'an unknown kind is 400')
  ok((await post('/v1/notify', { kind: 'do' })).status === 400, 'a note without title is 400')
  r = await post('/v1/notify', { kind: 'do', title: 'For the Chief' })
  ok(r.body.agent === h.chief, 'a note without agent goes to the Chief')

  section('Digest: this was wrong')
  before = know.notes.length
  r = await post('/v1/notes/wrong', { id: 'web:check-know', text: 'Not what I asked' })
  ok(r.body.ok === true, 'POST /v1/notes/wrong')
  ok((await get('/v1/know')).body.notes.length === before - 1, 'the note left the digest')
  t = await settled('web')
  ok(t.entries.some((e: any) => e.type === 'me' && e.text.includes('Not what I asked')), 'the bot was told what was wrong')
  ok((await post('/v1/notes/wrong', { id: 'nothing' })).status === 404, 'an unknown note is 404')

  section('Bots: create, edit, hide, unhide, group')
  r = await post('/v1/agents', { name: 'Docs Writer', job: 'Keeps the documentation current.' })
  check(r.body, Reply, 'create')
  ok(r.body.ok === true && r.body.id === 'docs-writer', 'POST /v1/agents creates a bot with a slug id')
  h = await home()
  check(h, Home, 'home after create')
  const fresh = h.agents.find((a: any) => a.id === 'docs-writer')
  ok(fresh && h.agents.filter((a: any) => a.face.skin === fresh.face.skin).length === 1, 'the new bot got a skin nobody else wears')
  t = await settled('docs-writer')
  check(t, Timeline, 'timeline(docs-writer)')
  ok(t.entries.at(-1)?.type === 'agent' && t.entries.at(-1).text.includes('Docs Writer'), 'the new bot introduces itself')
  ok((await get(fresh.avatar, {})).status === 200, 'the new bot has a face')
  ok((await post('/v1/agents', { name: 'Docs Writer' })).body.id === 'docs-writer-2', 'a second bot of the same name gets another id')
  ok((await post('/v1/agents', { name: '  ' })).body.ok === false, 'a bot without a name is refused')
  r = await post('/v1/agents/docs-writer/edit', { name: 'Docs', role: 'Writes the docs', face: { skin: '303' }, job: 'Write the docs every Friday.' })
  ok(r.body.ok === true && r.body.told === true, 'POST /v1/agents/<id>/edit with a new job tells the bot')
  let a = (await home()).agents.find((x: any) => x.id === 'docs-writer')
  ok(a.name === 'Docs' && a.role === 'Writes the docs' && a.face.skin === '303' && a.threadTitle === '%BOT Docs', 'name, role and face changed')
  ok((await post('/v1/agents/docs-writer/edit', { hidden: true })).body.ok === true, 'POST /v1/agents/<id>/edit hides a bot')
  ok((await home()).agents.find((x: any) => x.id === 'docs-writer').hidden === true, 'the bot is hidden')
  await post('/v1/agents/docs-writer/edit', { hidden: false })
  ok((await home()).agents.find((x: any) => x.id === 'docs-writer').hidden === false, 'and visible again')
  ok((await post(`/v1/agents/${h.chief}/edit`, { hidden: true })).body.ok === false, 'the Chief cannot be hidden')
  ok((await post('/v1/agents/nobody-here/edit', { name: 'x' })).body.ok === false, 'editing an unknown bot says so')
  ok((await post('/v1/agents', { kind: 'group', name: 'Duo', members: ['web'] })).body.ok === false, 'a group of one is refused')
  r = await post('/v1/agents', { kind: 'group', name: 'Money talk', members: ['finance', 'support', 'launch-crew'] })
  ok(r.body.ok === true && r.body.id === 'money-talk', 'POST /v1/agents creates a group')
  t = await settled('money-talk')
  ok(t.agent.kind === 'group' && t.members.length === 2 && t.agent.threadTitle === '%BOT Group: Money talk', 'the group has its two bots (a group cannot be a member)')
  await post('/v1/agents/money-talk/edit', { members: ['finance', 'support', 'api'] })
  t = await timeline('money-talk')
  ok(t.members.length === 3, 'editing a group changes its members')
  ok(t.agent.role === 'Group: Finance, Support, API', `and its line lists the new members (${t.agent.role})`)
  r = await post('/v1/agents/money-talk/edit', { name: 'Just one', members: ['finance'] })
  ok(r.body.ok === false && /two bots/.test(r.body.error ?? ''), 'editing a group down to one bot is refused')
  t = await timeline('money-talk')
  ok(t.members.length === 3 && t.agent.name === 'Money talk', 'and the refused edit changed nothing')

  section('Settings')
  r = await post('/v1/settings', { quiet: { enabled: false, from: '22:30', to: '07:15', alarms: false }, brief: { enabled: false, at: '09:00', agent: 'web' }, quickReplies: ['Ok', 'Later'] })
  check(r.body, AppSettings, 'settings after save')
  let s = (await get('/v1/settings')).body
  ok(s.quiet.enabled === false && s.quiet.from === '22:30' && s.quiet.to === '07:15' && s.quiet.alarms === false && s.brief.at === '09:00' && s.brief.agent === 'web' && s.quickReplies.join() === 'Ok,Later', 'POST /v1/settings saves every field')
  await post('/v1/settings', { quiet: { from: '25:99' }, brief: { at: 'quiet-end', agent: 'nobody-here' } })
  s = (await get('/v1/settings')).body
  ok(s.quiet.from === '22:30' && s.brief.at === 'quiet-end' && s.brief.agent === 'web', 'bad values are ignored, the rest is kept')
  await post('/v1/agents/lab/send', { text: 'Later' })
  t = await settled('lab')
  ok(t.entries.at(-1).suggestions?.join('|') === 'Ok|Later', 'the saved replies under an answer that asks follow the settings')
  await post('/v1/settings', { quickReplies: [] })
  ok(!(await timeline('lab')).entries.at(-1).suggestions?.length, 'with no saved replies, an answer that asks carries none (the app offers Yes and No)')

  section('Routines')
  const routine = (await timeline('chief')).routines[0]
  ok((await post('/v1/routines/enabled', { id: routine.id, enabled: !routine.enabled })).body.ok === true, 'POST /v1/routines/enabled')
  ok((await timeline('chief')).routines[0].enabled === !routine.enabled, 'the routine switched')
  ok((await post('/v1/routines/enabled', { id: 'nothing', enabled: true })).body.ok === false, 'an unknown routine says so')

  section('Share')
  r = await post('/v1/share', { url: 'https://example.com/article', note: 'Useful for us?' })
  ok(r.body.ok === true && typeof r.body.agent === 'string', 'POST /v1/share with a link goes to the Chief')
  r = await post('/v1/share', { agent: 'web', text: 'Some copied text' })
  ok(r.body.agent === 'web', 'POST /v1/share with a bot goes to that bot')
  ok((await post('/v1/share', {})).status === 400, 'sharing nothing is 400')
  t = await settled('web')
  ok(t.entries.some((e: any) => e.type === 'me' && e.text.includes('Some copied text')), 'the shared text shows in the chat')

  section('Phone: devices, pushes, live activity, calendar and contacts')
  ok((await post('/v1/devices', { token: DEVICE, env: 'sandbox' })).body.ok === true, 'POST /v1/devices')
  ok((await post('/v1/devices', { token: 'not a token' })).status === 400, 'a device token that is not hex is 400')
  r = await post('/v1/test-push', { title: 'Test' })
  check(r.body, Reply, 'test-push')
  ok(r.body.ok === true && r.body.devices === 1, 'POST /v1/test-push counts the registered device')
  ok((await post('/v1/devices/remove', { token: DEVICE })).body.ok === true, 'POST /v1/devices/remove')
  ok((await post('/v1/test-push')).body.devices === 0, 'the device is gone')
  ok((await post('/v1/live', { agent: 'web', token: DEVICE, startedAt: Date.now() / 1000 })).body.ok === true, 'POST /v1/live')
  ok((await post('/v1/live', { agent: 'web' })).status === 400, 'a live activity without token is 400')
  ok((await get('/v1/phone/calendar')).status === 404, 'GET /v1/phone/calendar is 404 before the phone shared anything')
  r = await post('/v1/phone/sync', { calendar: [{ title: 'Dentist', start: '2026-01-05T09:00:00.000Z' }], contacts: [{ name: 'Dana Example', phones: ['+100000000'] }, { name: 'Lee Sample' }] })
  ok(r.body.ok === true && (await home()).phoneShared === true, 'POST /v1/phone/sync, and home says the phone is shared')
  ok((await get('/v1/phone/calendar')).body.events.length === 1, 'GET /v1/phone/calendar')
  const contacts = (await get('/v1/phone/contacts?q=dana')).body
  ok(contacts.contacts.length === 1 && contacts.total === 2, 'GET /v1/phone/contacts?q= filters')
  ok((await post('/v1/phone/forget')).body.ok === true && (await home()).phoneShared === false, 'POST /v1/phone/forget')

  section('Search finds new messages')
  await post('/v1/agents/api/send', { text: 'Remember the word quokkaberry' })
  const hit = (await get('/v1/search?q=quokkaberry')).body
  ok(hit.messages.some((m: any) => m.agent === 'api' && m.role === 'user'), 'a message just sent is found')

  section('Reset')
  await reset()
  h = await home()
  ok(!h.agents.some((x: any) => x.id === 'docs-writer') && h.agents.length === 8, 'reset brings the first world back')
  ok((await post('/v1/demo/reset', {}, {})).status === 401, 'reset needs the token')
}

// ---------- what the server refuses, and what the `t3bot` command says and exits with ----------

async function guards() {
  const raw = async (path: string, body: string, headers: Record<string, string> = auth) => {
    const res = await fetch(BASE + path, { method: 'POST', headers: { ...headers, 'content-type': 'application/json' }, body })
    let parsed: any = null
    try { parsed = await res.json() } catch {}
    return { status: res.status, body: parsed }
  }
  section('Bodies the server refuses')
  for (const [body, words] of [['null', 'JSON object'], ['[1,2]', 'JSON object'], ['"text"', 'JSON object'], ['7', 'JSON object'], ['{"title":', 'not valid JSON']] as const) {
    const r = await raw('/v1/notify', body)
    ok(r.status === 400 && r.body?.ok === false && String(r.body?.error).includes(words), `POST /v1/notify with body ${body} is a 400 that says why`)
  }
  ok((await raw('/v1/notify', 'null', {})).status === 401, 'a bad body without the token is still 401: nothing is read before the token')
  ok((await raw('/v1/settings', '')).status === 200, 'an empty body is an empty object')
  const big = await raw('/v1/notify', JSON.stringify({ kind: 'do', title: 'x', body: 'y'.repeat(1024 * 1024 + 10) }))
  ok(big.status === 413 && /too large/.test(big.body?.error ?? ''), 'a notify body over 1 MB is 413')
  ok((await raw('/v1/agents/api/send', JSON.stringify({ text: 'z'.repeat(1024 * 1024 + 10) }))).status === 200, 'the routes that carry photos take more than 1 MB')
  const photo = await raw('/v1/agents/api/send', JSON.stringify({ images: ['A'.repeat(17 * 1024 * 1024)] }))
  ok(photo.status === 400 && /12 MB/.test(photo.body?.error ?? ''), 'a photo over 12 MB is refused with a 400')
  ok((await post('/v1/agents/api/send', { images: [null, 7, {}] })).status === 400, 'images that are not text are no message')
  for (const path of ['/v1/file?path=/etc/passwd', '/v1/file?path=/demo/assets/../demo.ts', '/v1/file?path=/demo/assets/..%2F..%2Fpackage.png', '/v1/file?path=', '/v1/file']) {
    ok((await get(path)).status === 404, `GET ${path} shows nothing`)
  }
  for (const path of ['/v1/avatars/..%2F..%2Fserver%2Fdemo.png', '/v1/avatars/skins/../../x.png', '/v1/avatars/UPPER.png']) {
    const r = await get(path, {})
    ok(r.status === 404 || r.status === 401, `GET ${path} serves no file`)
  }

  section('Notes are brought to what the app reads')
  ok((await post('/v1/notify', { kind: 'shout', title: 'x' })).status === 400, 'an unknown kind is 400')
  ok((await post('/v1/notify', { kind: 'do', title: { a: 1 } })).status === 400, 'a title that is not text is 400')
  ok((await post('/v1/notify', { kind: 'do', title: '   ' })).status === 400, 'a blank title is 400')
  const odd = await post('/v1/notify', {
    kind: 'approve', title: 42, body: 7, link: ['x'], key: 'guard-odd', fields: [{ label: 1, value: { deep: true } }, 'junk', null],
    checks: [{ label: 'Tests', state: 'green' }, { label: 'Build', state: 'pass' }], edit: { label: 5, text: 9 }, actions: [{ label: 'x'.repeat(500), message: 3 }, { nolabel: true }],
  })
  ok(odd.status === 200 && odd.body?.ok === true, 'a note with numbers where text belongs is accepted')
  let card = (await home()).needs.find((c: any) => c.key === 'guard-odd')
  ok(card && card.title === '42' && card.detail === '7' && card.link === undefined, 'title and body become text, a link that is not text is dropped')
  ok(card?.fields?.length === 1 && card.fields[0].label === '1' && typeof card.fields[0].value === 'string', 'fields are label and value as text, junk rows dropped')
  ok(card?.checks?.[0].state === 'pending' && card.checks[1].state === 'pass', 'a check state the app does not know becomes pending')
  ok(card?.edit?.label === '5' && card.edit.text === '9', 'the editable text is text')
  ok(card?.actions?.[0].label.length === 60 && card.actions[0].message === '3' && card.actions.length === 3, 'buttons: a bounded label, no button without one, then Done and Not now')
  if (card) check(card, Card, 'the odd note as a card')
  const dr = await post('/v1/notify', { kind: 'draft', title: 'Draft to Ana', key: 'guard-draft', draft: { to: 33612345678, text: 'Hi', secret: { a: 1 }, via: ['x'] } })
  card = (await home()).needs.find((c: any) => c.key === 'guard-draft')
  ok(dr.status === 200 && card?.draft?.to === '33612345678' && card.draft.text === 'Hi' && !('secret' in card.draft) && !('via' in card.draft), 'a draft keeps only the composer fields, as text')
  if (card) check(card, Card, 'the odd draft as a card')

  section('The t3bot command')
  const cli = async (argv: string[], env: Record<string, string> = {}) => {
    const p = Bun.spawn([process.execPath, join(import.meta.dir, '../bin/t3bot.ts'), ...argv],
      { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', env: { ...process.env, T3BOT_URL: BASE, T3BOT_TOKEN: TOKEN, ...env } })
    const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited])
    return { out, err, code }
  }
  let r = await cli(['notify', '--kind', 'do', '--title', 'Sign the lease', '--key', 'guard-cli', '--field', 'Rent=900 EUR', '--check', 'Papers=pass', '--action', 'Remind me=Remind me tomorrow'])
  ok(r.code === 0 && JSON.parse(r.out).ok === true && JSON.parse(r.out).kind === 'do', 'notify exits 0 and prints the note')
  card = (await home()).needs.find((c: any) => c.key === 'guard-cli')
  ok(card?.title === 'Sign the lease' && card.fields?.[0].value === '900 EUR' && card.checks?.[0].state === 'pass' && card.actions?.[0].label === 'Remind me', 'the card it made has its field, check and button')
  r = await cli(['notify', '--title', 'Tidied the logs'])
  ok(r.code === 0 && JSON.parse(r.out).kind === 'know', 'without --kind a note is a know')
  for (const [argv, words] of [
    [['notify', '--kind', 'do'], '--title'], [['notify', '--title'], '--title'], [['notify', '--title', 'x', '--kind', 'urgent'], '--kind'],
    [['notify', '--title', 'x', '--kind'], 'needs a value'], [['notify', '--title', 'x', '--boddy', 'y'], 'no option --boddy'],
    [['notify', '--title', 'x', '--body'], 'needs a value'], [['notify', '--title', 'x', '--field', '=5'], 'no label'],
    [['draft', '--to', 'Ana'], '--text'], [['draft', '--event', 'Dentist'], '--start'], [['draft', '--to', 'Ana', '--text', 'Hi', '--when', 'now'], 'no option --when'],
    [['nonsense'], 'no command'], [['phone'], 'calendar'],
  ] as const) {
    r = await cli([...argv])
    ok(r.code === 2 && r.err.includes(words) && !r.out.includes('"ok"'), `t3bot ${argv.join(' ')} exits 2 and names ${words}`)
  }
  r = await cli(['draft', '--to', 'Ana', '--text', 'On my way', '--key', 'guard-cli-draft'])
  ok(r.code === 0 && /sends it themselves/.test(r.out), 'draft exits 0 and says the person sends it')
  r = await cli(['notify', '--kind', 'do', '--title', 'x'], { T3BOT_URL: 'http://127.0.0.1:9' })
  ok(r.code === 1 && /did not answer/.test(r.err) && r.out === '', 'with the server down notify exits 1 and says it did not answer')
  r = await cli(['notify', '--kind', 'do', '--title', 'x'], { T3BOT_TOKEN: 'not-the-token-at-all' })
  ok(r.code === 1 && /refused the token/.test(r.err) && !r.err.includes('not-the-token-at-all'), 'with a wrong token notify exits 1, says so and does not print the token')
  r = await cli(['needs', '--json'])
  ok(r.code === 0 && Array.isArray(JSON.parse(r.out)), 'needs --json prints the list')
  r = await cli(['help'])
  ok(r.code === 0 && !r.out.includes('\u2014') && !r.out.includes('\u2013'), 'help has no long dashes')
  for (const word of ['notify', 'draft', 'phone', 'needs', 'roster', 'home', 'agent', 'setup', 'pair', 'doctor', 'demo', 'connect', 'version', '--force', '--face-id', '--edit-label', 'Exit codes']) {
    ok(r.out.includes(word), `help mentions ${word}`)
  }
  await post('/v1/demo/reset')
}

// ---------- second pass: methods, real callers of `t3bot notify`, the push request, where the demo listens ----------

/** A port nothing listens on, from 8850 up. */
function freePort(from = 8850): number {
  for (let p = from; p < from + 60; p++) {
    try { Bun.serve({ port: p, hostname: '127.0.0.1', fetch: () => new Response('') }).stop(true); return p } catch {}
  }
  throw new Error('no free port from 8850 up')
}

async function secondPass() {
  section('Wrong methods, on the running server')
  const ask = async (method: string, path: string, headers: Record<string, string> = auth) => {
    const res = await fetch(BASE + path, { method, headers })
    return { status: res.status, allow: res.headers.get('allow'), body: await res.json().catch(() => null) as any }
  }
  let a = await ask('PUT', '/v1/home')
  ok(a.status === 405 && a.allow === 'GET' && typeof a.body?.error === 'string', 'PUT /v1/home is 405 with Allow: GET and a sentence')
  a = await ask('GET', '/v1/notify')
  ok(a.status === 405 && a.allow === 'POST', 'GET /v1/notify is 405 with Allow: POST')
  a = await ask('DELETE', '/v1/settings')
  ok(a.status === 405 && a.allow === 'GET, POST', 'DELETE /v1/settings is 405 with Allow: GET, POST')
  a = await ask('POST', '/v1/agents/web')
  ok(a.status === 405 && a.allow === 'GET', 'POST /v1/agents/web is 405 with Allow: GET')
  a = await ask('GET', '/v1/agents/web/send')
  ok(a.status === 405 && a.allow === 'POST', 'GET /v1/agents/web/send is 405 with Allow: POST')
  for (const method of ['GET', 'POST', 'PUT', 'DELETE']) ok((await ask(method, '/v1/nothing-here')).status === 404, `${method} on an unknown path is still 404`)
  a = await ask('PUT', '/v1/home', {})
  ok(a.status === 401 && a.allow === null, 'without a token a wrong method is 401, and nothing says the path exists')
  ok((await ask('GET', '/v1/home')).status === 200 && (await post('/v1/settings', {})).status === 200, 'the right methods answer as before')
  ok((await ask('POST', '/v1/agents/no-such-bot/send')).status === 404, 'the right method on a bot that does not exist is still 404')

  section('The calls real automations make to t3bot notify')
  const tmp = mkdtempSync(join(tmpdir(), 't3bot-check-'))
  try {
    // `crew` was the command's first name and scripts still call it: a link to the same wrapper.
    symlinkSync(join(import.meta.dir, '../bin/t3bot'), join(tmp, 'crew'))
    const run = async (bin: string, argv: string[]) => {
      const p = Bun.spawn([bin, ...argv], { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe',
        env: { ...process.env, PATH: `${dirname(process.execPath)}:${process.env.PATH ?? ''}`, T3BOT_URL: BASE, T3BOT_TOKEN: TOKEN } })
      const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited])
      return { out, err, code }
    }
    const t3bot = join(import.meta.dir, '../bin/t3bot'), crew = join(tmp, 'crew')
    const cardOf = async (key: string) => (await home()).needs.find((c: any) => c.key === key)
    // A cost alarm: a title of about 120 characters and a body of 900 with line breaks, for a bot this server may not have.
    const lines = Array.from({ length: 12 }, (_, i) => `Vercel spend for project-${i} is 4.2 times its 14 day average: $${i}.40 today, usually $0.3${i}`)
    const title = `${lines[0].slice(0, 110)} (+11 more)`, body = lines.join('\n').slice(0, 900)
    let r = await run(t3bot, ['notify', '--agent', 'costs', '--kind', 'alarm', '--title', title, '--body', body, '--key', 'cost-watch-2026-11-11'])
    let c = await cardOf('cost-watch-2026-11-11')
    ok(r.code === 0 && JSON.parse(r.out).ok === true, 'a cost alarm (long title, 900 character body, a key) exits 0')
    ok(c?.kind === 'alarm' && c.rank === 0 && c.title === title && c.detail === body, 'its title and its body arrive whole, line breaks included')
    if (c) check(c, Card, 'the cost alarm as a card')
    r = await run(t3bot, ['notify', '--agent', 'web', '--kind', 'do', '--title', 'Moorline could not send your reply to Ana', '--key', 'moorline-approval-12', '--body', 'SMTP timeout. It is in the conversation in Moorline with Retry.'])
    c = await cardOf('moorline-approval-12')
    ok(r.code === 0 && c?.kind === 'do' && c.agent === 'web' && /Retry\.$/.test(c.detail), 'a do note with --agent, --key and --body, in any order, lands on that bot')
    r = await run(t3bot, ['notify', '--agent', 'web', '--kind', 'know', '--title', 'Moorline sent your reply to Ana', '--key', 'moorline-approval-13'])
    const know = (await get('/v1/know')).body?.notes ?? []
    ok(r.code === 0 && know.some((n: any) => n.title === 'Moorline sent your reply to Ana' && n.kind === 'know'), 'a know note with no body goes to the digest')
    r = await run(t3bot, ['notify', '--agent', 'chief', '--kind', 'approve', '--title', 'Reply to Ana is ready', '--key', 'compat-approve'])
    ok(r.code === 0 && (await cardOf('compat-approve'))?.kind === 'approve', 'approve is a kind')
    r = await run(crew, ['notify', '--agent', 'chief', '--kind', 'do', '--title', 'Message Hugo on Instagram', '--body', 'You asked yesterday to be reminded this morning.', '--key', 'remind-hugo'])
    ok(r.code === 0 && (await cardOf('remind-hugo'))?.title === 'Message Hugo on Instagram', 'the old command name (a link called crew) still sends a note')
    r = await run(t3bot, ['notify', '--kind', 'ALARM', '--title', 'Site down', '--key', 'compat-caps'])
    ok(r.code === 0 && (await cardOf('compat-caps'))?.kind === 'alarm', 'a kind written in capitals is taken')
    r = await run(t3bot, ['notify', '--kind', 'do', '--title', '-12% trials this week', '--body', '-- see the log, then --force if needed', '--key', 'compat-dashes'])
    c = await cardOf('compat-dashes')
    ok(r.code === 0 && c?.title === '-12% trials this week' && c.detail === '-- see the log, then --force if needed', 'a title or body that starts with dashes is text, not an option')
    r = await run(t3bot, ['notify', '--kind', 'do', '--title', 'Empty body', '--body', '', '--key', 'compat-empty'])
    ok(r.code === 0 && (await cardOf('compat-empty'))?.detail === undefined, 'an empty --body is a note without a body, not an error')
    const direct = await post('/v1/notify', { kind: ' Do ', title: 'Posted without the command', key: 'compat-direct', agent: 'web', extra: { ignored: true }, urgency: 'now' })
    ok(direct.status === 200 && (await cardOf('compat-direct'))?.kind === 'do', 'a script that posts the JSON itself, with fields the server does not know, is taken')
    const h = await home()
    check(h, Home, 'home after the automations wrote to it')
  } finally { rmSync(tmp, { recursive: true, force: true }) }

  section('The push request, sent to a local stand-in for APNs with a throwaway key')
  const keyDir = mkdtempSync(join(tmpdir(), 't3bot-check-key-'))
  const seen: { auth: string | null; topic: string | null; method: string; path: string; body: string; ps: string }[] = []
  const apnsPort = freePort()
  const apns = Bun.serve({ port: apnsPort, hostname: '127.0.0.1', async fetch(req) {
    const u = new URL(req.url)
    // What any other process on this computer could read while the request is on its way.
    const ps = Bun.spawnSync(['ps', '-axww', '-o', 'args=']).stdout.toString()
    seen.push({ auth: req.headers.get('authorization'), topic: req.headers.get('apns-topic'), method: req.method, path: u.pathname, body: await req.text(), ps })
    return u.pathname.endsWith('/dead') ? Response.json({ reason: 'Unregistered' }, { status: 410 }) : new Response('')
  } })
  try {
    const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
    const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
    const keyPath = join(keyDir, 'AuthKey_THROWAWAY1.p8')
    writeFileSync(keyPath, `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----\n`, { mode: 0o600 })
    chmodSync(keyPath, 0o600)
    const jwt = await apnsToken({ keyId: 'THROWAWAY1', teamId: 'TEAM123456', keyPath, topic: 'com.example.t3bot' })
    const [h64, b64, s64] = jwt.split('.')
    const unb64 = (x: string) => Buffer.from(x.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
    const head = JSON.parse(unb64(h64).toString()), claims = JSON.parse(unb64(b64).toString())
    ok(head.alg === 'ES256' && head.kid === 'THROWAWAY1' && claims.iss === 'TEAM123456' && Math.abs(claims.iat - Date.now() / 1000) < 60, 'the provider token names the key, the team and now')
    ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey, unb64(s64), new TextEncoder().encode(`${h64}.${b64}`)), 'its signature is the throwaway key\'s')
    const payload = JSON.stringify({ aps: { alert: { title: 'Ana: "ready?" \\o/', body: 'Line one\nLine two\ttabbed, C:\\dir, 100% #1 $HOME café 🙂 \'single\'' }, sound: 'default' }, t3bot: { agent: 'web' } })
    const headers = [`authorization: bearer ${jwt}`, 'apns-topic: com.example.t3bot', 'apns-push-type: alert', 'apns-priority: 10']
    const device = 'ab12cd34'.repeat(8)
    const sent = await apnsPost(`http://127.0.0.1:${apnsPort}`, device, headers, payload)
    const got = seen[0]
    ok(sent.code === '200' && seen.length === 1, 'the request arrives and its answer is read (200)')
    ok(got?.method === 'POST' && got.path === `/3/device/${device}`, 'it is a POST to the device')
    ok(got?.auth === `bearer ${jwt}` && got.topic === 'com.example.t3bot', 'the token and the topic arrive as headers')
    ok(got?.body === payload, 'the payload arrives byte for byte (quotes, backslashes, line breaks, accents)')
    const curlLine = (got?.ps ?? '').split('\n').find((l) => l.includes('curl') && l.includes('--config'))
    ok(!!curlLine && curlLine.includes('--http2'), 'while it is sent, ps shows curl with --http2 and --config')
    ok(!!got && !got.ps.includes(jwt) && !got.ps.includes(s64) && !got.ps.includes('bearer'), 'ps shows no token')
    ok(!!got && !got.ps.includes(device) && !got.ps.includes('ready?') && !got.ps.includes('apns-topic'), 'ps shows no device, no header and none of the message')
    const dead = await apnsPost(`http://127.0.0.1:${apnsPort}`, 'dead', headers, payload)
    ok(dead.code === '410' && dead.body.includes('Unregistered'), 'a refusal still comes back with its code and reason (410)')
    const before = seen.length
    const split = await apnsPost(`http://127.0.0.1:${apnsPort}`, device, [...headers, 'apns-collapse-id: x\nurl = "http://127.0.0.1:9/"'], payload)
    const slash = await apnsPost(`http://127.0.0.1:${apnsPort}`, '../../x', headers, payload)
    ok(split.code === '0' && slash.code === '0' && seen.length === before, 'a header with a line break, or a device that is not letters and digits, is not sent at all')
    const down = await apnsPost('http://127.0.0.1:9', device, headers, payload)
    ok(down.code !== '200' && !down.body.includes(jwt), 'when the other side is down the answer says so, without the token')
  } finally { apns.stop(true); rmSync(keyDir, { recursive: true, force: true }) }

  section('The demo listens on this computer only, unless asked')
  const lan = Object.values(networkInterfaces()).flat().find((i) => i && i.family === 'IPv4' && !i.internal)?.address
  const reach = async (host: string, port: number) => { try { return (await fetch(`http://${host}:${port}/health`, { signal: AbortSignal.timeout(1500) })).status === 200 } catch { return false } }
  const start = async (argv: string[], env: Record<string, string> = {}) => {
    const port = freePort(apnsPort + 1)
    const cleanEnv: Record<string, string> = { ...(process.env as Record<string, string>), ...env }
    if (!('T3BOT_DEMO_HOST' in env)) delete cleanEnv.T3BOT_DEMO_HOST
    const p = Bun.spawn([process.execPath, join(import.meta.dir, 'demo.ts'), '--port', String(port), '--no-banner', ...argv], { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', env: cleanEnv })
    let up = false
    for (let i = 0; i < 40 && !up && p.exitCode === null; i++) { await sleep(150); up = await reach('127.0.0.1', port) }
    const onLan = lan ? await reach(lan, port) : null
    p.kill(); await p.exited
    return { up, onLan, line: (await new Response(p.stdout).text()).split('\n')[0] }
  }
  let d = await start([])
  ok(d.up && /127\.0\.0\.1:\d+: this computer only/.test(d.line) && d.line.includes('--lan'), 'by default it listens on 127.0.0.1, and its first line says so and names --lan')
  if (lan) ok(d.onLan === false, 'by default it does not answer on the network address')
  d = await start(['--lan'])
  ok(d.up && /0\.0\.0\.0:\d+: open to your network/.test(d.line) && d.line.includes('"demo"'), 'with --lan it listens on every address, and its first line warns about the public token')
  if (lan) ok(d.onLan === true, 'with --lan it answers on the network address')
  d = await start([], { T3BOT_DEMO_HOST: '0.0.0.0' })
  ok(d.up && /open to your network/.test(d.line), 'T3BOT_DEMO_HOST=0.0.0.0 opens it too')
  d = await start(['--host', '127.0.0.1'], { T3BOT_DEMO_HOST: '0.0.0.0' })
  ok(d.up && /this computer only/.test(d.line), '--host wins over the environment')
  const help = Bun.spawnSync([process.execPath, join(import.meta.dir, '../bin/t3bot.ts'), 'help']).stdout.toString()
  ok(help.includes('--lan') && help.includes('T3BOT_DEMO_HOST') && /this computer only \(127\.0\.0\.1\)/.test(help), 'help says where the demo listens and how to open it')
  await post('/v1/demo/reset')
}

// ---------- frozen servers answer the same twice ----------

async function steady() {
  const one = (await get('/v1/home')).raw
  await sleep(1200)
  const two = (await get('/v1/home')).raw
  const same = one === two
  if (!same) return false
  section('Frozen: two captures match')
  for (const path of ['/v1/home', '/v1/agents/web', '/v1/agents/chief', '/v1/agents/api', '/v1/know', '/v1/settings', '/v1/search?q=pricing']) {
    const a = (await get(path)).raw
    await sleep(300)
    ok(a === (await get(path)).raw, `GET ${path} is byte for byte the same twice`)
  }
  return true
}

// ---------- the text rules both servers share (server/text.ts) ----------

function rules() {
  section('Guards (server/guard.ts)')
  const at = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3))
  for (const [from, to, time, quiet] of [
    ['23:00', '08:00', '22:59', false], ['23:00', '08:00', '23:00', true], ['23:00', '08:00', '23:59', true], ['23:00', '08:00', '00:00', true],
    ['23:00', '08:00', '07:59', true], ['23:00', '08:00', '08:00', false], ['23:00', '08:00', '12:00', false],
    ['01:00', '07:00', '00:59', false], ['01:00', '07:00', '01:00', true], ['01:00', '07:00', '06:59', true], ['01:00', '07:00', '07:00', false], ['01:00', '07:00', '23:30', false],
    ['00:00', '00:00', '00:00', false], ['09:00', '09:00', '09:00', false], ['00:00', '23:59', '23:58', true], ['00:00', '23:59', '23:59', false],
    ['23:59', '00:00', '23:59', true], ['23:59', '00:00', '00:00', false], ['25:00', '08:00', '02:00', false], ['23:00', '', '02:00', false],
  ] as const) ok(inQuiet(from, to, at(time)) === quiet, `quiet ${from} to ${to}: ${time} is ${quiet ? 'inside' : 'outside'}`)
  for (const [start, time, since] of [['08:00', '08:00', 0], ['08:00', '10:59', 179], ['08:00', '11:00', 180], ['08:00', '07:59', 1439],
    ['22:30', '23:59', 89], ['22:30', '00:00', 90], ['22:30', '01:29', 179], ['22:30', '01:30', 180], ['00:00', '00:00', 0], ['8:00', '09:00', -1], ['', '09:00', -1]] as const) {
    ok(minutesSince(start, at(time)) === since, `the brief of ${start || 'no time'}: at ${time} it is ${since} minutes in`)
  }
  ok(bodyLimit('/v1/notify') === 1024 * 1024 && bodyLimit('/v1/settings') === 1024 * 1024, 'small routes read 1 MB at most')
  ok(bodyLimit('/v1/agents/chief/send') > 30e6 && bodyLimit('/v1/share') > 30e6, 'send and share have room for photos')
  ok(bodyLimit('/v1/agents/chief/send/x') === 1024 * 1024 && bodyLimit('/v1/agents/Chief/send') === 1024 * 1024, 'only the exact send route does')
  ok(overLimit('/v1/notify', '2000000') && !overLimit('/v1/notify', '2000') && !overLimit('/v1/notify', null) && !overLimit('/v1/notify', 'abc'), 'the declared length is checked')
  ok(overLimit('/v1/notify', null, 2e6) && !overLimit('/v1/share', null, 2e6), 'and so is what was read')
  ok(readBody('').body && readBody('  \n').body && readBody('{"a":1}').body?.a === 1, 'an empty body is an empty object, an object is itself')
  for (const bad of ['null', '[]', '"x"', '3', 'true', '{', 'x']) ok(readBody(bad).error && !readBody(bad).body, `the body ${bad} is refused`)
  const thrown = (fn: () => unknown) => { try { fn(); return null } catch (e) { return e } }
  // A card's link: what would act inside the app, or name a file or a script, is dropped; the rest is kept as sent.
  for (const bad of ['t3bot://connect?url=http://x&token=y', 'T3Bot://connect', ' t3bot://connect', 't3\tbot://connect', 'javascript:alert(1)', 'JAVASCRIPT:x', 'java\nscript:x', 'data:text/html,x', 'file:///etc/passwd', 'https://x/\u0000']) {
    ok(safeLink(bad) === '' && tidyNote({ title: 'x', link: bad }).link === undefined, `a card link ${JSON.stringify(bad)} is dropped`)
    ok(storedNote({ id: 'n', kind: 'do', title: 'x', link: bad })!.link === undefined, `a stored card link ${JSON.stringify(bad)} is dropped`)
  }
  for (const good of ['https://example.com/a?b=c#d', 'http://127.0.0.1:3000', 'mailto:a@example.com', 't3://thread/1', 'example.com/page', 'x-t3bot-other://y']) {
    ok(safeLink(good) === good && tidyNote({ title: 'x', link: good }).link === good, `a card link ${good} is kept`)
  }
  // /v1/file: the file asked for must itself be a picture under the home or temp folders.
  {
    const dir = mkdtempSync(join(tmpdir(), 't3bot-file-'))
    try {
      const real = (p: string) => realpathSync(p)
      const home = real(dir)
      writeFileSync(join(dir, 'a.png'), 'x'); writeFileSync(join(dir, 'secret.txt'), 'x')
      symlinkSync(join(dir, 'secret.txt'), join(dir, 'link.png'))
      symlinkSync(join(dir, 'a.png'), join(dir, 'good.jpg'))
      symlinkSync('/etc/hosts', join(dir, 'hosts.png'))
      ok(servableImage(join(dir, 'a.png'), home, real) === join(home, 'a.png'), 'a picture under the home folder is served')
      ok(servableImage(join(dir, 'good.jpg'), home, real) === join(home, 'a.png'), 'a link to a picture is served as the picture')
      ok(servableImage(join(dir, 'link.png'), home, real) === null, 'a link named .png that points at a text file is refused')
      ok(servableImage(join(dir, 'hosts.png'), home, real) === null, 'a link named .png that points outside is refused')
      ok(servableImage(join(dir, 'secret.txt'), home, real) === null && servableImage(join(dir, 'none.png'), home, real) === null, 'a file that is not a picture, or not there, is refused')
      ok(servableImage(join(dir, '..', 'a.png'), home, real) === null && servableImage('a.png', home, real) === null, 'a path that leaves the folder or is not absolute is refused')
      ok(servableImage(join(dir, 'a.png'), '/nowhere', (p) => p.replace(home, '/Users/x/.ssh')) === null, 'a picture in a folder of secrets is refused')
    } finally { rmSync(dir, { recursive: true, force: true }) }
  }
  for (const bad of [null, 'x', [], {}, { title: '' }, { title: [] }, { title: 'x', kind: 'nope' }, { title: 'x', kind: 5 }, { title: 'x', kind: '' }]) {
    ok(thrown(() => tidyNote(bad)) instanceof BadInput, `tidyNote refuses ${JSON.stringify(bad)}`)
  }
  const note = tidyNote({ title: `  ${'t'.repeat(999)}`, body: 'b'.repeat(99999), key: 'k'.repeat(999), link: 'l'.repeat(9999), agent: 12,
    fields: Array.from({ length: 99 }, () => ({ label: 'l'.repeat(999), value: 'v'.repeat(9999) })), checks: [{ label: 'c', state: 'pass' }, { label: 'c', state: { x: 1 } }, 5],
    edit: { text: 'e'.repeat(99999) }, actions: Array.from({ length: 30 }, (_, i) => ({ label: `Go ${i}`, handler: i === 0 ? 'ship' : undefined, faceId: i === 1 ? 0 : undefined })),
    draft: 'not a draft' })
  ok(note.kind === 'know' && note.title.length === 300 && note.body!.length === 8000 && note.key!.length === 200 && note.link!.length === 2000 && note.agent === '12', 'tidyNote bounds every text')
  ok(note.fields!.length === 40 && note.fields![0].label.length === 200 && note.fields![0].value.length === 2000, 'at most 40 fields, each bounded')
  ok(note.checks!.length === 2 && note.checks![0].state === 'pass' && note.checks![1].state === 'pending', 'checks keep the three states only')
  ok(note.edit!.label === 'Text' && note.edit!.text.length === 20000, 'the editable text is bounded and labelled')
  ok(note.actions!.length === 6 && note.actions![0].handler === 'ship' && note.actions![0].id === 'a0' && note.actions![1].faceId === false && note.actions![2].faceId === undefined, 'at most six buttons')
  ok(Object.keys(note.draft).length === 0 && JSON.stringify(tidyNote({ title: 'x', kind: 'draft', draft: { to: 5, text: ' hi ', nope: 1, start: null } }).draft) === '{"to":"5","text":"hi"}', 'a draft holds composer fields as text')
  ok(tidyNote({ title: 'x' }).fields === undefined && tidyNote({ title: 'x', actions: [] }).actions!.length === 0, 'what was not sent stays unset')

  section('Stored notes are read back in the shape the app decodes')
  const NoteCardParts: Spec = {
    id: 'string', agent: 'string', kind: 'string', title: 'string', body: 'string?', link: 'string?', key: 'string?', created_at: 'date',
    'fields?': [{ label: 'string', value: 'string' }], 'checks?': [{ label: 'string', state: 'string' }], 'edit?': { label: 'string', text: 'string' },
    'actions?': [{ id: 'string', label: 'string', kind: 'string', style: 'string?', faceId: 'bool?' }],
  }
  // A note exactly as today's server saves it comes back unchanged: nothing valid is dropped or altered.
  const good = {
    id: 'chief:lease', agent: 'chief', kind: 'do', title: 'Sign the lease', body: 'Before Friday.\nTwo pages.', link: 'https://example.com/lease', key: 'lease',
    created_at: '2026-11-10T09:00:00.000Z', read_at: null,
    data: JSON.stringify({ fields: [{ label: 'Rent', value: '900 EUR' }], checks: [{ label: 'Papers', state: 'pass' }], edit: { label: 'Reply', text: ' keep my spaces ' },
      actions: [{ id: 'a0', label: 'Remind me', kind: 'message', style: 'primary', faceId: false, message: 'Remind me tomorrow' }, { id: 'done', label: 'Done', kind: 'done' }, { id: 'snooze', label: 'Not now', kind: 'snooze' }], faceId: false }),
  }
  const back = storedNote(good)!
  ok(back.id === good.id && back.agent === 'chief' && back.kind === 'do' && back.title === good.title && back.body === good.body && back.link === good.link && back.key === 'lease' && back.created_at === good.created_at, 'a valid note keeps its id, bot, kind, title, body, link, key and date')
  ok(JSON.stringify({ fields: back.fields, checks: back.checks, edit: back.edit, actions: back.actions, faceId: back.faceId }) === JSON.stringify(JSON.parse(good.data)), 'a valid note keeps its fields, checks, text and buttons exactly')
  check(back, NoteCardParts, 'a valid stored note')
  // Notes as an older server could have saved them: wrong types everywhere. Each is kept and made readable.
  const old: [string, any][] = [
    ['a title and body saved as numbers', { id: 'n1', agent: 'web', kind: 'alarm', title: 42, body: 7, link: 3, key: 9, created_at: '2026-11-01T08:00:00Z', data: null }],
    ['data that is not JSON', { id: 'n2', agent: 'web', kind: 'do', title: 'x', created_at: '2026-11-01T08:00:00Z', data: '{not json' }],
    ['data that is a list', { id: 'n3', agent: 'web', kind: 'do', title: 'x', created_at: '2026-11-01T08:00:00Z', data: '[1,2]' }],
    ['card parts that are not lists', { id: 'n4', agent: 'web', kind: 'approve', title: 'x', created_at: '2026-11-01T08:00:00Z', data: JSON.stringify({ fields: 'Rent=900', checks: { label: 'a' }, edit: 'text', actions: 5, faceId: 'yes' }) }],
    ['values of the wrong type inside the lists', { id: 'n5', agent: 'web', kind: 'approve', title: 'x', created_at: '2026-11-01T08:00:00Z', data: JSON.stringify({
      fields: [{ label: 1, value: { deep: true } }, 'junk', null, { value: 'no label' }], checks: [{ label: 'Tests', state: 'green' }, { label: 5, state: null }],
      edit: { label: 5, text: 9 }, actions: [{ label: 'Go', id: 7, kind: 3, style: {}, faceId: 'x', message: 4 }, { nolabel: true }, 'junk'] }) }],
    ['no title, no date, a bot saved as a number', { id: 'n6', agent: 12, kind: 'do', title: null, created_at: 5, data: '{}' }],
    ['a draft with fields the composer does not take', { id: 'n7', agent: 'web', kind: 'draft', title: 'Draft to Ana', created_at: '2026-11-01T08:00:00Z', data: JSON.stringify({ to: 33612345678, text: 'Hi', via: ['x'], secret: { a: 1 }, start: null }) }],
    ['a know note with a number as its title', { id: 'n8', agent: 'web', kind: 'know', title: 2026, body: { a: 1 }, created_at: '2026-11-01T08:00:00Z' }],
    ['very long texts', { id: 'n9', agent: 'web', kind: 'do', title: 't'.repeat(5000), body: 'b'.repeat(99999), created_at: '2026-11-01T08:00:00Z', data: JSON.stringify({ fields: Array.from({ length: 500 }, (_, i) => ({ label: `f${i}`, value: 'v'.repeat(9999) })) }) }],
  ]
  for (const [what, row] of old) {
    const n = storedNote(row)
    ok(n !== null && n.id === row.id, `an old note with ${what} is kept`)
    if (n) check(JSON.parse(JSON.stringify(n)), NoteCardParts, `an old note with ${what}`)
    if (n?.draft) check(n.draft, Draft, `the draft of an old note with ${what}`)
  }
  const n5 = storedNote(old[4][1])!, n6 = storedNote(old[5][1])!, n9 = storedNote(old[8][1])!
  ok(n5.fields!.length === 2 && n5.fields![0].label === '1' && n5.fields![0].value === '' && n5.checks![0].state === 'pending' && n5.edit!.text === '9' && n5.actions!.length === 1 && n5.actions![0].kind === '3', 'wrong values become text, an unknown check state is pending, a button without a label is left out')
  ok(n6.title === '(no title)' && n6.agent === '12' && n6.created_at === '1970-01-01T00:00:00.000Z', 'a note with no title or date still has both')
  ok(n9.title.length === 300 && n9.body!.length === 8000 && n9.fields!.length === 40 && n9.fields![0].value.length === 2000, 'old texts get the sizes new ones have')
  ok(storedNote(old[3][1])!.actions === undefined && storedNote(old[3][1])!.fields === undefined && storedNote(old[3][1])!.faceId === true, 'parts that cannot be read are left out, so the card shows its usual buttons')
  ok(JSON.stringify(storedNote(old[6][1])!.draft) === '{"to":"33612345678","text":"Hi"}', 'an old draft holds only composer fields, as text')
  ok(storedNote({ id: '', kind: 'do', title: 'x' }) === null && storedNote({ id: 'x', kind: 'shout', title: 'x' }) === null && storedNote(null) === null && storedNote('x') === null, 'only a row with no id or an unknown kind is not a note')
  ok(storedNote({ id: ' padded ', kind: 'do', title: 'x', created_at: 'x' })!.id === ' padded ', "a note's id is never altered (its buttons find the row by it)")
  ok(storedNote(old[0][1])!.created_at === '2026-11-01T08:00:00.000Z' && storedNote({ id: 'z', kind: 'do', title: 'x', created_at: '2026-11-01T10:00:00+02:00' })!.created_at === '2026-11-01T08:00:00.000Z', 'a date saved in another form goes out as the same moment in the form the server writes')

  // The real server cannot be started by these checks, so its source is read: both places that hand notes to the app go through storedNote.
  const real = readFileSync(join(import.meta.dir, 't3bot.ts'), 'utf8')
  ok(/function noteCards\(\)[\s\S]{0,600}storedNote\(row\)/.test(real), 't3bot.ts: the cards on /v1/home are built from storedNote')
  ok(/path === '\/v1\/know'[\s\S]{0,600}storedNote\(row\)/.test(real), 't3bot.ts: the notes on /v1/know are read through storedNote')

  section('A wrong method on a known path is 405')
  const demoOnly: [RegExp, string][] = [[/^\/v1\/(cards\/undo|demo\/reset)$/, 'POST']]
  for (const file of ['t3bot.ts', 'demo.ts']) {
    const src = readFileSync(join(import.meta.dir, file), 'utf8')
    const routes = [...src.matchAll(/path === '(\/v1\/[^']+)' && (GET|POST)/g)]
    ok(routes.length >= 20, `${file}: its routes were found (${routes.length})`)
    for (const [, path, method] of routes) {
      ok(wrongMethod(path, method, demoOnly) === null && (wrongMethod(path, 'DELETE', demoOnly) ?? '').includes(method), `${file}: ${method} ${path} is in the table of methods`)
    }
  }
  ok(wrongMethod('/v1/home', 'POST') === 'GET' && wrongMethod('/v1/notify', 'GET') === 'POST' && wrongMethod('/v1/settings', 'PUT') === 'GET, POST', 'the Allow header names the methods the path takes')
  ok(wrongMethod('/v1/agents/web', 'POST') === 'GET' && wrongMethod('/v1/agents/web/send', 'GET') === 'POST' && wrongMethod('/v1/cards/done', 'GET') === 'POST', 'paths with a bot id or a card action are known too')
  ok(wrongMethod('/v1/nothing-here', 'GET') === null && wrongMethod('/v1/cards/undo', 'GET') === null && wrongMethod('/v1/agents/UPPER', 'POST') === null && wrongMethod('/', 'PUT') === null, 'an unknown path has no Allow header (it stays 404)')
  ok(kindOf(undefined) === 'know' && kindOf(null) === 'know' && kindOf(' ALARM ') === 'alarm' && kindOf('Do') === 'do', 'a kind is read in any case, and is know when left out')
  ok(tidyNote({ title: 'x', kind: 'Approve' }).kind === 'approve' && thrown(() => tidyNote({ title: 'x', kind: 'urgent' })) instanceof BadInput, 'a kind in capitals is taken, a kind that does not exist is still refused')

  section('The push request keeps the token off the command line')
  const cfgText = curlConfig('https://api.push.apple.com/3/device/ab12', ['authorization: bearer aaa.bbb.ccc', 'apns-topic: com.example.app'], '{"a":"say \\"hi\\"\\n","b":"C:\\\\dir"}')
  ok(CURL_ARGS.includes('--http2') && CURL_ARGS.includes('--config') && CURL_ARGS[CURL_ARGS.length - 1] === '-', 'curl still speaks HTTP/2 and reads its options from stdin')
  ok(!CURL_ARGS.some((a) => /bearer|authorization|https?:|device/i.test(a)), 'the command line holds no token, header, address or device')
  ok(cfgText.split('\n').length === 6 && cfgText.endsWith('\n') && cfgText.includes('header = "authorization: bearer aaa.bbb.ccc"'), 'the options are one per line: address, method, headers, payload')
  ok(cfgText.includes(String.raw`data-binary = "{\"a\":\"say \\\"hi\\\"\\n\",\"b\":\"C:\\\\dir\"}"`), 'quotes and backslashes in the payload are escaped for curl')

  section('Text rules both servers share')
  const photo = '[Image from Sam: /Users/sam/shot.png (open it to see it)]'
  ok(preview(photo) === 'Photo', 'a message that is only a photo line reads "Photo"')
  ok(preview(`${photo}\n${photo.replace('shot', 'two')}`) === 'Photo', 'so do two photo lines')
  ok(preview(`Look at this\n\n${photo}`) === 'Look at this', 'a photo line is left out of the preview')
  ok(preview('![chart](/Users/sam/chart.png)') === 'Photo', 'an answer that is only a picture reads "Photo"')
  ok(preview('', 160, 1) === 'Photo' && preview('') === '', 'an empty message reads "Photo" only when it had a picture')
  ok(preview('One two three four five six seven eight nine ten', 20) === 'One two three four…', 'a long preview is cut between words')
  ok(preview('| Metric | Before |\n|---|---:|\n|Weight|2.6 MB|') === 'Metric Before Weight 2.6 MB', 'a table in a preview keeps its cells apart and loses its rule line')
  ok(preview('## Done\n> Called `read_file` on **PR #12**, _twice_') === 'Done Called read_file on PR #12, twice', 'a preview loses its markdown marks and keeps names and numbers whole')

  const long = 'Before the table there is a sentence that is long enough to push the numbers past the first sixty characters of the message.\n\n| Metric | Before | After |\n|---|---|---|\n| Page weight | 2.6 MB | 610 KB |\n| Speed score | 61 | 97 |\n\n- one item\n- another item\n\n```bash\nbun run build\nbun run links\n```\n\nAfter the table the message goes on for a while so that the end of the snippet has to be cut as well, somewhere in here.'
  const sn = snippet(long, '610')
  ok(sn.startsWith('…') && sn.endsWith('…'), `a snippet cut at both ends has an ellipsis at both (${sn})`)
  ok(sn.includes('Page weight: 2.6 MB, 610 KB · Speed score: 61, 97 · one item · another item · bun run build · bun run links'), 'rows, list items and code lines stay apart')
  ok(!/[|`]/.test(sn) && sn.length <= 204, 'no pipes or fences, about 200 characters')
  ok(snippet('A short message', 'short') === 'A short message', 'a short message is its own snippet, with no ellipsis')
  ok(snippet(long, 'nothing like this').startsWith('Before the table'), 'without a match the snippet is the start of the message')
  ok(snippet('Call `read_file` on it', 'read_file').includes('read_file'), 'names with an underscore stay whole')

  const no = ['Done. The check passes and nothing else changed.', 'Live.\n\n- Build: 41 s\n- Paint: 1.1 s', 'Why did it break? The cache was stale. I fixed it and added a test.', 'See https://example.com/a?b=1 for details.', '```\nwhat?\n```', '']
  const yes = ['Want me to ship it?', 'Which do you prefer?\n\n- A: fast\n- B: safe', 'I found two ways. Tell me which one you want.', 'It is ready. Should I send it now or wait for Monday.', 'Is it "done"?']
  for (const t of no) ok(!asks(t), `asks nothing: ${JSON.stringify(t).slice(0, 60)}`)
  for (const t of yes) ok(asks(t), `asks something: ${JSON.stringify(t).slice(0, 60)}`)
  ok(quickReplies('Want it?', ['Ship it'], ['Yes, go ahead'])?.join() === 'Ship it', "the bot's own suggestions always win")
  ok(quickReplies('Want it?', undefined, ['Yes, go ahead'])?.join() === 'Yes, go ahead', 'saved replies follow a question')
  ok(quickReplies('Done.', undefined, ['Yes, go ahead']) === undefined, 'saved replies do not follow a statement')
  ok(quickReplies('Want it?', undefined, []) === undefined, 'no saved replies, none sent')
}

// A demo someone has already used no longer shows every state: start it fresh, unless asked to only read.
if (!READ_ONLY) {
  const first = await get('/v1/hello').catch(() => null)
  if (first?.body?.demo) await post('/v1/demo/reset').catch(() => null)
}
rules()
const hello = await reads().catch((e) => { ok(false, `the read checks stopped: ${e}`); return null })
if (hello?.demo && !READ_ONLY) {
  await writes().catch((e) => ok(false, `the write checks stopped: ${e?.stack ?? e}`))
  await guards().catch((e) => ok(false, `the guard checks stopped: ${e?.stack ?? e}`))
  await secondPass().catch((e) => ok(false, `the second pass checks stopped: ${e?.stack ?? e}`))
  const frozen = await steady()
  console.log(`\n${frozen ? 'Frozen server: captures match.' : 'Live server: answers change over time, the frozen check was skipped.'}`)
} else if (!READ_ONLY) console.log('\nNot a demo server: write checks skipped.')

console.log(`\n${passed} checks passed, ${failures.length} failed.`)
if (failures.length) { for (const f of failures) console.log(`  - ${f}`); process.exit(1) }
