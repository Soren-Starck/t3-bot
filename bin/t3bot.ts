/**
 * t3bot: set up T3 Bot, pair the phone, and let agents reach the person on it.
 *
 * Getting started (on the computer that runs T3 Code):
 *   t3bot setup [--project <name, id or path>] [--name <your name>] [--dry-run] [--force] [--if-needed]
 *       Finds T3 Code, lets you pick a project, creates the first bot (Chief) there and writes the config.
 *       --dry-run shows what it would do and changes nothing. An existing config is never replaced without --force.
 *       --if-needed does nothing when a config with bots is already there (what the installer uses).
 *   t3bot pair [--url <address>] [--no-qr] [--invert] [--link-only]
 *       Prints the pairing link and a QR code: scan it with the iPhone camera and the app opens connected.
 *   t3bot doctor     Checks T3 Code, the config, the token, the server, the address for the phone and the push key.
 *   t3bot demo [--port 8810] [--frozen] [--lan] [--host <address to listen on>] [--url <address for the phone>] [--no-qr]
 *       Starts the demo server (invented bots, no T3 Code needed) and prints its pairing link.
 *       It listens on this computer only (127.0.0.1): the demo's token is public. --lan opens it to your network
 *       for a phone on the same Wi-Fi (also T3BOT_DEMO_HOST=0.0.0.0, or --host with one address to listen on).
 *   t3bot connect '<pairing link>' [--force]
 *       On another computer: saves the server's address and token, so `t3bot` there talks to your server.
 *       --force replaces a token that computer already holds.
 *
 * For agents:
 *   t3bot notify --kind alarm|approve|do|know --title "..." [--body "..."] [--agent <bot id>] [--link URL] [--key STABLE-KEY]
 *     alarm    rings at once, even during quiet hours unless the app's settings say otherwise (something down, money at risk)
 *     approve  the work is done and needs a yes; rings unless it is quiet hours (then in the morning)
 *     do       only the person can do it (a signature, a login, a purchase); rings unless it is quiet hours
 *     know     done without them; nothing rings, it goes into the evening digest
 *   --agent is the bot the card belongs to (ids in `t3bot roster`); without it, the Chief.
 *   --kind is `know` when left out. --key makes a note replaceable: the same key updates it instead of adding a second one.
 *   Richer cards (all optional, repeatable where it makes sense):
 *     --field "Amount=24 EUR"        a labelled value          --check "Tests=pass|fail|pending"   a check line
 *     --edit "text" [--edit-label "Reply"]   text the person can change before acting
 *     --action "Approve=what the bot should do"   a button; the tap sends that (and the edited text) to your thread
 *     --face-id                      Face ID before any of its buttons
 *
 *   t3bot draft --agent <id> --to "<name, number or email>" --text "..." [--via imessage|mail] [--subject "..."]
 *   t3bot draft --agent <id> --event "<title>" --start <ISO> --end <ISO> [--location "..."]
 *     (--key works here too.) A message or calendar event for the person to send or add themselves. It shows as a card; nothing goes
 *     out until they tap Send in the iPhone's own composer. Never say a draft was sent.
 *   t3bot phone calendar          the iPhone calendar (next two weeks), when it was shared in T3 Bot
 *   t3bot phone contacts <name>   matching contacts from the iPhone
 *
 *   t3bot roster [--json]   the bots: id, name, job, thread id
 *   t3bot needs [--json]    the ranked list of what needs the person, as the app shows it
 *   t3bot home              everything the app's first screen shows, as JSON
 *   t3bot agent <id>        one bot's recent conversation, runs and cards, as JSON
 *   t3bot version
 *
 * The server's address comes from $T3BOT_URL, else the file `t3bot connect` wrote, else this computer.
 * Exit codes: 0 done, 1 the server could not be reached or refused it, 2 the command was not written right.
 */
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from 'fs'
import { networkInterfaces } from 'os'
import { dirname, join } from 'path'
import {
  APNS_FILE, CONFIG_DIR, DEFAULT_PORT, HOME, PORT, ROOT, TOKEN_FILE, URL_FILE, USER_CONFIG, VERSION,
  chiefId, configPath, normalize, rulesPath, threadDefaults, tilde, untilde, userName,
} from '../server/config'
import { newToken } from '../server/guard'
import { apnsStatus } from '../server/push'
import { qrTerminal } from '../server/qr'
import * as t3 from '../server/t3'

const args = process.argv.slice(2)
const cmd = args.shift()
// The value after --name. Another flag there (`--title --body x`) means the value was left out; text that
// merely starts with two dashes ("-- see the log") is a value.
const FLAG = /^--[a-z][a-z0-9-]*$/
const opt = (name: string) => { const i = args.indexOf(`--${name}`); return i >= 0 && args[i + 1] !== undefined && !FLAG.test(args[i + 1]) ? args[i + 1] : undefined }
const has = (name: string) => args.includes(`--${name}`)
const optAll = (name: string) => args.flatMap((a, i) => (a === `--${name}` && args[i + 1] !== undefined && !FLAG.test(args[i + 1]) ? [args[i + 1]] : []))
const keyValue = (x: string) => { const i = x.indexOf('='); return i < 0 ? [x, ''] : [x.slice(0, i), x.slice(i + 1)] }
const fail = (m: string, code = 2): never => { console.error(m); process.exit(code) }
const say = (m = '') => console.log(m)
const LOCAL = `http://127.0.0.1:${PORT}`

// ---------- the server's address and token ----------

const readTrim = (file: string) => { try { return readFileSync(file, 'utf8').trim() } catch { return '' } }
/** Where this command finds the server: $T3BOT_URL, the address `t3bot connect` saved, or this computer. */
const base = (process.env.T3BOT_URL || readTrim(URL_FILE) || LOCAL).replace(/\/+$/, '')
const readToken = () => process.env.T3BOT_TOKEN || readTrim(TOKEN_FILE)
function needToken(): string {
  const t = readToken()
  if (!t) fail(`No token in ${tilde(TOKEN_FILE)}. On the computer that runs the server, start it once (deploy/install.sh). ` +
    `On another computer, run \`t3bot pair\` on the server and \`t3bot connect '<link>'\` here, or set T3BOT_TOKEN.`)
  return t
}
async function call(path: string, body?: unknown): Promise<{ status: number; data: any }> {
  const token = needToken()
  try {
    const r = await fetch(base + path, {
      method: body ? 'POST' : 'GET',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(30_000),
    })
    // A token the server does not know: said in words, since the server's own answer is only "unauthorized".
    if (r.status === 401) {
      fail(`The T3 Bot server at ${base} refused the token ${process.env.T3BOT_TOKEN ? 'in $T3BOT_TOKEN' : `in ${tilde(TOKEN_FILE)}`}. ` +
        `It belongs to another server, or the server's token changed: run \`t3bot pair\` on the server and \`t3bot connect '<link>'\` here.`, 1)
    }
    return { status: r.status, data: await r.json().catch(() => ({})) as any }
  } catch (e) {
    return fail(`The T3 Bot server at ${base} did not answer (${String((e as any)?.message ?? e).slice(0, 120)}). ` +
      `Is it running? \`t3bot doctor\` checks.`, 1)
  }
}
/** Why the server said no, in its own words when it gave some. */
const refusal = (r: { status: number; data: any }) => (typeof r.data?.error === 'string' && r.data.error ? r.data.error : `the server answered ${r.status}`)
/**
 * A command's options, checked before anything is sent: an option that does not exist (a typo would otherwise
 * drop the text it carried without a word) and an option whose value was left out both stop here, with exit code 2.
 */
function checkOptions(command: string, takeValue: string[], switches: string[] = []) {
  for (let i = 0; i < args.length; i++) {
    const a = args[i]
    if (!FLAG.test(a)) continue
    const name = a.slice(2)
    if (switches.includes(name)) continue
    if (!takeValue.includes(name)) fail(`t3bot ${command}: no option ${a}. \`t3bot help\` lists them.`)
    if (args[i + 1] === undefined || FLAG.test(args[i + 1])) fail(`t3bot ${command}: ${a} needs a value.`)
    i++
  }
}
const KINDS = ['alarm', 'approve', 'do', 'know']
async function probe(url: string, token?: string, ms = 2500): Promise<{ ok: boolean; status: number; data: any }> {
  try {
    const r = await fetch(url, { headers: token ? { authorization: `Bearer ${token}` } : {}, signal: AbortSignal.timeout(ms) })
    return { ok: r.ok, status: r.status, data: await r.json().catch(() => ({})) }
  } catch { return { ok: false, status: 0, data: {} } }
}

// ---------- which address the phone can use ----------

function sh(argv: string[], ms = 5000): { ok: boolean; out: string } {
  try {
    const p = Bun.spawnSync(argv, { stdout: 'pipe', stderr: 'pipe', timeout: ms })
    return { ok: p.exitCode === 0, out: p.stdout.toString() }
  } catch { return { ok: false, out: '' } }
}
const tailscaleBin = () => [Bun.which('tailscale'), '/usr/local/bin/tailscale', '/opt/homebrew/bin/tailscale',
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale'].find((p): p is string => !!p && existsSync(p)) ?? null

/** Tailscale on this computer: whether it is connected, this machine's name on the tailnet, and the address that serves `port`. */
function tailscale(port: number): { bin: string; running: boolean; dns: string; served: string | null } | null {
  const bin = tailscaleBin()
  if (!bin) return null
  let running = false, dns = '', served: string | null = null
  try {
    const st = JSON.parse(sh([bin, 'status', '--json']).out)
    running = st.BackendState === 'Running'
    dns = String(st.Self?.DNSName ?? '').replace(/\.$/, '')
  } catch {}
  if (!running) return { bin, running, dns, served }
  try {
    const sv = JSON.parse(sh([bin, 'serve', 'status', '--json']).out || '{}')
    const local = new RegExp(`^(https?\\+insecure|https?)://(127\\.0\\.0\\.1|localhost|\\[::1\\]):${port}(/|$)`)
    for (const [hostPort, web] of Object.entries<any>(sv.Web ?? {})) {
      if (!Object.values<any>(web?.Handlers ?? {}).some((h) => local.test(String(h?.Proxy ?? '')))) continue
      const p = hostPort.split(':').pop()
      const https = sv.TCP?.[p ?? '']?.HTTPS !== false
      served = `${https ? 'https' : 'http'}://${hostPort.replace(https ? /:443$/ : /:80$/, '')}`
      break
    }
    if (!served && dns) {
      for (const [p, tcp] of Object.entries<any>(sv.TCP ?? {})) {
        if (!new RegExp(`^(127\\.0\\.0\\.1|localhost):${port}$`).test(String(tcp?.TCPForward ?? ''))) continue
        served = `${tcp.TerminateTLS ? 'https' : 'http'}://${dns}${tcp.TerminateTLS && p === '443' ? '' : `:${p}`}`
        break
      }
    }
  } catch {}
  return { bin, running, dns, served }
}
/** This computer's address on the home network (never the Tailscale one). */
function lanAddress(): string | null {
  const all = Object.entries(networkInterfaces()).flatMap(([name, list]) => (list ?? []).map((i) => ({ name, ...i })))
    .filter((i) => i.family === 'IPv4' && !i.internal && !/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(i.address) && !i.address.startsWith('169.254.'))
  return (all.find((i) => i.name === 'en0') ?? all[0])?.address ?? null
}

type Reach = { url: string | null; how: 'given' | 'saved' | 'tailscale' | 'lan' | 'none'; notes: string[] }
/** The address to put in the pairing link, and what the person should know about it. */
async function phoneAddress(port: number, given?: string): Promise<Reach> {
  const explicit = given || process.env.T3BOT_PUBLIC_URL
  if (explicit) return { url: explicit.replace(/\/+$/, ''), how: 'given', notes: [] }
  const saved = readTrim(URL_FILE)
  if (saved && port === PORT) return { url: saved.replace(/\/+$/, ''), how: 'saved', notes: [`Address saved by \`t3bot connect\` in ${tilde(URL_FILE)}.`] }
  const ts = tailscale(port)
  if (ts?.running && ts.served) return { url: ts.served, how: 'tailscale', notes: ['Served by Tailscale: works wherever the phone has Tailscale on, over HTTPS.'] }
  const notes: string[] = []
  if (ts?.running) notes.push(`Tailscale is on but does not serve the server yet. For an HTTPS address that works away from home, run: tailscale serve --bg --https=${port} http://127.0.0.1:${port}`)
  else if (ts) notes.push('Tailscale is installed but not connected. Connected, it gives the phone an HTTPS address that works away from home.')
  else notes.push('Tailscale is not installed. With it (free for personal use) the phone reaches the server over HTTPS from anywhere.')
  const lan = lanAddress()
  if (!lan) return { url: null, how: 'none', notes: [...notes, 'This computer has no network address the phone could use.'] }
  const url = `http://${lan}:${port}`
  notes.push('This address is plain http on your home network: it only works while the phone is on the same Wi-Fi, and anyone on that network could read the traffic. Fine at home, not on a shared network.')
  if (!(await probe(`${url}/health`, undefined, 1500)).ok) {
    notes.push(`The server does not answer on ${url} yet: it listens on this computer only. Run deploy/install.sh again (without Tailscale it opens the server to your network), or start it with T3BOT_HOST=0.0.0.0.`)
  }
  return { url, how: 'lan', notes }
}
const pairingLink = (url: string, token: string) => `t3bot://connect?url=${encodeURIComponent(url)}&token=${encodeURIComponent(token)}`
function printQr(link: string) {
  try {
    const color = !!process.stdout.isTTY && !process.env.NO_COLOR
    say(qrTerminal(link, { color, invert: has('invert') }))
    if (!color) say(has('invert') ? '' : '(If the phone cannot read the code on a dark terminal, add --invert.)')
  } catch (e) {
    say(`(No QR code: ${String((e as any)?.message ?? e)}. Use the link.)`)
  }
}

// ---------- commands ----------

async function notify() {
  checkOptions('notify', ['kind', 'title', 'body', 'agent', 'link', 'key', 'field', 'check', 'edit', 'edit-label', 'action'], ['face-id'])
  const title = opt('title')?.trim()
  if (!title) fail('t3bot notify needs --title "..."')
  const kind = (opt('kind') ?? 'know').trim().toLowerCase()
  if (!KINDS.includes(kind)) fail(`t3bot notify: --kind is ${KINDS.join(', ')} (not "${kind}").${kind === 'draft' ? ' For a draft, use `t3bot draft`.' : ''}`)
  for (const f of [...optAll('field'), ...optAll('check'), ...optAll('action')]) {
    if (!keyValue(f)[0].trim()) fail(`t3bot notify: "${f}" has no label. Write it as "Label=value".`)
  }
  const r = await call('/v1/notify', {
    kind, title, body: opt('body'), agent: opt('agent'), link: opt('link'), key: opt('key'),
    fields: optAll('field').map(keyValue).map(([label, value]) => ({ label, value })),
    checks: optAll('check').map(keyValue).map(([label, state]) => ({ label, state: ['pass', 'fail', 'pending'].includes(state) ? state : 'pending' })),
    edit: opt('edit') !== undefined ? { label: opt('edit-label') ?? 'Text', text: opt('edit') } : undefined,
    actions: optAll('action').map(keyValue).map(([label, message]) => ({ label, message })),
    faceId: has('face-id'),
  })
  if (r.status !== 200 || !r.data.ok) fail(`t3bot notify failed: ${refusal(r)}`, 1)
  say(JSON.stringify(r.data))
}

async function draft() {
  checkOptions('draft', ['agent', 'to', 'text', 'via', 'subject', 'event', 'start', 'end', 'location', 'key'])
  const event = opt('event')
  const d: any = event
    ? { event, start: opt('start'), end: opt('end'), location: opt('location') }
    : { to: opt('to'), text: opt('text'), via: opt('via') ?? 'imessage', subject: opt('subject') }
  if (event ? !d.start : !d.to || !d.text) fail(event ? 't3bot draft --event needs --start' : 't3bot draft needs --to and --text')
  const title = event ? `Add to your calendar: ${event}` : `Draft ${d.via === 'mail' ? 'mail' : 'message'} to ${d.to}`
  const r = await call('/v1/notify', { kind: 'draft', title, body: event ? `${d.start}${d.end ? ` to ${d.end}` : ''}` : d.text, agent: opt('agent'), key: opt('key'), draft: d })
  if (r.status !== 200 || !r.data.ok) fail(`t3bot draft failed: ${refusal(r)}`, 1)
  say(JSON.stringify({ ...r.data, note: 'shown as a card in T3 Bot; the person sends it themselves' }))
}

async function phone() {
  const what = args[0]
  if (what !== 'calendar' && what !== 'contacts') fail('t3bot phone calendar | t3bot phone contacts <name>')
  const r = what === 'contacts' ? await call(`/v1/phone/contacts?q=${encodeURIComponent(args.slice(1).join(' '))}`) : await call('/v1/phone/calendar')
  if (r.status !== 200) fail(refusal(r), 1)
  say(JSON.stringify(r.data, null, 1))
}

async function getJson(path: string) {
  const r = await call(path)
  if (r.status !== 200) fail(refusal(r), 1)
  return r.data
}

async function needs() {
  const data = await getJson('/v1/home')
  if (has('json')) return say(JSON.stringify(data.needs ?? [], null, 1))
  if (!(data.needs ?? []).length) return say('Nothing needs you.')
  for (const c of data.needs) say(`${c.rank} ${String(c.agent ?? '').padEnd(7)} ${String(c.source ?? '').padEnd(8)} ${c.title}`)
}

async function roster() {
  let list: any[] | null = null
  const token = readToken()
  if (token) {
    const r = await probe(`${base}/v1/home`, token, 20_000)
    if (r.ok) list = r.data.agents ?? []
  }
  // The server is not up: the config on this computer says the same.
  if (!list) {
    if (!existsSync(configPath())) fail('No bots yet: run `t3bot setup`.')
    list = normalize(JSON.parse(readFileSync(configPath(), 'utf8'))).agents
  }
  const rows = list.map((a) => ({ id: a.id, name: a.name, job: a.role, threadId: a.threadId, kind: a.kind ?? 'bot',
    ...(a.members?.length ? { members: a.members } : {}), ...(a.hidden ? { hidden: true } : {}) }))
  if (has('json')) return say(JSON.stringify(rows, null, 1))
  if (!rows.length) return say('No bots yet: run `t3bot setup`.')
  for (const a of rows) say(`${a.id.padEnd(10)} ${a.name.padEnd(16)} ${a.kind === 'group' ? `[group: ${(a as any).members?.join(', ') ?? ''}] ` : ''}${a.job}\n${' '.repeat(11)}thread ${a.threadId || '(none)'}`)
}

function connect() {
  const link = args.find((a) => !a.startsWith('--')) ?? ''
  let url = '', token = ''
  try {
    const u = new URL(link)
    if (u.protocol !== 't3bot:') throw new Error('not a t3bot link')
    url = (u.searchParams.get('url') ?? '').replace(/\/+$/, '')
    token = u.searchParams.get('token') ?? ''
    if (!/^https?:\/\//.test(url) || !token) throw new Error('incomplete')
  } catch {
    fail("t3bot connect needs the pairing link printed by `t3bot pair` on the server, in quotes: t3bot connect 't3bot://connect?url=...&token=...'")
  }
  const current = readTrim(TOKEN_FILE)
  if (current && current !== token && !has('force')) {
    fail(`${tilde(TOKEN_FILE)} already holds another token (this computer may be a server itself). Add --force to replace it.`)
  }
  mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 })
  writeFileSync(TOKEN_FILE, token + '\n', { mode: 0o600 }); chmodSync(TOKEN_FILE, 0o600)
  writeFileSync(URL_FILE, url + '\n', { mode: 0o600 })
  say(`Saved. \`t3bot\` on this computer now talks to ${url}.`)
}

async function pair() {
  let token = readToken()
  if (!token) {
    if (readTrim(URL_FILE)) needToken()
    // A new install: the same token the server would make on its first start.
    mkdirSync(dirname(TOKEN_FILE), { recursive: true, mode: 0o700 })
    token = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url')
    writeFileSync(TOKEN_FILE, token + '\n', { mode: 0o600 }); chmodSync(TOKEN_FILE, 0o600)
  }
  const reach = await phoneAddress(PORT, opt('url'))
  if (!reach.url) fail(['No address the phone could use was found.', ...reach.notes, 'Or give one: t3bot pair --url https://your-address'].join('\n'))
  const link = pairingLink(reach.url!, token)
  if (has('link-only')) return say(link)
  say('Pair your iPhone with T3 Bot')
  say()
  say(`  Address  ${reach.url}`)
  say(`  Link     ${link}`)
  say()
  if (!has('no-qr')) { printQr(link); say() }
  say(has('no-qr') ? 'Open the link on the iPhone: T3 Bot opens, already connected.'
    : 'Scan the code with the iPhone camera (or open the link on the phone): T3 Bot opens, already connected.')
  say('The link holds your token. Whoever has it can talk to your bots, so do not post it anywhere.')
  for (const n of reach.notes) say(`\nNote: ${n}`)
  if (!(await probe(`${LOCAL}/health`)).ok && reach.how !== 'given' && reach.how !== 'saved') {
    say(`\nNote: the server is not running on this computer yet. Start it with deploy/install.sh (or \`bun server/t3bot.ts\`).`)
  }
}

async function demo() {
  const script = join(ROOT, 'server/demo.ts')
  if (!existsSync(script)) fail(`The demo server is missing (${tilde(script)}).`)
  const port = Number(opt('port')) || Number(process.env.T3BOT_DEMO_PORT) || 8810
  if ((await probe(`http://127.0.0.1:${port}/health`, undefined, 800)).ok) fail(`Something already answers on port ${port}. Pick another: t3bot demo --port ${port + 1}`)
  // This computer only unless --lan, --host or T3BOT_DEMO_HOST opens it: the demo's token is public.
  const host = opt('host') ?? (has('lan') ? '0.0.0.0' : process.env.T3BOT_DEMO_HOST || '127.0.0.1')
  const child = Bun.spawn([process.execPath, script, '--port', String(port), '--no-banner', ...(has('frozen') ? ['--frozen'] : []), '--host', host],
    { stdin: 'inherit', stdout: 'inherit', stderr: 'inherit' })
  const stop = () => { try { child.kill() } catch {} }
  process.on('SIGINT', stop); process.on('SIGTERM', stop)
  let up = false
  for (let i = 0; i < 40 && !up && child.exitCode === null; i++) { await Bun.sleep(250); up = (await probe(`http://127.0.0.1:${port}/health`, undefined, 500)).ok }
  if (!up) { stop(); fail(`The demo server did not start on port ${port}.`, 1) }
  // Listening on this computer only (the default): a phone cannot reach it, so no Wi-Fi address is offered.
  const local = /^(127\.|localhost$|::1$)/.test(host)
  const lan = local ? undefined : lanAddress()
  const url = (opt('url') ?? (lan ? `http://${lan}:${port}` : `http://127.0.0.1:${port}`)).replace(/\/+$/, '')
  const link = pairingLink(url, 'demo')
  say('T3 Bot demo: invented bots, nothing leaves this computer, nothing is saved.')
  say()
  say(`  Address  ${url}   (token: demo)`)
  say(`  Link     ${link}`)
  if (lan) say(`  In the iOS Simulator on this Mac: ${pairingLink(`http://127.0.0.1:${port}`, 'demo')}`)
  say()
  if (!has('no-qr')) { printQr(link); say() }
  say(lan ? `${has('no-qr') ? 'Open the link on' : 'Scan the code with'} an iPhone on the same Wi-Fi${has('no-qr') ? '' : ', or open the link on it'}. Stop with Ctrl C.`
    : `${local ? 'It listens on this computer only' : 'This computer has no network address'}, so the link only works on this Mac (the iOS Simulator). ${local ? 'For an iPhone on the same Wi-Fi, start it with --lan. ' : ''}Stop with Ctrl C.`)
  if (!local) say('It is open to your network over plain http with the public token "demo": use it on a network you trust.')
  process.exit(await child.exited)
}

async function setup() {
  const dry = has('dry-run'), force = has('force')
  const target = process.env.T3BOT_CONFIG ? configPath() : USER_CONFIG
  const inUse = configPath()
  const readConf = (p: string) => { try { return normalize(JSON.parse(readFileSync(p, 'utf8'))) } catch { return null } }
  const existing = existsSync(target) ? readConf(target) : null
  // deploy/install.sh asks with --if-needed: quiet when there is nothing to do.
  if (has('if-needed') && !force && ((existing?.agents.length ?? 0) > 0 || (existsSync(inUse) && (readConf(inUse)?.agents.length ?? 0) > 0))) return
  say(dry ? 'T3 Bot setup, dry run: nothing is written and nothing is sent to T3 Code.\n' : 'T3 Bot setup\n')

  // 1. A config that already has bots is never replaced by accident.
  if (existsSync(target) && !existing && !force) fail(`${tilde(target)} exists but is not valid JSON. Fix it, or add --force to replace it (a copy is kept).`)
  if (existing?.agents.length && !force) {
    say(`Already set up: ${tilde(target)} has ${existing.agents.length} bot${existing.agents.length === 1 ? '' : 's'}. Nothing to do.`)
    say('Add bots from the app. `t3bot pair` connects a phone, `t3bot doctor` checks everything.')
    say('To start over with a new Chief, add --force (the current file is kept as a copy beside it).')
    return
  }
  if (inUse !== target && existsSync(inUse) && (readConf(inUse)?.agents.length ?? 0) > 0 && !force) {
    say(`Already set up: the config in use is ${tilde(inUse)} (${readConf(inUse)!.agents.length} bots). Nothing to do.`)
    say(`A new config in ${tilde(target)} would take its place. If that is what you want, add --force.`)
    return
  }

  // 2. T3 Code.
  const st = t3.status()
  if (!st.dbFound) fail(`T3 Code was not found on this computer (no data at ${tilde(st.db)}).\nInstall T3 Code, open it once and create a project, then run \`t3bot setup\` again.\nIf it keeps its data somewhere else, set T3BOT_T3_HOME to that folder.`, 1)
  say(`T3 Code      found (${tilde(st.home)}${st.version ? `, version ${st.version}` : ''})`)
  if (st.problem) {
    if (!dry) fail(`\n${st.problem}`, 1)
    say(`             but: ${st.problem}`)
  } else say(`             running on port ${st.port}`)

  // 3. The project the bots live in.
  const projects = t3.listProjects()
  if (!projects.length) fail('\nT3 Code has no project yet. Create one in T3 Code (any folder works), then run `t3bot setup` again.', 1)
  const want = opt('project')
  let project = want
    ? projects.find((p) => p.id === want) ?? projects.find((p) => p.title.toLowerCase() === want.toLowerCase())
      ?? projects.find((p) => p.path === untilde(want).replace(/\/+$/, '')) ?? projects.find((p) => p.title.toLowerCase().includes(want.toLowerCase()))
    : projects.length === 1 ? projects[0] : undefined
  if (want && !project) fail(`\nNo T3 Code project matches "${want}". The projects:\n${projects.map((p) => `  ${p.title}  (${tilde(p.path)})`).join('\n')}`)
  if (!project) {
    say('\nWhich T3 Code project should your bots live in? Their threads are created there.')
    projects.forEach((p, i) => say(`  ${String(i + 1).padStart(2)}. ${p.title}  (${tilde(p.path)})`))
    if (!process.stdin.isTTY) fail(`\nPick one with --project "<name>", for example: t3bot setup --project "${projects[0].title}"`)
    for (;;) {
      const a = (prompt(`\nNumber (1 to ${projects.length}):`) ?? '').trim()
      if (!a) fail('Nothing chosen. Nothing was changed.')
      const n = Number(a)
      project = Number.isInteger(n) && n >= 1 && n <= projects.length ? projects[n - 1] : projects.find((p) => p.title.toLowerCase() === a.toLowerCase())
      if (project) break
      say('That is not one of them.')
    }
  }
  say(`Project      ${project!.title}  (${tilde(project!.path)})`)

  // 4. Who the bots work for.
  const fullName = sh(['id', '-F']).out.trim()
  const name = (opt('name') ?? existing?.user?.name ?? fullName.split(/\s+/)[0] ?? '').trim().slice(0, 40)
  say(`Your name    ${name || '(none: bots will say "the user")'}${opt('name') ? '' : '   (change it with --name)'}`)

  // 5. The token the phone and the `t3bot` command use.
  const tokenThere = !!readTrim(TOKEN_FILE)
  say(`Token        ${tokenThere ? `already in ${tilde(TOKEN_FILE)}` : `${dry ? 'would be' : 'is'} created in ${tilde(TOKEN_FILE)} (only you can read it)`}`)
  if (!tokenThere && !dry) {
    mkdirSync(dirname(TOKEN_FILE), { recursive: true, mode: 0o700 })
    writeFileSync(TOKEN_FILE, newToken() + '\n', { mode: 0o600 })
    chmodSync(TOKEN_FILE, 0o600)
  }

  // 6. The first bot.
  const who = name || 'the user'
  const notes = join(dirname(target), 'bots', 'chief.md')
  const first = `You are Chief, the first contact in T3 Bot, ${who}'s agent app on the iPhone. ` +
    `Read ${tilde(rulesPath('CHIEF.md'))} and ${tilde(rulesPath('BOTS.md'))} now and follow them for this whole thread. ` +
    `Keep what you must remember in ${tilde(notes)} so it survives compaction, and read these three files again after any compaction. ` +
    `Then reply with one line saying you are ready.`
  const base0: any = existing && !existing.agents.length ? existing : {}
  const defaults = threadDefaults(normalize({ defaults: base0.defaults }))
  const conf = (threadId: string) => ({
    ...base0,
    user: name ? { name } : base0.user,
    chief: 'chief',
    environmentId: t3.environmentId(),
    projectId: project!.id,
    night: base0.night ?? { from: '23:00', to: '08:00' },
    digestAt: base0.digestAt ?? '20:00',
    // A new install keeps six months of history. A config that already had bots keeps what it said, and one
    // that said nothing goes on keeping everything.
    keepDays: base0.keepDays ?? (existing?.agents.length ? existing.keepDays : 180),
    agents: [{ id: 'chief', name: 'Chief', role: 'First contact. Takes everything no other bot owns.', threadId, watch: [], kind: 'bot', hidden: false, face: { skin: '902' } }],
    sources: base0.sources ?? [],
    handlers: base0.handlers ?? {},
  })
  if (dry) {
    say(`\nIt would create one thread in "${project!.title}", titled "%BOT Chief" (${defaults.model}, effort ${defaults.effort}, ${defaults.runtimeMode}), with this first message:\n`)
    say(`  ${first}\n`)
    say(`It would then write ${tilde(target)}${existsSync(target) ? ' (keeping a copy of the current file)' : ''}:\n`)
    say(JSON.stringify(conf('<the new thread>'), null, 2).replace(/^/gm, '  '))
    say('\nDry run: nothing was written, nothing was sent to T3 Code.')
    return
  }
  say('\nCreating the Chief in T3 Code...')
  const made = await t3.createThread(project!.id, '%BOT Chief', first, defaults)
  if (!made.threadId) fail(`T3 Code refused the new thread: ${made.error ?? 'no reason given'}. Nothing was written.`, 1)
  if (!made.ok) say(`The thread exists, but its first message did not go through (${made.error}). Say hello to Chief from the app once you are paired.`)
  mkdirSync(dirname(target), { recursive: true, ...(dirname(target) === CONFIG_DIR ? { mode: 0o700 } : {}) })
  if (existsSync(target)) {
    const copy = `${target}.before-setup-${new Date().toISOString().replace(/[:.]/g, '-')}`
    copyFileSync(target, copy)
    say(`The previous config is kept as ${tilde(copy)}.`)
  }
  writeFileSync(`${target}.tmp`, JSON.stringify(conf(made.threadId!), null, 2) + '\n')
  renameSync(`${target}.tmp`, target)
  try { mkdirSync(dirname(notes), { recursive: true }) } catch {}
  say(`Config       written to ${tilde(target)}`)
  say('\nDone. Next:')
  const serverUp = (await probe(`${LOCAL}/health`)).ok
  if (!serverUp) say('  1. Start the server and keep it running:  deploy/install.sh')
  say(`  ${serverUp ? 1 : 2}. Connect your iPhone:                      t3bot pair`)
  say(`  ${serverUp ? 2 : 3}. Check everything:                         t3bot doctor`)
}

async function doctor() {
  let bad = 0, warned = 0
  const ok = (what: string, m: string) => say(`  ok    ${what.padEnd(11)} ${m}`)
  const warn = (what: string, m: string) => { warned++; say(`  note  ${what.padEnd(11)} ${m}`) }
  const no = (what: string, m: string) => { bad++; say(`  FAIL  ${what.padEnd(11)} ${m}`) }
  say(`T3 Bot ${VERSION} doctor\n`)

  ok('bun', Bun.version)

  // T3 Code
  const st = t3.status()
  if (!st.dbFound) no('T3 Code', `not found (no data at ${tilde(st.db)}). Install it and open it once. If it keeps its data elsewhere, set T3BOT_T3_HOME to that folder.`)
  else if (st.problem) no('T3 Code', st.problem)
  else ok('T3 Code', `running, version ${st.version ?? '?'}, port ${st.port}, ${t3.listProjects().length} projects`)
  if (st.dbFound && st.readError) warn('T3 Code', `its data could not be read just now: ${st.readError}`)

  // Config
  const path = configPath()
  let conf: ReturnType<typeof normalize> | null = null
  if (!existsSync(path)) no('config', `none yet (${tilde(path)}). Run \`t3bot setup\`.`)
  else {
    try { conf = normalize(JSON.parse(readFileSync(path, 'utf8'))) } catch (e) { no('config', `${tilde(path)} is not valid JSON: ${String((e as any)?.message ?? e).slice(0, 100)}`) }
  }
  if (conf) {
    const chief = chiefId(conf)
    if (!conf.agents.length) no('config', `${tilde(path)} has no bots. Run \`t3bot setup\`.`)
    else ok('config', `${tilde(path)}: ${conf.agents.length} bot${conf.agents.length === 1 ? '' : 's'}, chief "${chief}", user "${userName(conf)}"`)
    if (conf.agents.length && !conf.projectId) warn('config', 'no "projectId": new bots cannot be created from the app until `t3bot setup` or you add one.')
    if (st.dbFound && conf.agents.length) {
      try {
        const found = t3.threadsByIds(conf.agents.map((a) => a.threadId).filter(Boolean))
        const missing = conf.agents.filter((a) => !a.threadId || !found.has(a.threadId))
        if (missing.length) warn('bots', `no thread in T3 Code for: ${missing.map((a) => a.name).join(', ')} (deleted or archived there?)`)
        else ok('bots', 'every bot has its thread in T3 Code')
      } catch {}
    }
    const rules = (['BOTS.md', 'CHIEF.md', 'GROUP.md'] as const).map((n) => rulesPath(n))
    const gone = rules.filter((r) => !existsSync(r))
    if (gone.length) no('rules', `missing: ${gone.map(tilde).join(', ')}`)
    else ok('rules', [...new Set(rules.map((r) => tilde(dirname(r))))].join(', '))
  }

  // Token (never printed)
  if (process.env.T3BOT_TOKEN) ok('token', 'from $T3BOT_TOKEN')
  else if (!existsSync(TOKEN_FILE)) no('token', `none in ${tilde(TOKEN_FILE)}. The server makes one on its first start (deploy/install.sh).`)
  else {
    const mode = statSync(TOKEN_FILE).mode & 0o777
    if (!readTrim(TOKEN_FILE)) no('token', `${tilde(TOKEN_FILE)} is empty. Delete it and restart the server.`)
    else if (mode & 0o077) warn('token', `${tilde(TOKEN_FILE)} can be read by other accounts on this computer. Fix: chmod 600 ${tilde(TOKEN_FILE)}`)
    else ok('token', `${tilde(TOKEN_FILE)} (only you can read it)`)
  }

  // Server
  const token = readToken()
  const health = await probe(`${base}/health`)
  let serverPush: boolean | null = null
  if (!health.ok) no('server', `nothing answers at ${base}. Start it: deploy/install.sh (or \`bun server/t3bot.ts\`).`)
  else if (!token) warn('server', `answers at ${base}, but without a token nothing more can be checked.`)
  else {
    const hello = await probe(`${base}/v1/hello`, token, 8000)
    if (hello.status === 401) no('server', `answers at ${base} but refuses this token. Is another T3 Bot server running there, or is the token file newer than the server? Restart it.`)
    else if (!hello.ok) no('server', `answers at ${base} but /v1/hello failed (${hello.status}). An older server? Restart it from this folder.`)
    else {
      serverPush = !!hello.data.push
      ok('server', `${base}, version ${hello.data.version}${hello.data.demo ? ' (demo)' : ''}, ${hello.data.bots ?? '?'} bots${hello.data.t3?.ok === false ? `; it says: ${hello.data.t3.error}` : ''}`)
    }
  }
  const agentsDir = join(HOME, 'Library/LaunchAgents')
  if (process.platform === 'darwin' && base === LOCAL) {
    let plist = '', elsewhere = ''
    try {
      for (const f of readdirSync(agentsDir).filter((f) => f.endsWith('.plist'))) {
        const text = readTrim(join(agentsDir, f))
        if (text.includes(join(ROOT, 'server/t3bot.ts'))) plist = f
        else if (text.includes('server/t3bot.ts')) elsewhere = f
      }
    } catch {}
    if (plist) ok('at login', `LaunchAgent ${plist.replace(/\.plist$/, '')} starts the server and restarts it if it stops`)
    else if (elsewhere) warn('at login', `LaunchAgent ${elsewhere.replace(/\.plist$/, '')} starts a T3 Bot server from another folder, not this one.`)
    else warn('at login', 'no LaunchAgent: the server will not start by itself after a restart. deploy/install.sh adds one.')
  }

  // The address for the phone
  const reach = base === LOCAL ? await phoneAddress(PORT) : { url: base, how: 'saved' as const, notes: [] as string[] }
  if (!reach.url) no('phone', 'no address the phone could use. ' + reach.notes.join(' '))
  else if (reach.how === 'tailscale') ok('phone', `${reach.url} (Tailscale, HTTPS, works away from home)`)
  else if (reach.how === 'lan') { warn('phone', `${reach.url} (home network only, plain http)`); for (const n of reach.notes) say(`${' '.repeat(20)}${n}`) }
  else ok('phone', `${reach.url}`)

  // Push
  const apns = apnsStatus()
  if (apns.conf) {
    ok('push', `key found, topic ${apns.conf.topic}${serverPush === false ? ' (but the server runs with pushes off)' : ''}`)
  } else if (apns.problem) no('push', `${apns.problem} (${tilde(APNS_FILE)})`)
  else {
    warn('push', 'no push key, so the phone does not ring: the app still shows everything when you open it.')
    for (const l of [
      'To make it ring, with an Apple Developer account:',
      '1. developer.apple.com > Certificates, IDs & Profiles > Keys: create a key with Apple Push Notifications',
      `   service, download the .p8 file once and move it into ${tilde(CONFIG_DIR)} (chmod 600).`,
      `2. Write ${tilde(APNS_FILE)}:`,
      `   { "keyId": "<the key's id>", "teamId": "<your team id>", "keyPath": "${tilde(join(CONFIG_DIR, 'AuthKey_XXXXXXXXXX.p8'))}",`,
      '     "topic": "<the bundle id you built the app with>" }',
      'The server picks it up at the next push; no restart needed.',
    ]) say(`${' '.repeat(20)}${l}`)
  }

  say()
  if (bad) say(`${bad} thing${bad === 1 ? '' : 's'} to fix${warned ? `, ${warned} to know about` : ''}.`)
  else say(warned ? `Working. ${warned} thing${warned === 1 ? '' : 's'} to know about, above.` : 'Everything is in place.')
  if (!bad && base === LOCAL) say('Connect a phone with `t3bot pair`.')
  process.exit(bad ? 1 : 0)
}

function help() {
  say(readFileSync(import.meta.path, 'utf8').split('*/')[0].replace(/^\/\*\*\n/, '').replace(/^ \* ?/gm, '').trimEnd())
  if (PORT !== DEFAULT_PORT) say(`\n(T3BOT_PORT is ${PORT}.)`)
}

switch (cmd) {
  case 'notify': await notify(); break
  case 'draft': await draft(); break
  case 'phone': await phone(); break
  case 'needs': await needs(); break
  case 'roster': await roster(); break
  case 'home': say(JSON.stringify(await getJson('/v1/home'), null, 1)); break
  case 'agent': {
    const id = args.find((a) => !a.startsWith('--'))
    if (!id) fail('t3bot agent <id>   (ids in `t3bot roster`)')
    say(JSON.stringify(await getJson(`/v1/agents/${encodeURIComponent(id!)}`), null, 1)); break
  }
  case 'setup': await setup(); break
  case 'pair': await pair(); break
  case 'doctor': await doctor(); break
  case 'demo': await demo(); break
  case 'connect': connect(); break
  case 'version': case '--version': case '-v': say(VERSION); break
  case undefined: case 'help': case '--help': case '-h': help(); break
  default: console.error(`t3bot: no command "${cmd}".\n`); help(); process.exit(2)
}
