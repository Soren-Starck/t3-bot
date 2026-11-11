/**
 * Apple push for the T3 Bot app: token-based APNs (one .p8 key), sent with curl because APNs needs HTTP/2.
 * Push is optional. Without <config dir>/apns.json pushes are logged and skipped; the app still works when opened.
 *   apns.json: { "keyId": "ABC123DEFG", "teamId": "YOUR_TEAM_ID", "keyPath": "~/.config/t3bot/AuthKey_ABC123DEFG.p8", "topic": "<the app's bundle id>" }
 * `t3bot doctor` says whether the key is found and how to add one.
 */
import { existsSync, readFileSync } from 'fs'
import { APNS_FILE, untilde } from './config'

export type Conf = { keyId: string; teamId: string; keyPath: string; topic: string }
export type Env = 'sandbox' | 'production'
type Log = (m: string, x?: unknown) => void
let jwt: { token: string; at: number; key: string } | null = null

/** The push settings, or why there are none. Never throws. */
export function apnsStatus(): { conf: Conf | null; problem: string | null } {
  if (!existsSync(APNS_FILE)) return { conf: null, problem: null }
  try {
    const c = JSON.parse(readFileSync(APNS_FILE, 'utf8'))
    for (const k of ['keyId', 'teamId', 'keyPath', 'topic']) {
      if (typeof c?.[k] !== 'string' || !c[k].trim()) return { conf: null, problem: `apns.json has no "${k}"` }
    }
    const keyPath = untilde(c.keyPath.trim())
    if (!existsSync(keyPath)) return { conf: null, problem: 'apns.json points at a key file that does not exist' }
    return { conf: { keyId: c.keyId.trim(), teamId: c.teamId.trim(), keyPath, topic: c.topic.trim() }, problem: null }
  } catch {
    return { conf: null, problem: 'apns.json is not valid JSON' }
  }
}

const b64url = (b: ArrayBuffer | Uint8Array | string) =>
  Buffer.from(typeof b === 'string' ? b : new Uint8Array(b as ArrayBuffer)).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')

/** The provider token APNs asks for: a JWT signed with the .p8 key (exported for the checks, which sign with a throwaway key). */
export async function token(c: Conf): Promise<string> {
  // APNs accepts a token for up to an hour and refuses one refreshed more often than every 20 minutes.
  const key = `${c.teamId}:${c.keyId}:${c.keyPath}`
  if (jwt && jwt.key === key && Date.now() - jwt.at < 40 * 60e3) return jwt.token
  const pem = readFileSync(c.keyPath, 'utf8').replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  const imported = await crypto.subtle.importKey('pkcs8', Buffer.from(pem, 'base64'), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: c.keyId }))
  const body = b64url(JSON.stringify({ iss: c.teamId, iat: Math.floor(Date.now() / 1000) }))
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, imported, new TextEncoder().encode(`${head}.${body}`))
  jwt = { token: `${head}.${body}.${b64url(sig)}`, at: Date.now(), key }
  return jwt.token
}

/** The settings and a signed token, or null (logged once per reason) when push cannot be sent. */
let lastProblem = ''
async function ready(log: Log): Promise<{ c: Conf; jwtToken: string } | null> {
  const { conf: c, problem } = apnsStatus()
  const complain = (m: string) => { if (m !== lastProblem) { lastProblem = m; log(`push off: ${m}`) } }
  if (!c) { if (problem) complain(problem); return null }
  try {
    const jwtToken = await token(c)
    lastProblem = ''
    return { c, jwtToken }
  } catch (e) {
    complain(`the APNs key could not be used (${String(e).slice(0, 120)})`)
    return null
  }
}

const hostFor = (env: Env) => (env === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com')

/**
 * What curl is told on its standard input (`--config -`): the address, the headers and the payload. The provider
 * token is one of the headers, and anything on a command line can be read by every process on the computer
 * (`ps`), so none of it goes there: the command line only says "read your options from stdin".
 * A config value is a quoted string where a backslash and a double quote are escaped; JSON has no raw line break.
 */
const quoted = (s: string) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r/g, '\\r').replace(/\n/g, '\\n').replace(/\t/g, '\\t')}"`
export const CURL_ARGS = ['curl', '-sS', '--http2', '--max-time', '20', '-o', '-', '-w', '\n%{http_code}', '--config', '-']
export function curlConfig(url: string, headers: string[], payload: string): string {
  return [`url = ${quoted(url)}`, 'request = "POST"', ...headers.map((h) => `header = ${quoted(h)}`), `data-binary = ${quoted(payload)}`, ''].join('\n')
}

/**
 * One POST to APNs (`origin` is https://<the APNs host>; the checks pass a local address). Answers with the HTTP
 * code ('0' when curl itself failed) and the response body.
 */
export async function post(origin: string, deviceToken: string, headers: string[], payload: string): Promise<{ code: string; body: string }> {
  try {
    // A header with a line break would start a second one: such a request is not sent at all.
    if (headers.some((h) => /[\r\n]/.test(h)) || /[^0-9a-zA-Z]/.test(deviceToken)) return { code: '0', body: 'not sent: a header or the device token is not well formed' }
    const p = Bun.spawn(CURL_ARGS, { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' })
    p.stdin.write(curlConfig(`${origin}/3/device/${deviceToken}`, headers, payload)); p.stdin.end()
    const [out, err] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited])
    const lines = out.trim().split('\n')
    const code = lines.pop() || '0'
    return { code, body: (lines.join(' ') || err).trim().slice(0, 300) }
  } catch (e) {
    return { code: '0', body: String(e).slice(0, 200) }
  }
}

export type Alert = {
  title: string; body: string; category?: string; threadId?: string
  timeSensitive?: boolean; badge?: number; data?: Record<string, unknown>; collapseId?: string
}

export type Device = { token: string; env: Env }

/** Sends to every device; returns the tokens APNs says are gone so the caller can forget them. Never throws. */
export async function push(devices: Device[], a: Alert, log: Log): Promise<string[]> {
  if (!devices.length) return []
  const r = await ready(log)
  if (!r) { log('push skipped: no APNs key', { title: a.title }); return [] }
  const payload = JSON.stringify({
    aps: {
      alert: { title: a.title, body: a.body },
      sound: 'default',
      ...(a.category ? { category: a.category } : {}),
      ...(a.threadId ? { 'thread-id': a.threadId } : {}),
      ...(a.badge !== undefined ? { badge: a.badge } : {}),
      'interruption-level': a.timeSensitive ? 'time-sensitive' : 'active',
      'mutable-content': 1,
    },
    t3bot: a.data ?? {},
  })
  const gone: string[] = []
  for (const d of devices) {
    const { code, body } = await post(hostFor(d.env), d.token, [
      `authorization: bearer ${r.jwtToken}`, `apns-topic: ${r.c.topic}`, 'apns-push-type: alert', 'apns-priority: 10',
      ...(a.collapseId ? [`apns-collapse-id: ${a.collapseId.slice(0, 64)}`] : []),
    ], payload)
    if (code !== '200') {
      log('push failed', { code, body, env: d.env })
      if (code === '410') gone.push(d.token)
    }
  }
  return gone
}

/**
 * Updates or ends a Live Activity (ActivityKit push). `state` is the activity's ContentState and `env` the APNs
 * environment of the build that started it (a TestFlight or App Store build is production, an Xcode build sandbox).
 * When APNs says the token does not belong to that environment the other one is tried, and the answer names the
 * one that worked so the caller can remember it. `gone` means the activity no longer exists. Never throws.
 */
export async function pushLive(activityToken: string, state: Record<string, unknown>, end: boolean, log: Log, env: Env = 'sandbox'): Promise<{ ok: boolean; env: Env; gone?: boolean }> {
  const r = await ready(log)
  if (!r) return { ok: false, env }
  const now = Math.floor(Date.now() / 1000)
  const payload = JSON.stringify({ aps: { timestamp: now, event: end ? 'end' : 'update', 'content-state': state, ...(end ? { 'dismissal-date': now + 240 } : {}) } })
  const headers = [
    `authorization: bearer ${r.jwtToken}`, `apns-topic: ${r.c.topic}.push-type.liveactivity`, 'apns-push-type: liveactivity',
    // Updates go at low priority (Apple budgets the urgent ones); the end of the activity goes at once.
    `apns-priority: ${end ? 10 : 5}`,
  ]
  let res = await post(hostFor(env), activityToken, headers, payload)
  if (res.code === '400' && res.body.includes('BadDeviceToken')) {
    const other: Env = env === 'production' ? 'sandbox' : 'production'
    const second = await post(hostFor(other), activityToken, headers, payload)
    if (second.code === '200') return { ok: true, env: other }
    res = second.code === '410' ? second : res
  }
  if (res.code !== '200') log('live push failed', { code: res.code, body: res.body.slice(0, 200), env })
  return { ok: res.code === '200', env, gone: res.code === '410' }
}
