/**
 * Where T3 Bot keeps its files and how it reads its config. Shared by the server and the CLI.
 *
 * Config file, first one that exists: $T3BOT_CONFIG, ~/.config/t3bot/agents.json, <repo>/config/agents.json.
 * The rules files (BOTS.md, CHIEF.md, GROUP.md) follow the same order: beside a config of your own, then
 * ~/.config/t3bot, then the defaults that ship in <repo>/config. A new install works with the defaults, and a copy
 * of your own in ~/.config/t3bot wins over them even when the config itself is the one in the repo.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'fs'
import { homedir } from 'os'
import { dirname, join, resolve } from 'path'

/** Server and CLI version, as `/v1/hello` reports it. */
export const VERSION = '0.2.0'

export const HOME = process.env.HOME || homedir()
export const ROOT = resolve(import.meta.dir, '..')
export const DEFAULT_PORT = 8809
export const PORT = Number(process.env.T3BOT_PORT) || DEFAULT_PORT

/** Token, push key, the user's own config and rules. Mode 0700; nothing in it belongs in git. */
export const CONFIG_DIR = process.env.T3BOT_CONFIG_DIR || join(HOME, '.config/t3bot')
export const TOKEN_FILE = process.env.T3BOT_TOKEN_FILE || join(CONFIG_DIR, 'token')
export const APNS_FILE = join(CONFIG_DIR, 'apns.json')
/** On a machine that is not the server: the server's address, written by `t3bot connect`. */
export const URL_FILE = join(CONFIG_DIR, 'url')
export const USER_CONFIG = join(CONFIG_DIR, 'agents.json')
export const REPO_CONFIG = join(ROOT, 'config/agents.json')
/** The server's own state: its SQLite file, uploads, what the phone shared. */
export const DATA_DIR = process.env.T3BOT_DATA_DIR || join(HOME, '.local/share/t3bot')

/** `~/x` instead of `/Users/me/x`: how paths are written in prompts and printed by the CLI. */
export const tilde = (p: string) => (p === HOME || p.startsWith(HOME + '/') ? '~' + p.slice(HOME.length) : p)
export const untilde = (p: string) => p.replace(/^~(?=\/|$)/, HOME)

/** The config file in use. When none exists yet: where `t3bot setup` writes one. */
export function configPath(): string {
  const env = process.env.T3BOT_CONFIG ? resolve(untilde(process.env.T3BOT_CONFIG)) : ''
  if (env) return env
  if (existsSync(USER_CONFIG)) return USER_CONFIG
  if (existsSync(REPO_CONFIG)) return REPO_CONFIG
  return USER_CONFIG
}

/** BOTS.md, CHIEF.md or GROUP.md: the user's own copy when there is one, else the default in the repo. */
export function rulesPath(name: 'BOTS.md' | 'CHIEF.md' | 'GROUP.md'): string {
  const shipped = join(ROOT, 'config', name)
  for (const own of [join(dirname(configPath()), name), join(CONFIG_DIR, name)]) {
    if (own !== shipped && existsSync(own)) return own
  }
  return shipped
}

/** Where a bot writes its own lasting instructions. */
export const botNotesPath = (id: string) => join(dirname(configPath()), 'bots', `${id}.md`)

/**
 * Turns a command from the config into an argv: `~` is the home folder, and `./x` is a file beside the config,
 * or in the repo when it is not there (so a config kept in the repo can still say `./local/adapters/x.py`).
 */
export function expandArgv(argv: unknown): string[] {
  if (!Array.isArray(argv)) return []
  const base = dirname(configPath())
  return argv.map((x) => {
    const s = untilde(String(x))
    if (!s.startsWith('./')) return s
    const beside = join(base, s.slice(2))
    return existsSync(beside) ? beside : join(ROOT, s.slice(2))
  })
}

// ---------- the config ----------

export type Face = { skin: string }
export type AgentConf = {
  id: string; name: string; role: string; threadId: string; watch: string[]
  kind?: 'bot' | 'group'; face?: Face; hidden?: boolean; members?: string[]
}
/**
 * A card source: any command that prints {"cards": [...]} in the generic card format (docs/CARDS.md), and
 * optionally marks one done. This is how T3 Bot stays generic: your own to-do lists, release queues or mail
 * drafts plug in through small adapter scripts of your own.
 *   list: argv run every `ttl` seconds (default 30). done: argv with "{id}" replaced by the card's id in that source.
 *   timeout: seconds before a run is stopped (default 60 for list, 30 for done).
 */
export type SourceConf = { id: string; name: string; agent?: string; list: string[]; done?: string[]; ttl?: number; timeout?: number }
export type HandlerConf = { cmd: string[]; timeout?: number }
/** `instanceId` is T3 Code's provider instance for the model (claudeAgent unless the config says otherwise). */
export type Defaults = { model: string; effort: string; runtimeMode: string; instanceId: string }
export type Config = {
  environmentId: string; projectId: string
  night: { from: string; to: string }; digestAt: string
  agents: AgentConf[]; sources: SourceConf[]; handlers: Record<string, HandlerConf>
  user?: { name?: string }; defaults?: Partial<Defaults>; chief?: string
  /** Days that photos sent from the phone, read notes, digest notes and the record of card taps are kept. 0 keeps everything. */
  keepDays?: number
}

export const DEFAULTS: Defaults = { model: 'claude-opus-5-5', effort: 'high', runtimeMode: 'full-access', instanceId: 'claudeAgent' }
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/
export const isHHMM = (x: unknown): x is string => typeof x === 'string' && HHMM.test(x)

/** Fills what is missing, in place, so the rest of the code never meets a half-written config. Unknown keys stay. */
export function normalize(raw: any): Config {
  const c = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  c.environmentId = typeof c.environmentId === 'string' ? c.environmentId : ''
  c.projectId = typeof c.projectId === 'string' ? c.projectId : ''
  const night = c.night && typeof c.night === 'object' ? c.night : {}
  c.night = { ...night, from: isHHMM(night.from) ? night.from : '23:00', to: isHHMM(night.to) ? night.to : '08:00' }
  c.digestAt = isHHMM(c.digestAt) ? c.digestAt : '20:00'
  c.agents = (Array.isArray(c.agents) ? c.agents : []).filter((a: any) => a && typeof a.id === 'string' && /^[a-z0-9-]+$/.test(a.id))
  for (const a of c.agents) {
    a.name = String(a.name ?? a.id)
    a.role = String(a.role ?? '')
    a.threadId = typeof a.threadId === 'string' ? a.threadId : ''
    a.watch = Array.isArray(a.watch) ? a.watch.filter((w: unknown) => typeof w === 'string' && w.replace(/[%_]/g, '').length > 0) : []
    if (a.members !== undefined && !Array.isArray(a.members)) a.members = []
  }
  c.sources = (Array.isArray(c.sources) ? c.sources : []).filter((s: any) => s && typeof s.id === 'string' && Array.isArray(s.list) && s.list.length)
  c.handlers = c.handlers && typeof c.handlers === 'object' && !Array.isArray(c.handlers) ? c.handlers : {}
  return c as Config
}

let cached: Config = normalize({})
let cachedFrom = ''
let cachedMtime = -1
let lastComplaint = ''

/** The config, read again whenever the file changes. A file that is missing or broken never stops the server. */
export function loadConfig(warn: (m: string, x?: unknown) => void = () => {}): Config {
  const path = configPath()
  let mtime = 0
  try { mtime = statSync(path).mtimeMs } catch {}
  if (path === cachedFrom && mtime === cachedMtime) return cached
  const complain = (m: string) => { const k = `${path}:${mtime}:${m}`; if (k !== lastComplaint) { lastComplaint = k; warn(m, { path: tilde(path) }) } }
  if (!mtime) {
    complain('no config yet: run `t3bot setup`')
    cached = normalize({})
  } else {
    try {
      cached = normalize(JSON.parse(readFileSync(path, 'utf8')))
    } catch (e) {
      // Keep the last good one when it came from the same file (a half-saved edit); otherwise start empty.
      complain(`config unreadable, ${path === cachedFrom ? 'keeping the last good one' : 'starting empty'}: ${String(e).slice(0, 160)}`)
      if (path !== cachedFrom) cached = normalize({})
    }
  }
  cachedFrom = path
  cachedMtime = mtime
  return cached
}

/** Writes the config back where it was read from, in one rename so a reader never sees half a file. */
export function saveConfig(next: Config) {
  const path = configPath()
  mkdirSync(dirname(path), { recursive: true })
  const tmp = `${path}.tmp`
  writeFileSync(tmp, JSON.stringify(next, null, 2) + '\n')
  renameSync(tmp, path)
  cachedMtime = -1
}

/** The person's display name, as `/v1/hello` gives it to the app. */
export const userName = (c: Config) => (typeof c.user?.name === 'string' && c.user.name.trim() ? c.user.name.trim().slice(0, 40) : 'you')
/** How a prompt names the person to a bot: their name when the config has one, else "the user". */
export const userInPrompt = (c: Config) => (userName(c) === 'you' ? 'the user' : userName(c))

/**
 * How long history is kept, in days: photos sent from the phone, notes that were read, the notes of the evening
 * digest and the record of card taps older than this are deleted. `T3BOT_KEEP_DAYS` wins over `keepDays` in the
 * config. 0, or neither set, keeps everything forever; `t3bot setup` writes 180 into a new config.
 */
export function keepDays(c: Config): number {
  const pick = (x: unknown) => (x === undefined || x === null || x === '' ? undefined : Number(x))
  const n = pick(process.env.T3BOT_KEEP_DAYS) ?? pick(c.keepDays) ?? 0
  return Number.isFinite(n) && n > 0 ? n : 0
}

/** The bot that gets what no other bot claims: `chief` in the config, else the agent with id `chief`, else the first bot. */
export function chiefId(c: Config): string | undefined {
  if (typeof c.chief === 'string' && c.agents.some((a) => a.id === c.chief)) return c.chief
  return (c.agents.find((a) => a.id === 'chief') ?? c.agents.find((a) => (a.kind ?? 'bot') === 'bot') ?? c.agents[0])?.id
}

/** Model, effort and runtime mode for the threads T3 Bot creates. */
export function threadDefaults(c: Config): Defaults {
  const d = c.defaults && typeof c.defaults === 'object' ? c.defaults : {}
  const str = (x: unknown, fallback: string) => (typeof x === 'string' && x.trim() ? x.trim() : fallback)
  return {
    model: str(d.model, DEFAULTS.model), effort: str(d.effort, DEFAULTS.effort),
    runtimeMode: str(d.runtimeMode, DEFAULTS.runtimeMode), instanceId: str(d.instanceId, DEFAULTS.instanceId),
  }
}

/** True when a push key is set up. */
export const apnsConfigured = () => existsSync(APNS_FILE)
