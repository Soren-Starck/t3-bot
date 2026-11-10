/**
 * T3 Bot: the server behind the T3 Bot iPhone app. It runs beside T3 Code, on the same machine. Plain code, no model calls.
 *
 * Bots are a few named T3 Code threads (agents.json, see config.ts). The app shows them as contacts, a Chief on top,
 * and one ranked list of what needs the person: questions and approvals waiting in any T3 Code thread, cards from the
 * sources in the config (any command that prints cards, docs/CARDS.md) and notes agents send with `t3bot notify`.
 * Writes go through T3 Code (messages, answers) or a source's own command (done). Pushes go to the phone over APNs.
 *
 * Listens on 127.0.0.1:8809 (T3BOT_HOST, T3BOT_PORT); Tailscale Serve or the home network carries it to the phone.
 * Token: ~/.config/t3bot/token, made on first start.
 */
import { Database } from 'bun:sqlite'
import { timingSafeEqual } from 'crypto'
import { chmodSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from 'fs'
import { dirname, join } from 'path'
import * as t3 from './t3'
import { push, pushLive, type Alert, type Device, type Env } from './push'
import { oneLineCommand, plain, preview, quickReplies, snippet } from './text'
import {
  DATA_DIR as DATA, HOME, PORT, ROOT, TOKEN_FILE, VERSION, apnsConfigured, botNotesPath, chiefId, configPath, expandArgv, isHHMM,
  keepDays, loadConfig, rulesPath, saveConfig, threadDefaults, tilde, userInPrompt, userName, type AgentConf, type Config, type SourceConf,
} from './config'

const HOST = process.env.T3BOT_HOST || '127.0.0.1'
const AVATARS = join(ROOT, 'avatars')
const NO_PUSH = process.env.T3BOT_NO_PUSH === '1'
/** Where launchd sends this server's output (deploy/install.sh sets it), so the file can be kept small. */
const LOG_FILE = process.env.T3BOT_LOG_FILE || ''

const log = (m: string, x?: unknown) => console.log(new Date().toISOString(), m, x === undefined ? '' : JSON.stringify(x))
process.on('unhandledRejection', (e) => log('unhandled rejection', String((e as any)?.stack ?? e).slice(0, 400)))
process.on('uncaughtException', (e) => log('uncaught exception', String(e?.stack ?? e).slice(0, 400)))

/** An error's own words, without the stack or the class name in front. */
const reason = (e: unknown) => String((e as any)?.message ?? e).split('\n')[0].slice(0, 200)

/** A request the server refuses because of what it was sent: answered with 400 and these words. */
class Bad extends Error {}

/** The app's token. Made on first start, so a new install has nothing to prepare: `t3bot pair` hands it to the phone. */
function loadToken(): string {
  let t = ''
  if (existsSync(TOKEN_FILE)) {
    try { t = readFileSync(TOKEN_FILE, 'utf8').trim() } catch (e) {
      console.error(`T3 Bot cannot read its token file ${tilde(TOKEN_FILE)}: ${String(e).slice(0, 160)}`)
      process.exit(1)
    }
  }
  if (!t) {
    t = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url')
    try {
      mkdirSync(dirname(TOKEN_FILE), { recursive: true, mode: 0o700 })
      writeFileSync(TOKEN_FILE, t + '\n', { mode: 0o600 })
      chmodSync(TOKEN_FILE, 0o600)
    } catch (e) {
      console.error(`T3 Bot cannot create its token file ${tilde(TOKEN_FILE)}: ${reason(e)}. ` +
        `Check that you can write to ${tilde(dirname(TOKEN_FILE))}, or set T3BOT_TOKEN_FILE to a file you can write.`)
      process.exit(1)
    }
    log('token created', { file: tilde(TOKEN_FILE) })
  } else if (t.length < 16) log('the token is short: delete the token file and restart to get a strong one', { file: tilde(TOKEN_FILE) })
  return t
}
const TOKEN = loadToken()
const AUTH = Buffer.from(`Bearer ${TOKEN}`)
function authorized(req: Request): boolean {
  const got = Buffer.from(req.headers.get('authorization') ?? '')
  return got.length === AUTH.length && timingSafeEqual(got, AUTH)
}

// ---------- config (hot reloaded, see config.ts) ----------

const cfg = (): Config => loadConfig(log)
const agentById = (id: string) => cfg().agents.find((a) => a.id === id)
/** The bot that gets what no other bot claims. Undefined only while the config has no bots at all. */
const chief = () => { const id = chiefId(cfg()); return id ? agentById(id) : undefined }
const chiefOrNone = () => chiefId(cfg()) ?? ''
const NO_BOTS = 'there are no bots yet: run `t3bot setup` on the computer'
/** How a prompt names the person the bots work for: the name in the config, else "the user". */
const person = () => userInPrompt(cfg())

type Ran = { code: number; out: string; err: string; timedOut: boolean }
/** Runs a command without blocking the server and stops it after `timeout` seconds. Never throws. */
async function run(argv: string[], o: { timeout: number; stdin?: string; env?: Record<string, string> }): Promise<Ran> {
  if (!argv.length) return { code: -1, out: '', err: 'empty command', timedOut: false }
  try {
    const p = Bun.spawn(argv, {
      stdin: o.stdin === undefined ? 'ignore' : 'pipe', stdout: 'pipe', stderr: 'pipe', env: { ...process.env, ...(o.env ?? {}) },
    })
    let giveUp: () => void = () => {}
    const gaveUp = new Promise<null>((r) => { giveUp = () => r(null) })
    const timer = setTimeout(() => {
      try { p.kill(9) } catch {}
      // A child of the command can keep the pipes open after the kill: do not wait for it.
      setTimeout(giveUp, 2000)
    }, o.timeout * 1000)
    if (o.stdin !== undefined) { try { (p.stdin as any).write(o.stdin); (p.stdin as any).end() } catch {} }
    const done = await Promise.race([
      Promise.all([new Response(p.stdout as any).text(), new Response(p.stderr as any).text(), p.exited]), gaveUp,
    ])
    clearTimeout(timer)
    if (!done || p.signalCode === 'SIGKILL') return { code: -1, out: done?.[0] ?? '', err: `stopped after ${o.timeout} seconds`, timedOut: true }
    return { code: done[2], out: done[0], err: done[1], timedOut: false }
  } catch (e) {
    return { code: -1, out: '', err: String(e).slice(0, 300), timedOut: false }
  }
}
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

const slug = (s: string) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 24) || 'bot'
// Only smooth skins: no textures, patterns or pictures on the bodies, so that no two bots look alike.
let SKINS: { n: string; title: string; series: string; color: string }[] = []
try {
  SKINS = JSON.parse(readFileSync(join(ROOT, 'tools/faces/skins.json'), 'utf8')).filter((x: any) => x?.smooth && typeof x.n === 'string' && typeof x.color === 'string')
} catch (e) { log('skins unreadable: bots keep the default face', String(e).slice(0, 160)) }
const isSkin = (n: unknown) => typeof n === 'string' && SKINS.some((x) => x.n === n)
function hsl(hex: string): [number, number, number] {
  const v = parseInt(hex.slice(1), 16), r = (v >> 16 & 255) / 255, g = (v >> 8 & 255) / 255, b = (v & 255) / 255
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2, d = max - min
  if (!d) return [0, 0, l]
  const s = d / (1 - Math.abs(2 * l - 1))
  const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4
  return [(h * 60 + 360) % 360, s, l]
}
/** The smooth skin that looks least like any bot's: farthest hue from the others, vivid colors first. */
function freeSkin(): string {
  const used = cfg().agents.map((a) => SKINS.find((x) => x.n === a.face?.skin)).filter(Boolean) as typeof SKINS
  let best = SKINS[0], score = -1
  for (const c of SKINS) {
    if (used.some((u) => u.n === c.n)) continue
    const [h, s, l] = hsl(c.color)
    const far = used.length ? Math.min(...used.map((u) => {
      const [uh, us, ul] = hsl(u.color)
      const dh = Math.min(Math.abs(h - uh), 360 - Math.abs(h - uh)) / 180
      return dh * Math.min(s, us) + Math.abs(l - ul) * 0.8
    })) : 1
    const sc = far + s * 0.25
    if (sc > score) { score = sc; best = c }
  }
  return best?.n ?? '101'
}
/** Draws a bot's avatar picture (tools/faces). When that cannot run here, the bot shows its skin's stock picture. */
async function renderFace(id: string) {
  const r = await run([process.execPath, join(ROOT, 'tools/faces/render.ts'), id], { timeout: 60, env: { T3BOT_CONFIG: configPath() } })
  if (r.code !== 0) log('face render failed', { id, err: (r.err || r.out).slice(-200) })
}
function avatarPath(id: string) {
  const f = join(AVATARS, `${id}.png`)
  try { return `/v1/avatars/${id}.png?v=${Math.round(statSync(f).mtimeMs)}` } catch { return `/v1/avatars/${id}.png` }
}
/** The picture for an avatar request: the bot's own, else the stock picture of its skin. */
function avatarFile(name: string): string | null {
  const own = join(AVATARS, `${name}.png`)
  if (existsSync(own)) return own
  if (name.startsWith('skins/')) return null
  const skin = join(AVATARS, 'skins', `${agentById(name)?.face?.skin ?? '101'}.png`)
  return agentById(name) && existsSync(skin) ? skin : null
}
function describeSchedule(s: any): string {
  if (!s) return ''
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
  if (s.type === 'fixed_time') return `${s.weekdays?.length && s.weekdays.length < 7 ? s.weekdays.map((d: number) => days[d]).join(', ') : 'Every day'} at ${s.timeOfDay}`
  if (s.type === 'interval') {
    const m = s.everyMs / 60000
    if (m >= 60 * 24 * 300) return 'When started by code'
    return m < 60 ? `Every ${m} min` : m < 1440 ? `Every ${+(m / 60).toFixed(1)} h` : `Every ${+(m / 1440).toFixed(1)} days`
  }
  if (s.type === 'once') return `Once, ${new Date(s.runAt).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' })}`
  if (s.type === 'webhook') return 'On a webhook'
  return s.type
}

// ---------- own state ----------

/** The server's own SQLite file. A folder it cannot write to stops the start with what to do, not a stack trace. */
function openState(): Database {
  try {
    mkdirSync(DATA, { recursive: true })
    const d = new Database(join(DATA, 't3bot.sqlite'))
    d.exec('pragma busy_timeout = 5000')
    return d
  } catch (e) {
    console.error(`T3 Bot cannot open its data folder ${tilde(DATA)}: ${reason(e)}. ` +
      'Check that you can write to it, or set T3BOT_DATA_DIR to a folder you can write.')
    process.exit(1)
  }
}
const db = openState()
db.exec(`
  pragma journal_mode = wal;
  create table if not exists devices (token text primary key, env text not null, updated_at text not null);
  create table if not exists notes (id text primary key, agent text not null, kind text not null, title text not null,
    body text, link text, key text, created_at text not null, read_at text, pushed_at text, digested_at text);
  create table if not exists seen (k text primary key, at text not null);
  create table if not exists snooze (id text primary key, until text not null);
  create table if not exists held (id integer primary key autoincrement, title text not null, created_at text not null, sent_at text);
  create table if not exists actions (id integer primary key autoincrement, at text not null, what text not null, detail text);
`)
try { db.exec('alter table notes add column data text') } catch {}
db.exec('create table if not exists kv (k text primary key, v text not null)')
const PHONE = join(DATA, 'phone.json')
const now = () => new Date().toISOString()
const seen = (k: string) => !!db.query('select 1 from seen where k = ?').get(k)
const markSeen = (k: string) => db.query('insert or ignore into seen (k, at) values (?, ?)').run(k, now())
const record = (what: string, detail: unknown) => db.query('insert into actions (at, what, detail) values (?, ?, ?)').run(now(), what, JSON.stringify(detail))

// ---------- text helpers ----------

/**
 * A bot ends a message with its suggested replies on one last line: "» Yes, send it · Show me the draft · Not now"
 * (config/BOTS.md). The app shows them as one-tap chips; the line itself is not shown.
 */
function splitSuggestions(text: string): { text: string; suggestions?: string[] } {
  const lines = text.trimEnd().split('\n')
  const last = lines[lines.length - 1]?.trim() ?? ''
  if (!last.startsWith('»')) return { text }
  const suggestions = last.slice(1).split(/\s[·|]\s/).map((x) => x.trim().replace(/^["“]|["”]$/g, '')).filter((x) => x && x.length <= 60).slice(0, 4)
  return { text: lines.slice(0, -1).join('\n').trimEnd(), suggestions: suggestions.length ? suggestions : undefined }
}

/**
 * Images in a message: a bot's markdown images with an absolute path (`![shot](/abs/x.png)`, the way T3 Code shows
 * them too) and the photos the person attached ("[Image from <name>: /path ...]"). The app shows them; the text loses them.
 */
const IMG_MD = /!\[([^\]]*)\]\((\/[^)\s]+\.(?:png|jpe?g|gif|webp|heic))\)/gi
// Any name: the name in the config can change, and old messages keep the one they were sent with.
const IMG_SENT = /^\[Image from [^:\]\n]{1,60}: (\/[^\s]+\.(?:png|jpe?g))[^\]]*\]\s*$/gim
/** The line a photo from the phone becomes in the message to the bot. The app hides any line starting with "[Image from ". */
const imageLine = (file: string) => `[Image from ${person()}: ${file} (open it to see it)]`
function splitImages(text: string, photosOnly = false): { text: string; images?: { path: string; alt: string }[] } {
  const images: { path: string; alt: string }[] = []
  let t = photosOnly ? text : text.replace(IMG_MD, (_m, alt, path) => { images.push({ path, alt: String(alt) }); return '' })
  t = t.replace(IMG_SENT, (_m, path) => { images.push({ path, alt: '' }); return '' })
  return images.length ? { text: t.replace(/\n{3,}/g, '\n\n').trim(), images } : { text }
}

/** Only image files under the home folder or the temp folders, never secrets. */
function servableImage(path: string): string | null {
  if (!/\.(png|jpe?g|gif|webp|heic)$/i.test(path) || !path.startsWith('/')) return null
  let real: string
  try { real = realpathSync(path) } catch { return null }
  const okRoot = [HOME + '/', '/private/tmp/', '/tmp/', '/private/var/folders/'].some((r) => real.startsWith(r))
  const banned = ['/.ssh/', '/.config/', '/Library/Keychains/', '/.t3/userdata/secrets/', '/.gnupg/', '/.aws/'].some((b) => real.includes(b))
  return okRoot && !banned ? real : null
}

/** /compact and other slash commands the compactor sends: plumbing, never shown. */
const isSlash = (m: t3.Msg) => m.role === 'user' && /^\/[a-z-]+\s*$/.test(m.text.trim())

// ---------- the needs list ----------

/**
 * A card is anything that needs the person. Generic on purpose (T3 Bot is meant to work for any T3 Code user): a source
 * gives it a title, optional body, fields, checks and an editable text, and the buttons it offers. A button either
 * acts here (done, snooze), hands the card to its bot (`handle`), sends the bot a message built from the card and
 * the edited text (`message`), or runs a handler from the config (`command`). `faceId` asks for Face ID first.
 */
type Action = { id: string; label: string; kind: 'done' | 'snooze' | 'handle' | 'message' | 'command'; style?: 'primary' | 'destructive' | 'plain'; faceId?: boolean; message?: string; handler?: string }
type Card = {
  body?: string
  fields?: { label: string; value: string }[]
  checks?: { label: string; state: 'pass' | 'fail' | 'pending' }[]
  edit?: { label: string; text: string }
  actions?: Action[]
  draft?: { to?: string; text?: string; via?: string; subject?: string; event?: string; start?: string; end?: string; location?: string }
  /** How the card's bot can find the item itself (e.g. "Website to-do, key x"); used in messages to it. */
  ref?: string
  id: string; source: 'question' | 'desk' | 'note'; agent: string; rank: number
  title: string; detail?: string; why?: string; steps?: string; urgency?: string; customer?: boolean; minutes?: number
  desk?: string; deskName?: string; key?: string; at: string
  threadId?: string; threadTitle?: string; requestId?: string; requestKind?: string; questions?: t3.Question[]
  kind?: string; link?: string
}

/**
 * What each source last said. The list commands run beside the server, never inside a request: a slow or hanging
 * adapter delays the cards (its own, and the other sources' until its timeout), not the app. A source that fails
 * keeps its last good list and is tried again later.
 */
type SourceState = { at: number; cards: Card[]; loaded: boolean; failedAt: number; saidAt: number; running: Promise<void> | null }
const sourceState = new Map<string, SourceState>()
function stateOf(id: string): SourceState {
  let st = sourceState.get(id)
  if (!st) { st = { at: 0, cards: [], loaded: false, failedAt: 0, saidAt: 0, running: null }; sourceState.set(id, st) }
  return st
}

/**
 * A source is someone's script, and the app refuses the whole list when one value has the wrong type (a number
 * where it expects text). So what a source printed is brought to the types the app reads. Values that already
 * have the right type pass unchanged.
 */
function tidyCard(c: any): any {
  const o = { ...c }
  const text = (v: unknown) => (typeof v === 'string' ? v : typeof v === 'number' || typeof v === 'boolean' ? String(v) : undefined)
  for (const k of ['detail', 'body', 'why', 'steps', 'urgency', 'group', 'desk', 'key', 'kind', 'link', 'ref', 'threadId', 'threadTitle', 'requestId', 'requestKind']) {
    if (o[k] == null || typeof o[k] === 'string') continue
    const t = text(o[k])
    if (t === undefined) delete o[k]; else o[k] = t
  }
  if (o.minutes != null && typeof o.minutes !== 'number') { const n = Number(o.minutes); if (Number.isFinite(n)) o.minutes = n; else delete o.minutes }
  if (o.customer != null && typeof o.customer !== 'boolean') o.customer = o.customer === 1 || o.customer === 'true'
  if (typeof o.rank === 'number' && Number.isFinite(o.rank)) o.rank = Math.round(o.rank); else delete o.rank
  const pairs = (x: unknown, a: string, b: string) => (Array.isArray(x)
    ? x.filter((f) => f && typeof f === 'object').map((f: any) => ({ ...f, [a]: text(f[a]) ?? '', [b]: text(f[b]) ?? '' })) : undefined)
  if (o.fields != null) o.fields = pairs(o.fields, 'label', 'value')
  if (o.checks != null) o.checks = pairs(o.checks, 'label', 'state')
  if (o.edit != null) {
    if (typeof o.edit === 'object' && !Array.isArray(o.edit)) o.edit = { ...o.edit, label: text(o.edit.label) ?? 'Text', text: text(o.edit.text) ?? '' }
    else delete o.edit
  }
  if (o.draft != null) {
    if (typeof o.draft === 'object' && !Array.isArray(o.draft)) {
      o.draft = { ...o.draft }
      for (const k of ['to', 'text', 'via', 'subject', 'event', 'start', 'end', 'location']) {
        if (o.draft[k] == null || typeof o.draft[k] === 'string') continue
        const t = text(o.draft[k])
        if (t === undefined) delete o.draft[k]; else o.draft[k] = t
      }
    } else delete o.draft
  }
  if (o.questions != null) delete o.questions
  if (Array.isArray(o.actions)) {
    o.actions = o.actions.filter((a: any) => a && typeof a === 'object' && text(a.label) && text(a.kind)).map((a: any, i: number) => ({
      ...a, id: text(a.id) ?? `a${i}`, label: text(a.label), kind: text(a.kind),
      ...(a.style != null ? { style: text(a.style) ?? 'plain' } : {}), ...(a.faceId != null ? { faceId: a.faceId === true } : {}),
    }))
    // Buttons were given and none can be shown: the usual three, rather than a card with nothing to tap.
    if (!o.actions.length && c.actions.length) delete o.actions
  } else delete o.actions
  return o
}

function toCards(src: SourceConf, raw: any[]): Card[] {
  const srcAgent = src.agent && agentById(src.agent) ? src.agent : chiefOrNone()
  return raw.filter((c) => c && typeof c === 'object' && c.id && c.title).map(tidyCard).map((c) => {
    const rank = typeof c.rank === 'number' ? c.rank : ({ now: 1, today: 2, week: 3, later: 4 } as Record<string, number>)[c.urgency] ?? 3
    return {
      ...c, id: `${src.id}:${c.id}`, local: c.id, srcId: src.id, source: 'desk' as const, rank, title: String(c.title),
      agent: agentById(String(c.agent ?? '')) ? String(c.agent) : srcAgent,
      deskName: c.group ?? src.name ?? src.id, at: String(c.at ?? '').replace(' ', 'T'),
      // The app shows `detail`. A source may call it `body`, as `t3bot notify` does.
      detail: c.detail ?? (typeof c.body === 'string' ? c.body : undefined),
      actions: Array.isArray(c.actions) ? c.actions : [
        { id: 'handle', label: 'Handle it', kind: 'handle', style: 'primary', faceId: !!c.faceId },
        ...(src.done ? [{ id: 'done', label: 'Done', kind: 'done' }] : []),
        { id: 'snooze', label: 'Not now', kind: 'snooze' },
      ],
    } as Card
  })
}

/**
 * Source commands (list and done) run one at a time, in the order they were asked for. Sources are someone's
 * scripts and may share a state file: two at once can lose a write, or fail on the other's temporary file.
 */
let sourceTurn: Promise<unknown> = Promise.resolve()
function inTurn<T>(job: () => Promise<T>): Promise<T> {
  const mine = sourceTurn.then(job, job)
  sourceTurn = mine.catch(() => {})
  return mine
}

/** Runs one source's list command. Asked twice at once, it runs once. */
function refreshSource(src: SourceConf): Promise<void> {
  const st = stateOf(src.id)
  if (st.running) return st.running
  st.running = (async () => {
    const r = await inTurn(() => run(expandArgv(src.list), { timeout: Number(src.timeout) > 0 ? Number(src.timeout) : 60 }))
    let raw: unknown = null
    try { raw = JSON.parse(r.out).cards } catch {}
    if (Array.isArray(raw)) {
      st.cards = toCards(src, raw); st.at = Date.now(); st.loaded = true; st.failedAt = 0; st.saidAt = 0
    } else {
      st.failedAt = Date.now()
      // Said once, then every ten minutes while it stays broken.
      if (Date.now() - st.saidAt > 10 * 60e3) { st.saidAt = Date.now(); log('source unreadable', { source: src.id, err: (r.err || r.out).trim().slice(-200) }) }
    }
  })().catch((e) => { st.failedAt = Date.now(); log('source error', { source: src.id, e: String(e).slice(0, 200) }) }).finally(() => { st.running = null })
  return st.running
}

function sourceStale(src: SourceConf, st: SourceState): boolean {
  const ttl = Math.max(5, Number(src.ttl) || 30) * 1000
  if (st.failedAt && Date.now() - st.failedAt < Math.max(ttl, 30e3)) return false
  return Date.now() - st.at >= ttl
}

/** Starts a run of every source whose list is older than its ttl (all of them with `force`); resolves when they are back. */
function refreshSources(force = false): Promise<void> {
  const sources = cfg().sources
  for (const id of sourceState.keys()) if (!sources.some((s) => s.id === id)) sourceState.delete(id)
  return Promise.all(sources.filter((src) => force || stateOf(src.id).running || sourceStale(src, stateOf(src.id))).map(refreshSource)).then(() => {})
}

/** Waits, a few seconds at most, for sources that have never answered (the first request after a start). */
async function sourcesReady(ms = 4000) {
  const waiting = cfg().sources.filter((s) => { const st = stateOf(s.id); return !st.loaded && !st.failedAt })
  if (waiting.length) await Promise.race([Promise.all(waiting.map(refreshSource)), sleep(ms)])
}

/** Cards from every configured source, as last read. Asking also starts a refresh of the ones that are due. */
function deskCards(): Card[] {
  void refreshSources()
  return cfg().sources.flatMap((src) => sourceState.get(src.id)?.cards ?? [])
}

/** After something changed a source's items: read them again, waiting a few seconds at most. */
async function reloadSources(only?: SourceConf) {
  const again = async (src: SourceConf) => { const st = stateOf(src.id); if (st.running) await st.running; await refreshSource(src) }
  await Promise.race([Promise.all((only ? [only] : cfg().sources).map(again)), sleep(8000)])
}

function agentForThread(threadId: string, title: string): string {
  for (const a of cfg().agents) {
    if (a.threadId && a.threadId === threadId) return a.id
    if (a.watch.some((w) => title.startsWith(w))) return a.id
  }
  return chiefOrNone()
}

function questionCards(): Card[] {
  return t3.pendingRequests().map((r) => ({
    id: `req:${r.requestId}`, source: 'question' as const, agent: agentForThread(r.threadId, r.threadTitle), rank: 0,
    title: r.kind === 'command' ? `Approve: ${oneLineCommand(r.command ?? 'a command', 120)}` : r.questions[0]?.question ?? 'A question',
    detail: r.questions.length > 1 ? `${r.questions.length} questions` : undefined,
    at: r.createdAt, threadId: r.threadId, threadTitle: r.threadTitle, requestId: r.requestId, requestKind: r.kind, questions: r.questions,
  }))
}

function noteCards(): Card[] {
  const rows = db.query(`select * from notes where read_at is null and kind in ('alarm','approve','do','draft') order by created_at`).all() as any[]
  return rows.map((n) => {
    let data: any = {}
    try { data = (n.data ? JSON.parse(n.data) : {}) ?? {} } catch {}
    const isPhoneDraft = n.kind === 'draft'
    return {
      id: `note:${n.id}`, source: 'note' as const, agent: n.agent, rank: n.kind === 'alarm' ? 0 : n.kind === 'do' ? 2 : 1,
      title: n.title, detail: n.body ?? undefined, at: n.created_at, kind: n.kind, link: n.link ?? undefined, key: n.key ?? undefined,
      draft: isPhoneDraft ? data : undefined,
      fields: data.fields, checks: data.checks, edit: data.edit,
      actions: isPhoneDraft ? undefined : (data.actions?.length ? data.actions : [
        { id: 'handle', label: 'Handle it', kind: 'handle', style: 'primary', faceId: !!data.faceId },
        { id: 'done', label: 'Done', kind: 'done' },
        { id: 'snooze', label: 'Not now', kind: 'snooze' },
      ]),
    }
  })
}

/** Every card, snoozed ones included (actions must still find a snoozed card). */
const allCards = (): Card[] => [...questionCards(), ...noteCards(), ...deskCards()]

function needs(): Card[] {
  const snoozed = new Set((db.query('select id from snooze where until > ?').all(now()) as any[]).map((r) => r.id))
  return allCards()
    .filter((c) => !snoozed.has(c.id))
    .sort((a, b) => a.rank - b.rank || (b.customer ? 1 : 0) - (a.customer ? 1 : 0) || a.at.localeCompare(b.at))
}
const badgeCount = (list = needs()) => list.filter((c) => c.rank <= 1).length

// ---------- agents ----------

function agentSummary(a: AgentConf, list: Card[]) {
  const th = a.threadId ? t3.threadsByIds([a.threadId]).get(a.threadId) : undefined
  const watch = t3.threadsByPrefix(a.watch)
  const mine = list.filter((c) => c.agent === a.id)
  const ownStatus = th?.status ?? 'idle'
  const ownWorking = t3.isActive(ownStatus)
  const watching = watch.some((w) => t3.isActive(w.status))
  const working = ownWorking || watching
  // Waiting on something important from the person: a question or approval, or an urgent card (customer waiting, money, alarm).
  const waiting = mine.some((c) => c.source === 'question' || c.rank <= 1)
  const lastReply = a.threadId ? t3.lastAssistant(a.threadId) : null
  const activity = [lastReply?.at, th?.updatedAt, ...watch.map((w) => w.updatedAt)].filter(Boolean).sort().pop() ?? ''
  const quietHours = activity ? (Date.now() - Date.parse(activity)) / 3600e3 : 999
  // What the face shows: work first, then waiting for the person, then a failed last run. Idle bots sleep, so a
  // glance at the faces tells each bot's state.
  void quietHours
  // Working wins (a working bot that holds urgent cards must not look like it is waiting); a run that is itself
  // waiting on an answer shows as waiting.
  const askingNow = ownWorking && mine.some((c) => c.source === 'question' && c.threadId === a.threadId)
  const mood = askingNow ? 'waiting' : ownWorking ? 'working' : waiting ? 'waiting' : watching ? 'watching' : ownStatus === 'failed' ? 'failed' : 'asleep'
  // While it works, what it is doing right now (the face animates accordingly).
  const doing = ownWorking && a.threadId ? t3.activity(a.threadId)
    : watching ? t3.activity(watch.find((w) => t3.isActive(w.status))!.id) : null
  const hidden = a.threadId ? t3.systemRuns(a.threadId) : new Set<string>()
  // The preview is the person's conversation with the bot: their messages and the answers to them, not what automations sent.
  const recent = a.threadId ? t3.messages(a.threadId, 60).filter((m) => !isSlash(m) && !hidden.has(m.runId ?? '')) : []
  const userRuns = new Set(recent.filter((m) => m.role === 'user' && m.createdBy === 'user').map((m) => m.runId))
  const last = recent.filter((m) => (m.role === 'user' && m.createdBy === 'user') || (m.role === 'assistant' && userRuns.has(m.runId))).pop()
  return {
    id: a.id, name: a.name, role: a.role, avatar: avatarPath(a.id), threadId: a.threadId,
    kind: a.kind ?? 'bot', face: a.face ?? { skin: '101' }, hidden: !!a.hidden, members: a.members ?? [],
    // Its skin's main color: a group chat tints each member's bubbles with it, so who said what reads at a glance.
    color: SKINS.find((x) => x.n === (a.face?.skin ?? '101'))?.color ?? null,
    threadTitle: th?.title ?? '', t3Link: a.threadId && th ? `t3code://threads/${cfg().environmentId || t3.environmentId()}/${encodeURIComponent(a.threadId)}` : null,
    // Its thread was deleted in T3 Code: the app can say so instead of showing an empty chat.
    ...(a.threadId && !th ? { threadMissing: true } : {}),
    status: waiting ? 'waiting' : working ? 'working' : 'idle', mood, activity: doing, lastReplyAt: lastReply?.at ?? null, needs: mine.length,
    // A message that was only a photo reads "Photo"; the line that stands for the photo is never shown.
    last: last ? { text: preview(last.role === 'assistant' ? splitSuggestions(last.text).text : last.text, 160), at: last.at, from: last.role === 'assistant' ? 'agent' : 'me' } : null,
    watching: watch.filter((w) => t3.isActive(w.status)).map((w) => w.title),
  }
}

function home() {
  const list = needs()
  const doneToday = db.query(`select count(*) n from notes where kind = 'know' and created_at > ?`).get(dayStart()) as any
  const t3Problem = t3.status().problem
  return {
    agents: cfg().agents.map((a) => agentSummary(a, list)),
    // The bot the app puts on top and sends shared things to; null while there are no bots.
    chief: chiefId(cfg()) ?? null,
    user: userName(cfg()),
    // What stops the bots from working, in one plain sentence (T3 Code not running, not installed).
    t3: t3Problem ? { ok: false, error: t3Problem } : { ok: true },
    phoneShared: existsSync(PHONE),
    needs: list,
    badge: badgeCount(list),
    doneToday: doneToday?.n ?? 0,
    generatedAt: now(),
  }
}

/** What the app's connect screen and Settings read: who this server is, and whether it can ring the phone. */
function hello() {
  const t3Problem = t3.status().problem
  return {
    ok: true, name: 'T3 Bot', version: VERSION, user: userName(cfg()), demo: false, push: !NO_PUSH && apnsConfigured(),
    chief: chiefId(cfg()) ?? null, bots: cfg().agents.length, t3: t3Problem ? { ok: false, error: t3Problem } : { ok: true },
  }
}

type Entry = { id: string; type: 'me' | 'agent' | 'auto'; text: string; at: string; steps: string[]; working?: boolean; suggestions?: string[]; auto?: boolean; images?: { path: string; alt: string }[] }

function timeline(a: AgentConf) {
  const entries: Entry[] = []
  const run = a.threadId ? t3.lastRun(a.threadId) : null
  const working = !!run && t3.isActive(run.status)
  if (a.threadId) {
    const hidden = t3.systemRuns(a.threadId)
    const msgs = t3.messages(a.threadId, 160).filter((m) => !hidden.has(m.runId ?? ''))
    let pending: t3.Msg[] = []
    const flush = (runId: string | null, isLastRun: boolean) => {
      if (!pending.length) return
      const last = pending[pending.length - 1]
      const stillWorking = isLastRun && working
      const split = splitSuggestions(last.text)
      const pics = splitImages(split.text)
      entries.push({
        auto: runId ? !userRuns.has(runId) : false, images: stillWorking ? undefined : pics.images,
        id: last.id, type: 'agent', text: stillWorking ? '' : pics.text, at: last.at, suggestions: stillWorking ? undefined : split.suggestions,
        steps: (stillWorking ? pending : pending.slice(0, -1)).map((m) => plain(m.text, 240)), working: stillWorking,
      })
      pending = []
    }
    // Runs the person started; the others (an automation's notice, the brief) fold away in the app.
    const userRuns = new Set(msgs.filter((m) => m.role === 'user' && m.createdBy === 'user').map((m) => m.runId).filter(Boolean) as string[])
    let currentRun: string | null = null
    for (const m of msgs) {
      if (isSlash(m)) continue
      if (m.runId !== currentRun) { flush(currentRun, false); currentRun = m.runId }
      if (m.role === 'user') {
        // The person's own bubbles: only the photos they attached (a markdown image typed or quoted stays text).
        const mine = m.createdBy === 'user' ? splitImages(m.text, true) : null
        entries.push({ id: m.id, type: mine ? 'me' : 'auto', text: mine ? mine.text : plain(m.text, 300), at: m.at, steps: [], images: mine?.images })
      } else pending.push(m)
    }
    flush(currentRun, true)
    // Quick replies under the last answer: the bot's own "» " line when it wrote one. Without it, the person's
    // saved replies, and only when the answer asks them something (text.ts, quickReplies).
    const tail = entries[entries.length - 1]
    if (tail && tail.type === 'agent' && !tail.working) tail.suggestions = quickReplies(tail.text, tail.suggestions, settings().quickReplies)
  }
  const list = needs()
  const runs = t3.threadsByPrefix(a.watch)
    .map((w) => ({ w, m: t3.lastAssistant(w.id) }))
    .filter((x) => x.m && Date.now() - Date.parse(x.m.at) < 36 * 3600e3)
    .sort((x, y) => y.m!.at.localeCompare(x.m!.at))
    .slice(0, 8)
    .map(({ w, m }) => ({ threadId: w.id, title: w.title, status: w.status, at: m!.at, text: plain(m!.text, 400) }))
  const routineThreads = [a.threadId, ...t3.threadsByPrefix(a.watch).map((w) => w.id)].filter(Boolean)
  const routines = t3.routines(routineThreads).map((r) => ({
    id: r.id, title: r.title, enabled: r.enabled, when: describeSchedule(r.schedule), nextRunAt: r.nextRunAt,
    lastRunAt: r.lastRunAt, lastRunStatus: r.lastRunStatus, own: r.threadId === a.threadId,
  }))
  return {
    agent: agentSummary(a, list),
    routines,
    entries: entries.slice(-60),
    working,
    cards: list.filter((c) => c.agent === a.id),
    runs,
    // A group chat follows each member live: who is answering right now, and what it is doing.
    members: a.kind === 'group' ? (a.members ?? []).map(agentById).filter((m): m is AgentConf => !!m).map((m) => agentSummary(m, list)) : [],
  }
}

// ---------- actions ----------

/** A card by id. A desk card the cache does not know yet gets one fresh read of the sources before giving up. */
async function findCard(id: string): Promise<Card | undefined> {
  const card = allCards().find((c) => c.id === id)
  if (card || id.startsWith('req:') || id.startsWith('note:')) return card
  await Promise.race([refreshSources(true), sleep(8000)])
  return deskCards().find((c) => c.id === id)
}
const noteDone = (id: string) => db.query('update notes set read_at = ? where id = ?').run(now(), id.slice(5))

async function cardAction(id: string, action: string, body: any): Promise<{ ok: boolean; error?: string; agent?: string }> {
  const card = await findCard(id)
  if (!card) return { ok: false, error: 'card not found' }
  if (action === 'snooze') {
    const asked = body?.until ? new Date(String(body.until)) : null
    const until = asked && asked.getTime() > Date.now() + 60e3 ? asked : morning()
    db.query('insert or replace into snooze (id, until) values (?, ?)').run(id, until.toISOString())
    record('snooze', { id }); return { ok: true }
  }
  if (action === 'done') {
    if (card.source === 'note') { noteDone(id); record('done', { id }); return { ok: true } }
    if (card.source === 'desk') {
      const src = cfg().sources.find((x) => x.id === (card as any).srcId)
      if (!src?.done?.length) return { ok: false, error: 'this source cannot mark cards done' }
      const r = await inTurn(() => run(expandArgv(src.done).map((x) => x.replace('{id}', String((card as any).local))), { timeout: Number(src.timeout) > 0 ? Number(src.timeout) : 30 }))
      record('done', { id, rc: r.code })
      if (r.code !== 0) return { ok: false, error: (r.err.trim() || r.out.trim()).slice(-300) || 'the source could not mark it done' }
      // Gone from the list at once, then the source is read again so the app sees what it says now.
      const st = stateOf(src.id)
      st.cards = st.cards.filter((c) => c.id !== id)
      await reloadSources(src)
      return { ok: true }
    }
    return { ok: false, error: 'answer the question instead' }
  }
  if (action === 'handle') {
    const agent = agentById(card.agent) ?? chief()
    if (!agent) return { ok: false, error: NO_BOTS }
    if (!agent.threadId) return { ok: false, error: `${agent.name} has no thread yet` }
    const where = card.ref ? card.ref : card.source === 'desk' ? `${card.deskName}, item ${(card as any).local}` : card.source === 'note' ? `a T3 Bot note${card.key ? `, key ${card.key}` : ''}` : `thread "${card.threadTitle}"`
    const text = (body?.text ? `${body.text}\n\n` : '') +
      `From T3 Bot: ${person()} picked this card on the phone and wants to deal with it now: "${card.title}" (${where}).\n` +
      `Do it if nothing more is needed from them; otherwise ask in one short question with the options.`
    const r = await sendTo(agent, text)
    record('handle', { id, agent: agent.id, ok: r.ok })
    return { ...r, agent: agent.id }
  }
  return { ok: false, error: `unknown action ${action}` }
}

/** The next end of quiet hours (the "tomorrow morning" of snoozes). */
function morning(): Date {
  const [h, m] = (settings().quiet.to || '08:00').split(':').map(Number)
  const d = new Date(); d.setHours(h, m, 0, 0)
  if (d.getTime() <= Date.now()) d.setDate(d.getDate() + 1)
  return d
}

/** Any button on a card. `text` is the card's edited text, when it has one. */
async function act(id: string, actionId: string, body: any): Promise<{ ok: boolean; error?: string; agent?: string; message?: string }> {
  const card = await findCard(id)
  if (!card) return { ok: false, error: 'card not found' }
  const a = (Array.isArray(card.actions) ? card.actions : []).find((x) => x?.id === actionId) ?? { id: actionId, label: actionId, kind: actionId as Action['kind'] }
  if (a.kind === 'done' || a.kind === 'snooze' || a.kind === 'handle') {
    const extra = a.kind === 'handle' && body?.text && card.edit ? `Use this text as edited on the phone:\n${body.text}` : undefined
    return cardAction(id, a.kind, { ...body, text: extra })
  }
  if (a.kind === 'message') {
    const bot = agentById(card.agent) ?? chief()
    if (!bot) return { ok: false, error: NO_BOTS }
    if (!bot.threadId) return { ok: false, error: `${bot.name} has no thread yet` }
    const text = `From T3 Bot: ${person()} tapped "${a.label}" on the card "${card.title}".\n` +
      (a.message ? `${a.message}\n` : '') +
      (body?.text !== undefined && card.edit ? `${card.edit.label}, as ${person()} left it on the phone:\n${body.text}\n` : '') +
      `Do it now; tell ${person()} in one line when it is done, or ask one short question if something blocks.`
    const r = await sendTo(bot, text)
    if (r.ok && card.source === 'note') noteDone(id)
    record('act', { id, action: a.id, ok: r.ok })
    return { ...r, agent: bot.id }
  }
  if (a.kind === 'command') {
    const h = cfg().handlers[a.handler ?? '']
    if (!h || !Array.isArray(h.cmd) || !h.cmd.length) return { ok: false, error: `no handler "${a.handler}" in the config` }
    // The handler gets the card, the button and the edited text as JSON on stdin. Five minutes unless the config says otherwise.
    const r = await run(expandArgv(h.cmd), { timeout: Number(h.timeout) > 0 ? Number(h.timeout) : 300, stdin: JSON.stringify({ card, action: a, text: body?.text }) })
    const out = r.out.trim()
    record('command', { id, handler: a.handler, code: r.code })
    if (r.code !== 0) return { ok: false, error: (r.timedOut ? r.err : r.err.trim() || out).slice(-300) || 'the handler failed' }
    if (card.source === 'note') noteDone(id)
    await reloadSources()
    return { ok: true, message: out.slice(-300) }
  }
  return { ok: false, error: `unknown action ${actionId}` }
}

/**
 * A message to a bot's thread. When T3 Code refuses it, the answer says why in words the app can show: the thread
 * was deleted, or T3 Code is not running.
 */
async function sendTo(a: AgentConf, text: string): Promise<{ ok: boolean; error?: string }> {
  const r = await t3.sendMessage(a.threadId, text)
  if (r.ok) return r
  if (t3.READONLY) return r
  const problem = t3.status().problem
  if (problem) return { ok: false, error: problem }
  let gone = false
  try { gone = !t3.threadMeta(a.threadId) } catch {}
  return gone ? { ok: false, error: `${a.name}'s thread no longer exists in T3 Code. Hide this bot, or make a new one.` } : r
}

// ---------- images sent from the phone (saved on this machine; the bot gets their paths) ----------

const UPLOADS = join(DATA, 'uploads')
const MAX_IMAGE = 12 * 1024 * 1024
const MAX_TEXT = 100_000
function saveImages(images: unknown[]): string[] {
  mkdirSync(UPLOADS, { recursive: true })
  const out: string[] = []
  for (const b64 of images.slice(0, 6)) {
    if (typeof b64 !== 'string' || !b64) continue
    if (b64.length > MAX_IMAGE * 1.4) throw new Bad('a photo is larger than 12 MB')
    const buf = Buffer.from(b64, 'base64')
    if (!buf.length) continue
    const ext = buf[0] === 0x89 ? 'png' : 'jpg'
    const f = join(UPLOADS, `${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}-${crypto.randomUUID().slice(0, 8)}.${ext}`)
    writeFileSync(f, buf, { mode: 0o600 })
    out.push(f)
  }
  return out
}
/** Text the phone sends on to a bot: a string, trimmed, and not a book. */
const textOf = (x: unknown, max = MAX_TEXT) => (typeof x === 'string' || typeof x === 'number' ? String(x).trim().slice(0, max) : '')

// ---------- settings (quiet hours, daily brief, quick replies) ----------

type Settings = {
  quiet: { enabled: boolean; from: string; to: string; alarms: boolean }
  brief: { enabled: boolean; at: string; agent: string }
  quickReplies: string[]
}
function settings(): Settings {
  const row = db.query(`select v from kv where k = 'settings'`).get() as any
  let saved: any = {}
  try { saved = (row ? JSON.parse(row.v) : {}) ?? {} } catch {}
  const obj = (x: unknown) => (x && typeof x === 'object' && !Array.isArray(x) ? (x as Record<string, unknown>) : {})
  const hhmm = (x: unknown, d: string) => (isHHMM(x) ? x : d)
  const bool = (x: unknown, d: boolean) => (typeof x === 'boolean' ? x : d)
  const q = obj(saved.quiet), b = obj(saved.brief)
  return {
    quiet: { enabled: bool(q.enabled, true), from: hhmm(q.from, cfg().night.from), to: hhmm(q.to, cfg().night.to), alarms: bool(q.alarms, true) },
    // The brief comes from the Chief unless another bot was chosen (and still exists).
    brief: { enabled: bool(b.enabled, true), at: b.at === 'quiet-end' || !isHHMM(b.at) ? 'quiet-end' : b.at, agent: agentById(String(b.agent ?? '')) ? String(b.agent) : chiefOrNone() },
    quickReplies: Array.isArray(saved.quickReplies) ? saved.quickReplies.filter((x: unknown) => typeof x === 'string').slice(0, 6) : [],
  }
}
function saveSettings(b: any) {
  const cur = settings()
  const hhmm = (x: unknown, d: string) => (isHHMM(x) ? x : d)
  const bool = (x: unknown, d: boolean) => (typeof x === 'boolean' ? x : d)
  const next: Settings = {
    quiet: { enabled: bool(b.quiet?.enabled, cur.quiet.enabled), from: hhmm(b.quiet?.from, cur.quiet.from), to: hhmm(b.quiet?.to, cur.quiet.to), alarms: bool(b.quiet?.alarms, cur.quiet.alarms) },
    brief: { enabled: bool(b.brief?.enabled, cur.brief.enabled), at: b.brief?.at === 'quiet-end' ? 'quiet-end' : hhmm(b.brief?.at, cur.brief.at), agent: agentById(String(b.brief?.agent ?? '')) ? String(b.brief.agent) : cur.brief.agent },
    quickReplies: Array.isArray(b.quickReplies) ? b.quickReplies.map((x: unknown) => String(x).trim().slice(0, 200)).filter(Boolean).slice(0, 6) : cur.quickReplies,
  }
  db.query(`insert or replace into kv (k, v) values ('settings', ?)`).run(JSON.stringify(next))
  return next
}

// ---------- notes from agents ----------

function addNote(n: any) {
  const kind = String(n.kind ?? 'know')
  if (!['alarm', 'approve', 'do', 'know', 'draft'].includes(kind)) throw new Bad('kind must be alarm, approve, do, know or draft')
  const title = textOf(n.title, 300)
  if (!title) throw new Bad('title is required')
  n = { ...n, title, body: textOf(n.body, 8000) || undefined, link: textOf(n.link, 2000) || undefined, key: textOf(n.key, 200) || undefined }
  const agent = agentById(String(n.agent ?? '')) ? String(n.agent) : chiefOrNone()
  const id = n.key ? `${agent}:${n.key}` : crypto.randomUUID()
  const pairs = (x: unknown, a: string, b: string) => (Array.isArray(x)
    ? x.filter((f) => f && typeof f === 'object').map((f: any) => ({ [a]: String(f[a] ?? ''), [b]: String(f[b] ?? '') })).slice(0, 40) : undefined)
  const data = kind === 'draft' ? JSON.stringify(n.draft && typeof n.draft === 'object' ? n.draft : {})
    : JSON.stringify({
      fields: pairs(n.fields, 'label', 'value'),
      checks: pairs(n.checks, 'label', 'state'),
      edit: n.edit?.text !== undefined ? { label: String(n.edit.label ?? 'Text'), text: String(n.edit.text) } : undefined,
      actions: Array.isArray(n.actions) ? n.actions.filter((a: any) => a && typeof a === 'object' && a.label).slice(0, 6).map((a: any, i: number) => ({
        id: String(a.id ?? `a${i}`), label: String(a.label), kind: a.handler ? 'command' : 'message', style: i === 0 ? 'primary' : 'plain',
        faceId: !!(a.faceId ?? n.faceId), message: a.message ? String(a.message) : undefined, handler: a.handler ? String(a.handler) : undefined,
      })).concat([{ id: 'done', label: 'Done', kind: 'done' }, { id: 'snooze', label: 'Not now', kind: 'snooze' }]) : undefined,
      faceId: !!n.faceId,
    })
  db.query(`insert into notes (id, agent, kind, title, body, link, key, created_at, data) values (?, ?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(id) do update set kind = excluded.kind, title = excluded.title, body = excluded.body, link = excluded.link,
              data = excluded.data, read_at = null, pushed_at = null`)
    .run(id, agent, kind, String(n.title), n.body ? String(n.body) : null, n.link ? String(n.link) : null, n.key ? String(n.key) : null, now(), data)
  return { id, agent, kind }
}

// ---------- edit and create bots ----------

/** What a group's line says until someone writes another: who is in it. */
const groupRole = (members: string[]) => `Group: ${members.map((m) => agentById(m)?.name ?? m).join(', ')}`.slice(0, 140)

async function editAgent(id: string, b: any) {
  const c = cfg()
  const a = c.agents.find((x) => x.id === id)
  if (!a) return { ok: false, error: 'no such bot' }
  // Checked before anything is changed, so a refused edit leaves the bot as it was.
  if (b.hidden === true && id === chiefId(c)) return { ok: false, error: 'the Chief stays visible' }
  const members: string[] | null = Array.isArray(b.members) && a.kind === 'group'
    ? [...new Set(b.members.filter((m: unknown): m is string => typeof m === 'string' && m !== id && !!agentById(m) && agentById(m)!.kind !== 'group'))] as string[]
    : null
  if (members && members.length < 2) return { ok: false, error: 'a group needs at least two bots' }
  // A group whose line still is the list of its members gets the new list when the members change.
  const listed = a.kind === 'group' && a.role === groupRole(a.members ?? [])
  const roleBefore = a.role
  if (typeof b.name === 'string' && b.name.trim()) a.name = b.name.trim().slice(0, 40)
  if (typeof b.role === 'string' && b.role.trim()) a.role = b.role.trim().slice(0, 140)
  if (typeof b.hidden === 'boolean') a.hidden = b.hidden
  let faceChanged = false
  if (b.face && typeof b.face === 'object' && isSkin(String(b.face.skin)) && b.face.skin !== a.face?.skin) {
    a.face = { skin: String(b.face.skin) }
    faceChanged = true
  }
  if (members) {
    a.members = members
    if (listed && a.role === roleBefore) a.role = groupRole(members)
  }
  saveConfig(c)
  // The new picture is usually there within a few seconds; the app is not kept waiting longer than that.
  if (faceChanged) await Promise.race([renderFace(id), sleep(15000)])
  let told = false
  const job = textOf(b.job, 4000)
  if (job && a.threadId) {
    const r = await sendTo(a, `From T3 Bot: ${person()} changed what you do. Your job from now on: "${job}". ` +
      `Update your own instructions (your contract or notes) so it lasts after compaction, then confirm in one line.` +
      (a.kind === 'group' ? '' : ` Your one-line description in ${tilde(configPath())} is now "${a.role}".`))
    told = r.ok
  }
  record('edit', { id, faceChanged, told })
  return { ok: true, told }
}

// Ids of bots being created right now, so two taps at once cannot make two bots with the same id.
const creating = new Set<string>()
async function newAgent(b: any) {
  const c = cfg()
  if (!c.projectId) return { ok: false, error: 'no T3 Code project is chosen yet: run `t3bot setup` on the computer' }
  const kind = b.kind === 'group' ? 'group' : 'bot'
  const name = textOf(b.name, 40)
  if (!name) return { ok: false, error: 'a name is required' }
  const base = slug(name)
  let id = base
  for (let n = 2; c.agents.some((a) => a.id === id) || creating.has(id); n++) id = `${base.slice(0, 20)}-${n}`
  const members: string[] = kind === 'group'
    ? [...new Set((Array.isArray(b.members) ? b.members : []).filter((m: unknown): m is string => typeof m === 'string' && !!agentById(m) && agentById(m)!.kind !== 'group'))] as string[]
    : []
  if (kind === 'group' && members.length < 2) return { ok: false, error: 'a group needs at least two bots' }
  const job = textOf(b.job, 4000)
  const face = b.face && typeof b.face === 'object' && isSkin(String(b.face.skin)) ? { skin: String(b.face.skin) } : { skin: freeSkin() }
  const roster = members.map((m) => `${agentById(m)!.name} (id ${m}, thread ${agentById(m)!.threadId})`).join(', ')
  const who = person()
  const first = kind === 'group'
    ? `You run the T3 Bot group chat "${name}". Read ${tilde(rulesPath('GROUP.md'))} now and follow it for this whole thread. ` +
      `Members: ${roster}.${job ? ` What this group is for: ${job}.` : ''} Reply with one line saying the group is ready and who is in it.`
    : `You are ${name}, a bot in T3 Bot, ${who}'s agent app. Your job: ${job || `to be defined by ${who}`}. ` +
      `Read ${tilde(rulesPath('BOTS.md'))} now and follow it for this whole thread. Write your own instructions to ` +
      `${tilde(botNotesPath(id))} so they survive compaction, read that file again after any compaction, ` +
      `then reply with one line saying you are ready.`
  const title = botTitle({ name, kind })
  creating.add(id)
  try {
    try { mkdirSync(dirname(botNotesPath(id)), { recursive: true }) } catch {}
    const r = await t3.createThread(c.projectId, title, first, threadDefaults(c))
    if (!r.threadId) return { ok: false, error: r.error ?? 'T3 Code refused the new thread' }
    // Read again: the config may have been edited while T3 Code made the thread.
    const fresh = cfg()
    fresh.agents.push({ id, name, role: job ? job.slice(0, 140) : kind === 'group' ? groupRole(members) : 'New bot',
      threadId: r.threadId, watch: [], kind, face, hidden: false, ...(kind === 'group' ? { members } : {}) })
    saveConfig(fresh)
    await Promise.race([renderFace(id), sleep(15000)])
    record('new', { id, kind, ok: r.ok })
    return { ok: r.ok, id, error: r.ok ? undefined : r.error }
  } finally {
    creating.delete(id)
  }
}

// ---------- %BOT titles ----------

/** Every bot's conversation thread is titled `%BOT <Name>`, a group `%BOT Group: <Name>`, so they are easy to tell apart in T3 Code. */
const botTitle = (a: { name: string; kind?: string }) => a.kind === 'group' ? `%BOT Group: ${a.name}` : `%BOT ${a.name}`
let lastTitles = 0
async function enforceTitles() {
  if (t3.READONLY || Date.now() - lastTitles < 60e3) return
  lastTitles = Date.now()
  for (const a of cfg().agents) {
    if (!a.threadId) continue
    const m = t3.threadMeta(a.threadId)
    if (!m) continue
    const want = botTitle(a)
    // A count in brackets after the name is left alone, so a tool of yours can keep one there: "%BOT Inbox (36)".
    const ok = m.title === want || new RegExp(`^${want.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} \\(\\d+\\)$`).test(m.title)
    if (!ok) { const r = await t3.rename(a.threadId, want); log('bot thread renamed', { from: m.title, to: want, ok: r.ok }) }
    if (!m.autoSettleOff) { const r = await t3.keepUp(a.threadId); log('bot thread kept out of auto-settle', { title: want, ok: r.ok }) }
  }
}

// ---------- bot threads stay out of the desktop sidebar unless they work ----------

/**
 * Every bot thread settles after each reply, so the T3 Code desktop app only shows it while it works.
 * A run in progress or a question waiting for an answer keeps it up; when one starts on a settled thread, it comes back.
 * An urgent card does not: it reaches the person through T3 Bot (orange line, push), never the desktop sidebar.
 */
// Each try is remembered with its time: the same state is tried again after 10 minutes, so a thread that something
// else brought back up (a title change, a manual unsettle) without a new run still goes back down.
const lastSettleTry = new Map<string, string>()
const settleTriedAt = new Map<string, number>()
async function settleBots() {
  if (t3.READONLY) return
  const waiting = new Set(t3.pendingRequests().map((r) => r.threadId))
  for (const a of cfg().agents) {
    if (!a.threadId) continue
    const m = t3.threadMeta(a.threadId)
    const run = t3.lastRun(a.threadId)
    if (!m || !run) continue
    // Up only while it works or a question in it waits on an answer.
    const busy = t3.isActive(run.status) || waiting.has(a.threadId)
    // A pinned thread stays in the sidebar even settled: bot threads are never pinned.
    if (m.pinned && !lastSettleTry.has(`pin:${a.threadId}`)) {
      lastSettleTry.set(`pin:${a.threadId}`, '1')
      const r = await t3.unpin(a.threadId)
      log('bot thread unpinned', { title: m.title, ok: r.ok })
    }
    const key = `${busy ? 'up' : 'down'}:${run.id}:${run.status}:${m.settled}`
    if (lastSettleTry.get(a.threadId) === key && Date.now() - (settleTriedAt.get(a.threadId) ?? 0) < 10 * 60e3) continue
    if (!busy && !m.settled) {
      lastSettleTry.set(a.threadId, key); settleTriedAt.set(a.threadId, Date.now())
      const r = await t3.settle(a.threadId, run.id)
      log('bot thread settled', { title: m.title, ok: r.ok, ...(r.ok ? {} : { error: r.error?.slice(0, 160) }) })
    } else if (busy && m.settled) {
      lastSettleTry.set(a.threadId, key); settleTriedAt.set(a.threadId, Date.now())
      const r = await t3.unsettle(a.threadId)
      log('bot thread back up while it works', { title: m.title, ok: r.ok })
    }
  }
}

// ---------- push loop ----------

const hm = (s: string) => { const [h, m] = s.split(':').map(Number); return h * 60 + m }
function isNight(d = new Date()) {
  const q = settings().quiet
  if (!q.enabled) return false
  const { from, to } = q
  const t = d.getHours() * 60 + d.getMinutes()
  return hm(from) > hm(to) ? t >= hm(from) || t < hm(to) : t >= hm(from) && t < hm(to)
}
function dayStart() { const d = new Date(); d.setHours(0, 0, 0, 0); return d.toISOString() }
/** The day as the person lives it (local time), for the things that happen once a day. */
const localDay = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
const devices = () => (db.query('select token, env from devices').all() as any[]).map((d): Device => ({ token: d.token, env: d.env === 'production' ? 'production' : 'sandbox' }))

/** One push to the phone. Held for the morning during quiet hours unless it must ring. Never throws. */
async function send(a: Alert, opts: { night?: 'hold' | 'ring' } = {}) {
  try {
    if (NO_PUSH) { log('push (disabled)', { title: a.title, body: a.body }); return }
    if (opts.night !== 'ring' && isNight()) {
      db.query('insert into held (title, created_at) values (?, ?)').run(`${a.title}: ${a.body}`, now())
      log('held for the morning', { title: a.title }); return
    }
    // The phone shows each push as sent by its bot (its face, its name as the title, this label under it).
    const agentId = String(a.data?.agent ?? '') || chiefOrNone()
    const kindLabel = a.data?.kindLabel ? String(a.data.kindLabel) : a.category === 'QUESTION' || a.category === 'QUESTION_MULTI' ? 'Question'
      : a.category === 'APPROVAL' ? 'Approval'
      : a.category === 'CARD' ? (a.timeSensitive ? 'Alarm' : 'Needs you')
      : a.category === 'DIGEST' ? a.title
      : ''
    a = { ...a, data: { ...(a.data ?? {}), agent: agentId, agentName: agentById(agentId)?.name ?? 'T3 Bot', kindLabel } }
    const to = devices()
    const gone = await push(to, { ...a, badge: badgeCount() }, log)
    for (const t of gone) db.query('delete from devices where token = ?').run(t)
    if (to.length && apnsConfigured()) log('pushed', { title: a.title, category: a.category })
  } catch (e) {
    log('push error', String(e).slice(0, 200))
  }
}

// ---------- Live Activities ----------

/** What a working bot is doing, in the words its Live Activity shows. */
const ACTIVITY_WORDS: Record<string, string> = {
  thinking: 'Thinking', reading: 'Reading', running: 'Running a command', writing: 'Writing',
  web: 'On the web', delegating: 'Asking another agent', asking: 'Waiting for your answer',
}
const liveSaid = new Map<string, { text: string; at: number }>()

/**
 * The Live Activity the phone started when a message was sent to a bot: its push token, when it started (Unix
 * seconds, as the app sent it), the APNs environment of the build that started it, and when it was registered.
 */
type Live = { token: string; startedAt: number; env: Env; at: number }
const isEnv = (x: unknown): x is Env => x === 'production' || x === 'sandbox'
/** The environment of the phone's build, from the device it registered last. */
const defaultEnv = (): Env => {
  const d = db.query('select env from devices order by updated_at desc limit 1').get() as any
  return d?.env === 'production' ? 'production' : 'sandbox'
}
const dropLive = (id: string) => { db.query(`delete from kv where k = ?`).run(`live:${id}`); liveSaid.delete(id) }
const saveLive = (id: string, l: Live) => db.query(`insert or replace into kv (k, v) values (?, ?)`).run(`live:${id}`, JSON.stringify(l))
function liveOf(id: string): Live | null {
  const row = db.query(`select v from kv where k = ?`).get(`live:${id}`) as any
  if (!row) return null
  try {
    const l = JSON.parse(row.v)
    if (typeof l?.token !== 'string' || !l.token) throw new Error('no token')
    const startedAt = Number(l.startedAt) || Math.floor(Date.now() / 1000)
    return { token: l.token, startedAt, env: isEnv(l.env) ? l.env : defaultEnv(), at: Number(l.at) || startedAt * 1000 }
  } catch {
    dropLive(id)
    return null
  }
}
/** One Live Activity push. Remembers the environment that worked and forgets an activity that no longer exists. */
async function liveSend(id: string, l: Live, state: Record<string, unknown>, end: boolean) {
  if (NO_PUSH) { if (end) dropLive(id); return }
  const r = await pushLive(l.token, state, end, log, l.env)
  if (end || r.gone) dropLive(id)
  else if (r.ok && r.env !== l.env) saveLive(id, { ...l, env: r.env })
}

/** While a bot works on a message from the phone, its Live Activity says what it is doing (at most every 15 s per bot). */
async function liveUpdates() {
  for (const a of cfg().agents) {
    if (!a.threadId) continue
    const l = liveOf(a.id)
    if (!l) { liveSaid.delete(a.id); continue }
    const run = t3.lastRun(a.threadId)
    if (!run || !t3.isActive(run.status)) {
      // The run it was started for stopped without an answer (failed, interrupted, cancelled): end the activity
      // instead of leaving "Thinking" on the lock screen. A completed run is ended with its answer by the loop.
      const since = Math.min(l.at, l.startedAt * 1000) - 30e3
      const stopped = !!run && run.status !== 'completed' && Date.parse(run.requestedAt) >= since
      if (stopped) await liveSend(a.id, l, { status: 'answered', text: 'Stopped before answering.', startedAt: l.startedAt }, true)
      // iOS ends an activity by itself after eight hours: nothing is left to update.
      else if (Date.now() - l.at > 8 * 3600e3) dropLive(a.id)
      continue
    }
    const text = ACTIVITY_WORDS[t3.activity(a.threadId) ?? 'thinking'] ?? 'Thinking'
    const last = liveSaid.get(a.id)
    if (last?.text === text || (last && Date.now() - last.at < 15e3)) continue
    liveSaid.set(a.id, { text, at: Date.now() })
    await liveSend(a.id, l, { status: 'working', text, startedAt: l.startedAt }, false)
  }
}

// ---------- the loop: what rings the phone ----------

let firstLoop = true
const stepSaid = new Map<string, { msg: string; at: number }>()
async function loop() {
  const baseline = firstLoop && !seen('baseline:done')
  let failed = false
  // One step failing (T3 Code's state unreadable for a moment) does not stop the others.
  const step = async (name: string, fn: () => Promise<void>) => {
    try { await fn() } catch (e) {
      failed = true
      const msg = String(e).slice(0, 200), last = stepSaid.get(name)
      if (!last || last.msg !== msg || Date.now() - last.at > 10 * 60e3) { stepSaid.set(name, { msg, at: Date.now() }); log(`loop step failed: ${name}`, msg) }
    }
  }
  // The sources are read beside the loop. The first pass waits for them, so that after a restart (and on the very
  // first start, when everything already there is recorded as old) the cards are known before deciding what is new.
  if (firstLoop) await Promise.race([refreshSources(), sleep(90000)])

  // 1. questions and approvals waiting in any thread
  await step('questions', async () => {
    for (const c of questionCards()) {
      const k = `q:${c.requestId}`
      if (seen(k)) continue
      markSeen(k)
      if (baseline) continue
      const who = agentById(c.agent)
      await send({
        title: who && who.id !== chiefOrNone() ? `${who.name} asks` : `${c.threadTitle} asks`,
        body: c.title, threadId: c.agent, collapseId: c.requestId,
        category: c.requestKind === 'command' ? 'APPROVAL' : c.questions?.length === 1 ? 'QUESTION' : 'QUESTION_MULTI',
        data: { cardId: c.id, agent: c.agent, threadId: c.threadId, requestId: c.requestId, questionId: c.questions?.[0]?.id },
      })
    }
  })
  // 2. an agent's own thread finished a run: it answered something
  await step('answers', async () => {
    for (const a of cfg().agents) {
      if (!a.threadId) continue
      const run = t3.lastRun(a.threadId)
      if (!run || run.status !== 'completed') continue
      const k = `run:${run.id}`
      if (seen(k)) continue
      if (baseline) { markSeen(k); continue }
      const m = t3.lastAssistant(a.threadId)
      // The run can show as completed a moment before its last message is readable: look again on the next pass
      // instead of deciding, once and for all, that it said nothing.
      if ((!m || m.runId !== run.id) && run.completedAt && Date.now() - Date.parse(run.completedAt) < 20e3) continue
      markSeen(k)
      if (!m || m.runId !== run.id || t3.systemRuns(a.threadId).has(run.id)) continue
      const isBrief = t3.runHas(a.threadId, run.id, 't3bot:brief:')
      // Automated turns (an automation's notice, the morning brief dump, a schedule) do not ring: their cards do.
      if (!isBrief && !t3.runStartedByUser(a.threadId, run.id)) continue
      // The Live Activity started by sending this bot a message: show the start of the answer, then end it.
      const l = liveOf(a.id)
      if (l) await liveSend(a.id, l, { status: 'answered', text: preview(splitSuggestions(m.text).text, 140), startedAt: l.startedAt }, true)
      await send({ title: a.name, body: preview(splitSuggestions(m.text).text, isBrief ? 400 : 220), category: 'REPLY', threadId: a.id,
        data: { agent: a.id, ...(isBrief ? { kindLabel: 'Morning brief' } : {}) } }, isBrief ? { night: 'ring' } : {})
    }
  })
  // 3. new desk cards: now and today ring, the rest wait for the app
  await step('cards', async () => {
    for (const c of deskCards()) {
      const k = `card:${c.id}`
      if (seen(k)) continue
      markSeen(k)
      if (baseline || !['now', 'today'].includes(c.urgency ?? '')) continue
      await send({
        title: `${agentById(c.agent)?.name ?? c.deskName}: needs you`, body: c.title, category: 'CARD', threadId: c.agent,
        data: { cardId: c.id, agent: c.agent },
      })
    }
  })
  // 4. notes agents sent with `t3bot notify`
  await step('notes', async () => {
    for (const n of db.query(`select * from notes where pushed_at is null and kind != 'know'`).all() as any[]) {
      db.query('update notes set pushed_at = ? where id = ?').run(now(), n.id)
      const who = agentById(n.agent)?.name ?? 'T3 Bot'
      await send({
        title: n.kind === 'alarm' ? `${who}: alarm` : who, body: n.body ? `${n.title}: ${n.body}` : n.title,
        category: 'CARD', threadId: n.agent, timeSensitive: n.kind === 'alarm', data: { cardId: `note:${n.id}`, agent: n.agent },
      }, { night: n.kind === 'alarm' && settings().quiet.alarms ? 'ring' : 'hold' })
    }
  })
  // The very first start records what is already there as old. If a step could not read, the next pass tries again.
  if (baseline && !failed) { markSeen('baseline:done'); log('baseline recorded: nothing older rings') }
  if (!baseline || !failed) firstLoop = false
  // 5. the morning: one push for everything held overnight
  await step('morning', async () => {
    if (isNight()) return
    const held = db.query('select id, title from held where sent_at is null order by id').all() as any[]
    if (!held.length) return
    db.query('update held set sent_at = ? where sent_at is null').run(now())
    await send({ title: `While you slept: ${held.length}`, body: held.slice(0, 3).map((h) => h.title).join(' · '), category: 'DIGEST' })
  })
  // 6. the daily brief: one short message from the chosen bot when quiet hours end (or at a set time)
  await step('brief', async () => {
    const b = settings().brief
    const bot = agentById(b.agent)
    if (!b.enabled || !bot?.threadId || t3.READONLY) return
    const at = b.at === 'quiet-end' ? settings().quiet.to : b.at
    const d0 = new Date(), mins = d0.getHours() * 60 + d0.getMinutes()
    const key = `brief:${localDay(d0)}`
    if (mins < hm(at) || mins >= hm(at) + 180 || seen(key)) return
    markSeen(key)
    const who = person()
    const r = await t3.sendSystem(bot.threadId, `From T3 Bot: ${who}'s morning brief. In at most 5 short lines: the 3 things that need ${who} most today ` +
      `(read http://127.0.0.1:${PORT}/v1/home with the token in ${tilde(TOKEN_FILE)}), anything broken, and one line on how the night went. ` +
      `No preamble.`, 'brief')
    log('brief asked', { bot: bot.id, ok: r.ok })
  })
  // 7. the evening digest of what agents did alone
  await step('digest', async () => {
    const d = new Date()
    const dayKey = `digest:${localDay(d)}`
    // Sent 15 minutes before quiet hours start, so it never rings inside them.
    const q = settings().quiet
    const digestAt = q.enabled ? (hm(q.from) - 15 + 1440) % 1440 : hm(cfg().digestAt)
    if (d.getHours() * 60 + d.getMinutes() < digestAt || seen(dayKey)) return
    markSeen(dayKey)
    const know = db.query(`select id, title from notes where kind = 'know' and digested_at is null order by created_at`).all() as any[]
    if (!know.length) return
    db.query(`update notes set digested_at = ? where kind = 'know' and digested_at is null`).run(now())
    await send({ title: `Done without you today: ${know.length}`, body: know.slice(0, 4).map((k) => k.title).join(' · '), category: 'DIGEST' })
  })
}

// ---------- housekeeping: nothing here grows without end ----------

let lastPrune = 0
function prune() {
  if (Date.now() - lastPrune < 3600e3) return
  lastPrune = Date.now()
  const ago = (days: number) => new Date(Date.now() - days * 86400e3).toISOString()
  // Bookkeeping nobody reads again: questions older than T3 Code still lists, the once-a-day marks, snoozes that
  // ended and pushes that were held for the morning and sent. Run and card marks stay: without them an old answer
  // or card would ring again.
  db.query(`delete from seen where k like 'q:%' and at < ?`).run(ago(30))
  db.query(`delete from seen where (k like 'brief:%' or k like 'digest:%') and at < ?`).run(ago(7))
  db.query(`delete from snooze where until < ?`).run(now())
  db.query(`delete from held where sent_at is not null and sent_at < ?`).run(ago(30))
  // History: kept forever unless T3BOT_KEEP_DAYS or "keepDays" in the config gives a number of days. Past that
  // age the record of card taps, the notes that were read, the notes of the evening digest and the photos sent
  // from the phone are deleted. A note that was never read stays whatever its age.
  const days = keepDays(cfg())
  if (days > 0) {
    db.query(`delete from actions where at < ?`).run(ago(days))
    db.query(`delete from notes where created_at < ? and (read_at is not null or kind = 'know')`).run(ago(days))
    if (existsSync(UPLOADS)) {
      const before = Date.now() - days * 86400e3
      for (const f of readdirSync(UPLOADS)) {
        if (!/\.(png|jpe?g)$/i.test(f)) continue
        try { if (statSync(join(UPLOADS, f)).mtimeMs < before) rmSync(join(UPLOADS, f)) } catch {}
      }
    }
  }
  // The log launchd writes for this server: past 5 MB, only its last 1 MB is kept.
  if (LOG_FILE) {
    try {
      const size = statSync(LOG_FILE).size
      if (size > 5 * 1024 * 1024) {
        const keep = Buffer.alloc(1024 * 1024)
        const fd = openSync(LOG_FILE, 'r')
        try { readSync(fd, keep, 0, keep.length, size - keep.length) } finally { closeSync(fd) }
        writeFileSync(LOG_FILE, keep.subarray(keep.indexOf(10) + 1))
      }
    } catch {}
  }
}

async function tick() {
  try { await loop() } catch (e) { log('loop error', String(e)) }
  try { await enforceTitles() } catch (e) { log('titles error', String(e)) }
  try { await settleBots() } catch (e) { log('settle error', String(e)) }
  try { await liveUpdates() } catch (e) { log('live update error', String(e)) }
  try { prune() } catch (e) { log('housekeeping error', String(e)) }
  setTimeout(tick, 5000)
}

// ---------- http ----------

const json = (x: unknown, status = 200) => new Response(JSON.stringify(x), { status, headers: { 'content-type': 'application/json' } })

/** Home and chats are fetched every few seconds from the phone: compressed, they are a fraction of the size. */
async function gz(req: Request, res: Response): Promise<Response> {
  if (!(req.headers.get('accept-encoding') ?? '').includes('gzip')) return res
  if (!(res.headers.get('content-type') ?? '').startsWith('application/json')) return res
  const raw = new Uint8Array(await res.arrayBuffer())
  if (raw.length < 1500) return new Response(raw, { status: res.status, headers: res.headers })
  const headers = new Headers(res.headers)
  headers.set('content-encoding', 'gzip')
  return new Response(Bun.gzipSync(raw), { status: res.status, headers })
}

const HEX = /^[0-9a-f]{32,400}$/i

try {
  Bun.serve({
    // Bun cuts a request after 10 s by default; making a bot waits longer than that for its face.
    idleTimeout: 60,
    hostname: HOST,
    port: PORT,
    // Room for a few photos in one message, not for anything else.
    maxRequestBodySize: 64 * 1024 * 1024,
    error(e) {
      log('server error', String(e).slice(0, 300))
      return json({ ok: false, error: 'server error' }, 500)
    },
    async fetch(req) {
      const url = new URL(req.url)
      const path = url.pathname
      if (path === '/health') return json({ ok: true })
      const av = path.match(/^\/v1\/avatars\/((?:skins\/)?[a-z0-9-]+)\.png$/)
      if (av) {
        const f = avatarFile(av[1])
        return f ? new Response(Bun.file(f), { headers: { 'cache-control': 'max-age=3600' } }) : json({ error: 'no avatar' }, 404)
      }
      if (!authorized(req)) return json({ error: 'unauthorized' }, 401)
      if (req.method !== 'POST') return gz(req, await route(req, url, path, {}))
      // An empty body is an empty object; anything else must be a JSON object.
      let body: any = {}
      let raw = ''
      try { raw = await req.text() } catch { return json({ ok: false, error: 'the request could not be read (too large?)' }, 413) }
      if (raw.trim()) {
        try { body = JSON.parse(raw) } catch { return json({ ok: false, error: 'the body is not valid JSON' }, 400) }
        if (!body || typeof body !== 'object' || Array.isArray(body)) return json({ ok: false, error: 'the body must be a JSON object' }, 400)
      }
      const started = performance.now()
      const res = await route(req, url, path, body)
      log('action', { path, status: res.status, ms: Math.round(performance.now() - started) })
      return res
    },
  })
} catch (e) {
  const taken = (e as any)?.code === 'EADDRINUSE' || /in use/i.test(String(e))
  console.error(taken
    ? `T3 Bot could not start: port ${PORT} on ${HOST} is already in use. If a T3 Bot server already runs here, use that one ` +
      '(`t3bot doctor` shows it). Otherwise start this one on a free port with T3BOT_PORT, and give `t3bot` the same T3BOT_PORT.'
    : `T3 Bot could not listen on ${HOST}:${PORT}: ${reason(e)}. Check T3BOT_HOST and T3BOT_PORT.`)
  process.exit(1)
}

async function route(req: Request, url: URL, path: string, body: any): Promise<Response> {
  try {
    const GET = req.method === 'GET', POST = req.method === 'POST'
    if (path === '/v1/hello' && GET) return json(hello())
    if (path === '/v1/home' && GET) { await sourcesReady(); return json(home()) }
    if (path === '/v1/file' && GET) {
      const f = servableImage(url.searchParams.get('path') ?? '')
      if (!f || !existsSync(f)) return json({ error: 'not an image this app may show' }, 404)
      return new Response(Bun.file(f), { headers: { 'cache-control': 'private, max-age=86400' } })
    }
    if (path === '/v1/skins' && GET) return json({ skins: SKINS, used: cfg().agents.map((a) => a.face?.skin) })
    let m = path.match(/^\/v1\/agents\/([a-z0-9-]+)$/)
    if (m && GET) {
      const a = agentById(m[1])
      if (!a) return json({ error: 'no such agent' }, 404)
      await sourcesReady()
      return json(timeline(a))
    }
    m = path.match(/^\/v1\/agents\/([a-z0-9-]+)\/send$/)
    if (m && POST) {
      const a = agentById(m[1])
      if (!a?.threadId) return json({ ok: false, error: a ? `${a.name} has no thread yet` : 'no such agent' }, 404)
      const images = Array.isArray(body.images) ? saveImages(body.images) : []
      const text = [textOf(body.text), ...images.map(imageLine)].filter(Boolean).join('\n\n')
      if (!text) return json({ ok: false, error: 'empty message' }, 400)
      const r = await sendTo(a, text)
      record('send', { agent: a.id, ok: r.ok })
      return json(r, r.ok ? 200 : 502)
    }
    if (path === '/v1/answer' && POST) {
      const threadId = textOf(body.threadId, 200), requestId = textOf(body.requestId, 200)
      if (!threadId || !requestId) return json({ ok: false, error: 'threadId and requestId are required' }, 400)
      // Only a question that is still waiting, in the thread that asked it.
      if (!t3.pendingRequests().some((p) => p.threadId === threadId && p.requestId === requestId)) {
        return json({ ok: false, error: 'that question is no longer waiting for an answer' }, 404)
      }
      const decision = textOf(body.decision, 100)
      const answers = body.answers && typeof body.answers === 'object' && !Array.isArray(body.answers) ? body.answers : {}
      const r = decision ? await t3.decide(threadId, requestId, decision) : await t3.answer(threadId, requestId, answers)
      record('answer', { requestId, ok: r.ok })
      return json(r, r.ok ? 200 : 502)
    }
    m = path.match(/^\/v1\/cards\/(done|snooze|handle)$/)
    if (m && POST) {
      if (!body.id) return json({ ok: false, error: 'id required' }, 400)
      return json(await cardAction(String(body.id), m[1], body))
    }
    if (path === '/v1/devices' && POST) {
      const token = textOf(body.token, 400)
      if (!HEX.test(token)) return json({ ok: false, error: 'token required (the hex push token of the device)' }, 400)
      const env: Env = body.env === 'production' ? 'production' : 'sandbox'
      db.query('insert or replace into devices (token, env, updated_at) values (?, ?, ?)').run(token, env, now())
      // A phone gets a new token now and then; the twenty newest are plenty.
      db.query('delete from devices where token not in (select token from devices order by updated_at desc limit 20)').run()
      log('device registered', { env }); return json({ ok: true })
    }
    // The app turned notifications off, or was disconnected from this server: stop ringing that phone.
    if (path === '/v1/devices/remove' && POST) {
      const token = textOf(body.token, 400)
      if (!HEX.test(token)) return json({ ok: false, error: 'token required (the hex push token of the device)' }, 400)
      const gone = db.query('delete from devices where token = ?').run(token).changes
      log('device removed', { known: gone > 0 }); return json({ ok: true })
    }
    if (path === '/v1/notify' && POST) return json({ ok: true, ...addNote(body) })
    if (path === '/v1/cards/act' && POST) {
      if (!body.id || !body.action) return json({ ok: false, error: 'id and action required' }, 400)
      const r = await act(String(body.id), String(body.action), body)
      return json(r, r.ok ? 200 : 502)
    }
    if (path === '/v1/search' && GET) {
      const qText = (url.searchParams.get('q') ?? '').trim().slice(0, 200)
      if (qText.length < 2) return json({ messages: [], cards: [] })
      await sourcesReady()
      const byThread = new Map(cfg().agents.filter((a) => a.threadId).map((a) => [a.threadId, a.id]))
      const lower = qText.toLowerCase()
      const messages = t3.searchMessages([...byThread.keys()], qText).filter((m) => !isSlash(m)).map((m) => {
        // The bot's "» suggestions" line is for the reply buttons, not the snippet.
        const text = m.role === 'assistant' ? splitSuggestions(m.text).text : m.text
        return { agent: byThread.get(m.threadId), role: m.role, at: m.at, id: m.id, snippet: snippet(text, qText) }
      })
      const cards = allCards().filter((c) => [c.title, c.why, c.steps, c.detail, ...(Array.isArray(c.fields) ? c.fields : []).map((f) => f?.value)]
        .some((x) => x && String(x).toLowerCase().includes(lower))).slice(0, 20)
      return json({ messages, cards })
    }
    if (path === '/v1/share' && POST) {
      const a = agentById(String(body.agent ?? '')) ?? chief()
      if (!a) return json({ ok: false, error: NO_BOTS }, 404)
      if (!a.threadId) return json({ ok: false, error: 'that bot has no thread' }, 404)
      const parts = [textOf(body.note, 4000), body.url ? `Shared link: ${textOf(body.url, 4000)}` : '', body.text ? `Shared text:\n${textOf(body.text, 20000)}` : '',
        ...(Array.isArray(body.images) ? saveImages(body.images).map(imageLine) : [])].filter(Boolean)
      if (!parts.length) return json({ ok: false, error: 'nothing to share' }, 400)
      const r = await sendTo(a, `${person()} shared this with you from the phone:\n\n${parts.join('\n\n')}`)
      record('share', { agent: a.id, ok: r.ok })
      return json({ ...r, agent: a.id }, r.ok ? 200 : 502)
    }
    if (path === '/v1/live' && POST) {
      const id = String(body.agent ?? ''), token = textOf(body.token, 400)
      if (!agentById(id) || !HEX.test(token)) return json({ ok: false, error: 'agent and token required' }, 400)
      // The build's APNs environment, when the app says it; else the one its device registered with.
      saveLive(id, { token, startedAt: Number(body.startedAt) > 0 ? Number(body.startedAt) : Math.floor(Date.now() / 1000), env: isEnv(body.env) ? body.env : defaultEnv(), at: Date.now() })
      liveSaid.delete(id)
      return json({ ok: true })
    }
    if (path === '/v1/settings' && GET) return json(settings())
    if (path === '/v1/settings' && POST) return json(saveSettings(body))
    if (path === '/v1/notes/wrong' && POST) {
      const n = db.query('select * from notes where id = ?').get(String(body.id ?? '')) as any
      if (!n) return json({ ok: false, error: 'no such note' }, 404)
      const bot = agentById(n.agent) ?? chief()
      if (!bot) return json({ ok: false, error: NO_BOTS }, 404)
      if (!bot.threadId) return json({ ok: false, error: 'that bot has no thread' }, 404)
      const words = textOf(body.text, 4000)
      const r = await sendTo(bot, `From T3 Bot: ${person()} says this was wrong: "${n.title}"${n.body ? ` (${n.body})` : ''}.` +
        (words ? ` In their words: ${words}.` : '') + ` Undo it if you can, write down the lesson so it does not happen again, and say in one line what you did.`)
      if (r.ok) db.query('update notes set read_at = ? where id = ?').run(now(), n.id)
      record('wrong', { id: n.id, ok: r.ok })
      return json(r, r.ok ? 200 : 502)
    }
    m = path.match(/^\/v1\/agents\/([a-z0-9-]+)\/edit$/)
    if (m && POST) return json(await editAgent(m[1], body))
    if (path === '/v1/agents' && POST) return json(await newAgent(body))
    if (path === '/v1/routines/enabled' && POST) {
      const id = textOf(body.id, 200)
      const thread = t3.routineThread(id)
      if (thread === undefined) return json({ ok: false, error: 'routine not found' }, 404)
      // Only the routines the app shows: the ones that post into a bot's thread or a thread it watches.
      const shown = new Set(cfg().agents.flatMap((a) => [a.threadId, ...t3.threadsByPrefix(a.watch).map((w) => w.id)]).filter(Boolean))
      if (!thread || !shown.has(thread)) return json({ ok: false, error: 'that routine does not belong to a bot' }, 403)
      const r = await t3.setRoutineEnabled(id, !!body.enabled)
      record('routine', { id, enabled: !!body.enabled, ok: r.ok })
      return json(r, r.ok ? 200 : 502)
    }
    if (path === '/v1/phone/sync' && POST) {
      const list = (x: unknown, max: number) => (Array.isArray(x) ? x.filter((i) => i && typeof i === 'object').slice(0, max) : [])
      const tmp = `${PHONE}.tmp`
      writeFileSync(tmp, JSON.stringify({ at: now(), calendar: list(body.calendar, 5000), contacts: list(body.contacts, 20000) }), { mode: 0o600 })
      chmodSync(tmp, 0o600)
      renameSync(tmp, PHONE)
      return json({ ok: true })
    }
    if (path === '/v1/phone/forget' && POST) {
      rmSync(PHONE, { force: true })
      return json({ ok: true })
    }
    if (path.startsWith('/v1/phone/') && GET) {
      let ph: any = null
      try { ph = JSON.parse(readFileSync(PHONE, 'utf8')) } catch {}
      if (!ph || typeof ph !== 'object') return json({ ok: false, error: 'the phone calendar and contacts have not been shared in T3 Bot' }, 404)
      if (path === '/v1/phone/calendar') return json({ at: ph.at, events: Array.isArray(ph.calendar) ? ph.calendar : [] })
      if (path === '/v1/phone/contacts') {
        const qq = (url.searchParams.get('q') ?? '').toLowerCase()
        const all: any[] = Array.isArray(ph.contacts) ? ph.contacts : []
        return json({ at: ph.at, contacts: qq ? all.filter((c) => JSON.stringify(c).toLowerCase().includes(qq)).slice(0, 20) : all.slice(0, 50), total: all.length })
      }
    }
    if (path === '/v1/know' && GET) {
      return json({ notes: db.query(`select * from notes where kind = 'know' and created_at > ? order by created_at desc`).all(dayStart()) })
    }
    if (path === '/v1/test-push' && POST) {
      await send({ title: textOf(body.title, 200) || 'T3 Bot', body: textOf(body.body, 1000) || 'Push works.', category: 'REPLY',
        data: { agent: agentById(String(body.agent ?? ''))?.id ?? chiefOrNone() } }, { night: 'ring' })
      return json({ ok: true, devices: devices().length, push: !NO_PUSH && apnsConfigured() })
    }
    return json({ error: 'not found' }, 404)
  } catch (e) {
    if (e instanceof Bad) return json({ ok: false, error: e.message }, 400)
    log('request error', { path, e: String((e as any)?.stack ?? e).slice(0, 400) })
    // A read of T3 Code that failed says so in plain words; anything else is a fault of this server.
    return json({ ok: false, error: e instanceof t3.ReadError ? e.message : `T3 Bot hit an error (${reason(e)}). The server log has the details.` }, 500)
  }
}

log(`t3bot ${VERSION} listening on ${HOST}:${PORT}`, { config: tilde(configPath()), bots: cfg().agents.length, ...(t3.READONLY ? { readOnly: true } : {}) })
if (HOST !== '127.0.0.1' && HOST !== 'localhost' && HOST !== '::1') log('reachable from the network over plain http: use it on a network you trust, or put Tailscale in front')
tick()
