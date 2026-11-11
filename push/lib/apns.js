// The push sender's core, shared by the routes and the tests. Node only (crypto, http2), no packages, no storage.
import crypto from 'node:crypto'
import http2 from 'node:http2'

const b64u = (b) => Buffer.from(b).toString('base64url')
const env = (name) => (process.env[name] || '').trim()

// ---------- settings (environment variables) ----------

function sealKey() {
  const k = Buffer.from(env('SEAL_KEY'), 'base64')
  if (k.length !== 32) throw new Error('SEAL_KEY must be 32 bytes, base64')
  return k
}

let parsed = { pem: '', key: null }
/** The .p8 key as a key object. Its text is never put in an error or a log: a bad key only says "APNS_KEY". */
function apnsKey() {
  let pem = env('APNS_KEY').replace(/\\n/g, '\n')
  if (parsed.key && parsed.pem === pem) return parsed.key
  let text = pem
  if (text && !text.includes('BEGIN')) text = `-----BEGIN PRIVATE KEY-----\n${text.replace(/\s+/g, '\n')}\n-----END PRIVATE KEY-----`
  let key
  try { key = crypto.createPrivateKey(text) } catch { throw new Error('APNS_KEY is not a .p8 key') }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('APNS_KEY is not a .p8 key')
  parsed = { pem, key }
  return key
}

export const allowedTopics = () => env('ALLOWED_TOPICS').split(',').map((s) => s.trim()).filter(Boolean)

/** The names of the settings that are missing or malformed (never their values). Empty when the sender is ready. */
export function missing() {
  const out = []
  try { sealKey() } catch { out.push('SEAL_KEY') }
  try { apnsKey() } catch { out.push('APNS_KEY') }
  if (!/^[A-Z0-9]{10}$/.test(env('APNS_KEY_ID'))) out.push('APNS_KEY_ID')
  if (!/^[A-Z0-9]{10}$/.test(env('APNS_TEAM_ID'))) out.push('APNS_TEAM_ID')
  if (!allowedTopics().length) out.push('ALLOWED_TOPICS')
  return out
}

// ---------- sealed addresses: the phone's push token, readable only by this sender ----------

const TOKEN = /^(?:[0-9a-f]{2}){32,100}$/
const TOPIC = /^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$/
const ENVS = ['sandbox', 'production']
/** The app drops an address longer than this from its hook (HookSettings.isSafe), so none is ever handed out. */
export const ADDRESS_MAX = 300
const today = (ms = Date.now()) => Math.floor(ms / 86_400_000)

export const validToken = (t) => typeof t === 'string' && TOKEN.test(t)
export const validTopic = (b) => typeof b === 'string' && TOPIC.test(b)
export const validEnv = (e) => ENVS.includes(e)

/** {t: device token hex, e: 'sandbox'|'production', b: bundle id} -> an opaque address (base64url). */
export function seal(obj, nowMs = Date.now()) {
  const iv = crypto.randomBytes(12)
  const c = crypto.createCipheriv('aes-256-gcm', sealKey(), iv)
  // i: the day it was made, so a sender can refuse old addresses (ADDRESS_MAX_AGE_DAYS).
  const body = Buffer.concat([c.update(JSON.stringify({ ...obj, v: 1, i: today(nowMs) })), c.final()])
  return b64u(Buffer.concat([iv, body, c.getAuthTag()]))
}

/** Opens an address this sender made. Throws for anything else: another key, a changed byte, a wrong shape. */
export function unseal(address) {
  if (typeof address !== 'string' || address.length > 400 || !/^[A-Za-z0-9_-]+$/.test(address)) throw new Error('bad address')
  const raw = Buffer.from(address, 'base64url')
  if (raw.length < 12 + 16 + 2) throw new Error('bad address')
  const iv = raw.subarray(0, 12), tag = raw.subarray(raw.length - 16), body = raw.subarray(12, raw.length - 16)
  const d = crypto.createDecipheriv('aes-256-gcm', sealKey(), iv)
  d.setAuthTag(tag)
  const o = JSON.parse(Buffer.concat([d.update(body), d.final()]).toString('utf8'))
  if (!o || o.v !== 1 || !validToken(o.t) || !validEnv(o.e) || !validTopic(o.b)) throw new Error('bad address')
  return o
}

/** True when ADDRESS_MAX_AGE_DAYS is set and the address is older (one made before addresses carried a day counts as old). */
export function expired(o, nowMs = Date.now()) {
  const days = Number(env('ADDRESS_MAX_AGE_DAYS'))
  if (!(days > 0)) return false
  return !Number.isInteger(o.i) || today(nowMs) - o.i > days
}

// ---------- APNs ----------

// Apple refuses a token older than 60 minutes and one that changes more often than every 20. Instances share
// nothing, so each rounds the token's time down to the same half hour: every instance signs the same claims, they
// change once per 30 minutes, and a token is never more than 30 minutes old when it is used.
const JWT_WINDOW = 30 * 60
let jwt = { token: '', iat: 0, id: '', key: null, exact: false }

/** The provider token, signed at most once per half hour per instance. `exact` signs one dated now (after Apple
 *  called the rounded one expired, which only a wrong clock explains); it is then kept for its half hour. */
export function bearer(nowSec = Math.floor(Date.now() / 1000), exact = false) {
  const iat = exact ? nowSec : Math.floor(nowSec / JWT_WINDOW) * JWT_WINDOW
  const key = apnsKey()
  const id = `${env('APNS_KEY_ID')}.${env('APNS_TEAM_ID')}`
  const fresh = jwt.exact ? nowSec >= jwt.iat && nowSec - jwt.iat < JWT_WINDOW : jwt.iat === iat
  if (!exact && jwt.token && jwt.key === key && jwt.id === id && fresh) return jwt.token
  const head = b64u(JSON.stringify({ alg: 'ES256', kid: env('APNS_KEY_ID') }))
  const claims = b64u(JSON.stringify({ iss: env('APNS_TEAM_ID'), iat }))
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${claims}`), { key, dsaEncoding: 'ieee-p1363' })
  jwt = { token: `${head}.${claims}.${b64u(sig)}`, iat, id, key, exact }
  return jwt.token
}

const HOSTS = { production: 'https://api.push.apple.com', sandbox: 'https://api.sandbox.push.apple.com' }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** One request on its own connection. Resolves {status, reason, connected}; status 0 when no answer came. */
function attempt({ origin, headers, data, timeoutMs }) {
  return new Promise((resolve) => {
    let done = false, connected = false, status = 0, text = ''
    let client
    const finish = (r) => {
      if (done) return
      done = true
      clearTimeout(timer)
      try { r.status ? client.close() : client.destroy() } catch {}
      resolve({ ...r, connected })
    }
    const timer = setTimeout(() => finish({ status: 0, reason: 'timeout' }), timeoutMs)
    try {
      client = http2.connect(origin)
      client.on('connect', () => { connected = true })
      client.on('error', () => finish({ status: 0, reason: 'unreachable' }))
      const req = client.request(headers)
      req.setEncoding('utf8')
      req.on('response', (h) => { status = Number(h[':status']) || 0 })
      req.on('data', (c) => { if (text.length < 2048) text += c })
      req.on('end', () => {
        let reason = ''
        try { reason = String(JSON.parse(text).reason || '') } catch {}
        finish({ status, reason: /^[A-Za-z]{1,60}$/.test(reason) ? reason : '' })
      })
      req.on('error', () => finish({ status: 0, reason: 'unreachable' }))
      req.on('close', () => finish({ status, reason: status ? '' : 'unreachable' }))
      req.end(data)
    } catch { finish({ status: 0, reason: 'unreachable' }) }
  })
}

/**
 * One push. Resolves {status, reason}; never throws for an APNs refusal or a network failure.
 * A second try is made only when the first cannot have rung the phone: the connection was never made, Apple
 * answered 503, or Apple said the sender's token had expired. A timeout is not tried again.
 * The whole call stays under `budgetMs`, because the hook's curl gives up after 6 seconds.
 */
export async function send({ token, env: where, topic, payload, collapseId, pushType = 'alert', priority = 10, budgetMs = 4500, origin }) {
  const deadline = Date.now() + budgetMs
  const data = JSON.stringify(payload)
  const once = (auth) => {
    const headers = { ':method': 'POST', ':path': `/3/device/${token}`, authorization: `bearer ${auth}`, 'apns-topic': topic,
      'apns-push-type': pushType, 'apns-priority': String(priority), 'content-type': 'application/json' }
    if (collapseId) headers['apns-collapse-id'] = collapseId
    return attempt({ origin: origin || HOSTS[where === 'production' ? 'production' : 'sandbox'], headers, data, timeoutMs: Math.max(200, Math.min(3500, deadline - Date.now())) })
  }
  let r = await once(bearer())
  const left = () => deadline - Date.now()
  if (r.status === 403 && r.reason === 'ExpiredProviderToken' && left() > 500) {
    r = await once(bearer(Math.floor(Date.now() / 1000), true))
  } else if (((r.status === 0 && !r.connected && r.reason !== 'timeout') || r.status === 503) && left() > 700) {
    await sleep(150)
    r = await once(bearer())
  }
  return { status: r.status, reason: r.reason }
}

/** Seam for the tests: the routes send through this, so a test can answer in Apple's place. */
export const apns = { send }

/** What a ring becomes: a generic alert the phone's notification extension fills in from T3 Code. */
export function ringPayload(kind, thread) {
  const asks = kind === 'request'
  return {
    aps: {
      alert: { title: 'T3 Bot', body: kind === 'test' ? 'Push works on this phone.' : asks ? 'A bot needs you' : 'A bot answered' },
      sound: 'default',
      'mutable-content': 1,
      'thread-id': String(thread || 't3bot').slice(0, 64),
      category: asks ? 'T3REQUEST' : 'REPLY',
      'interruption-level': asks ? 'time-sensitive' : 'active',
      // Wakes the app too, when it is in memory, so a Live Activity can end with the reply.
      'content-available': 1,
    },
    t3: { thread: String(thread || ''), kind },
  }
}

// ---------- a guard against floods ----------
// Counted in memory, so per warm instance: it slows a flood on one instance and is no hard limit across several.
// A hard limit needs something shared (the host's firewall rate limit; see the README).

const seen = new Map()
export function tooMany(key, limit = 30, windowMs = 60_000, now = Date.now()) {
  let w = seen.get(key)
  if (!w || now - w.start >= windowMs) {
    if (seen.size >= 5000) for (const [k, v] of seen) if (now - v.start >= windowMs) seen.delete(k)
    if (seen.size >= 5000) seen.clear()
    w = { start: now, n: 0 }
    seen.set(key, w)
  }
  w.n += 1
  return w.n > limit
}

// ---------- requests ----------

export const BODY_MAX = 2048
const fail = (status, code, error) => ({ status, code, error })

/** The JSON object of a request, or {status, code, error}. Works with Vercel's parsed `req.body` and with a bare stream. */
export async function readJson(req, max = BODY_MAX) {
  if (!/^application\/json\s*(;|$)/i.test(String(req.headers?.['content-type'] || ''))) return fail(415, 'content_type', 'send JSON with content-type: application/json')
  if (Number(req.headers?.['content-length']) > max) return fail(413, 'too_large', `the body is over ${max} bytes`)
  let b
  try { b = req.body } catch { return fail(400, 'bad_json', 'the body is not JSON') }
  if (b === undefined && typeof req[Symbol.asyncIterator] === 'function') {
    const chunks = []
    let size = 0
    for await (const c of req) {
      size += c.length
      if (size > max) return fail(413, 'too_large', `the body is over ${max} bytes`)
      chunks.push(c)
    }
    b = Buffer.concat(chunks)
  }
  if (Buffer.isBuffer(b)) b = b.toString('utf8')
  if (typeof b === 'string') {
    if (b.length > max) return fail(413, 'too_large', `the body is over ${max} bytes`)
    try { b = JSON.parse(b) } catch { return fail(400, 'bad_json', 'the body is not JSON') }
  }
  if (!b || typeof b !== 'object' || Array.isArray(b)) return fail(400, 'bad_json', 'the body is not a JSON object')
  if (JSON.stringify(b).length > max) return fail(413, 'too_large', `the body is over ${max} bytes`)
  return { value: b }
}

export function reply(res, status, obj) {
  res.setHeader('cache-control', 'no-store')
  return res.status(status).json(obj)
}

const caller = (req) => String(req.headers?.['x-forwarded-for'] || req.headers?.['x-real-ip'] || '').split(',')[0].trim().slice(0, 64)

/**
 * A POST route: method, caller limit, settings, body, then `fn(body, req, res)`. Anything thrown becomes a plain
 * 500: the reason is never sent back, and only its kind is logged.
 */
export function post(name, perMinute, fn) {
  return async function handler(req, res) {
    try {
      if (req.method !== 'POST') { res.setHeader('allow', 'POST'); return reply(res, 405, { ok: false, code: 'method', error: 'POST only' }) }
      if (tooMany(`${name}:${caller(req)}`, perMinute)) { res.setHeader('retry-after', '60'); return reply(res, 429, { ok: false, code: 'too_many', error: 'too many requests' }) }
      const lacks = missing()
      if (lacks.length) return reply(res, 503, { ok: false, code: 'not_configured', error: `this sender is not set up: ${lacks.join(', ')}` })
      const b = await readJson(req)
      if (!b.value) return reply(res, b.status, { ok: false, code: b.code, error: b.error })
      return await fn(b.value, req, res)
    } catch (e) {
      console.error(`push ${name}: failed (${String(e?.code || e?.name || 'error').slice(0, 40)})`)
      return reply(res, 500, { ok: false, code: 'internal', error: 'the sender failed' })
    }
  }
}
