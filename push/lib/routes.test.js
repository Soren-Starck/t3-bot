// The three routes, called the way Vercel calls them, with a stand-in for Apple. No network.
import { test, expect, beforeEach } from 'bun:test'
import crypto from 'node:crypto'

const pair = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
process.env.SEAL_KEY = crypto.randomBytes(32).toString('base64')
process.env.ALLOWED_TOPICS = 'com.example.t3bot, com.example.other'
process.env.APNS_KEY = pair.privateKey.export({ type: 'pkcs8', format: 'pem' })
process.env.APNS_KEY_ID = 'ABCDE12345'
process.env.APNS_TEAM_ID = 'TEAM123456'
delete process.env.ADDRESS_MAX_AGE_DAYS
const { apns, seal, unseal } = await import('./apns.js')
const address = (await import('../api/address.js')).default
const ring = (await import('../api/ring.js')).default
const health = (await import('../api/health.js')).default

const hex = () => crypto.randomBytes(32).toString('hex')
let ip = 0
/** One call from a caller of its own (so the per-caller limit of one test does not reach the next). */
async function call(handler, body, { method = 'POST', headers = { 'content-type': 'application/json' }, from } = {}) {
  const res = { code: 0, body: null, headers: {}, setHeader(k, v) { this.headers[k.toLowerCase()] = v }, status(c) { this.code = c; return this }, json(o) { this.body = o; return this } }
  await handler({ method, headers: { 'x-forwarded-for': from || `10.0.${(ip >> 8) & 255}.${ip++ & 255}`, ...headers }, body, url: '/api/x' }, res)
  return { status: res.code, body: res.body, headers: res.headers }
}
async function withEnv(values, fn) {
  const old = Object.fromEntries(Object.keys(values).map((k) => [k, process.env[k]]))
  for (const [k, v] of Object.entries(values)) v === undefined ? delete process.env[k] : (process.env[k] = v)
  try { return await fn() } finally { for (const [k, v] of Object.entries(old)) v === undefined ? delete process.env[k] : (process.env[k] = v) }
}

let sent
let answer
beforeEach(() => {
  sent = []
  answer = () => ({ status: 200, reason: '' })
  apns.send = async (p) => { sent.push(p); return answer(p, sent.length) }
})
const addressFor = (t = hex(), e = 'sandbox', b = 'com.example.t3bot') => seal({ t, e, b })

// ---------- /api/address ----------

test('address: what the app sends today gets an address only this sender can open', async () => {
  const token = hex()
  const r = await call(address, { token: token.toUpperCase(), env: 'sandbox', topic: 'com.example.t3bot' })
  expect(r.status).toBe(200)
  expect(r.body.ok).toBe(true)
  expect(unseal(r.body.address)).toMatchObject({ t: token, e: 'sandbox', b: 'com.example.t3bot' })
  expect(r.body.address).not.toContain(token)
  expect(r.body.address.length).toBeLessThanOrEqual(300)
  expect(r.headers['cache-control']).toBe('no-store')
  expect(sent.length).toBe(0) // nothing goes to Apple for an address
})

test('address: refuses another app, a token that is not one, an unknown environment', async () => {
  const token = hex()
  const other = await call(address, { token, env: 'sandbox', topic: 'com.someone.else' })
  expect(other.status).toBe(403)
  expect(other.body.code).toBe('not_this_app')
  expect(other.body.error).toContain('push/README.md')
  for (const bad of ['', 'zz'.repeat(32), 'ab'.repeat(16), 'abc', 'a'.repeat(65), 'ab'.repeat(101), 42, null, ['ab'.repeat(32)]]) {
    expect((await call(address, { token: bad, env: 'sandbox', topic: 'com.example.t3bot' })).body.code).toBe('bad_token')
  }
  expect((await call(address, { token, env: 'staging', topic: 'com.example.t3bot' })).body.code).toBe('bad_env')
  expect((await call(address, { token, topic: 'com.example.t3bot' })).status).toBe(400)
  expect((await call(address, { token, env: 'sandbox', topic: ['com.example.t3bot'] })).status).toBe(403)
})

test('address and ring: POST and JSON only, small bodies', async () => {
  for (const h of [address, ring]) {
    const get = await call(h, undefined, { method: 'GET' })
    expect(get.status).toBe(405)
    expect(get.headers.allow).toBe('POST')
    expect((await call(h, undefined, { method: 'OPTIONS' })).status).toBe(405)
    expect((await call(h, 'token=abc', { headers: { 'content-type': 'application/x-www-form-urlencoded' } })).status).toBe(415)
    expect((await call(h, { to: 'x' }, { headers: {} })).status).toBe(415)
    expect((await call(h, { junk: 'x'.repeat(4000) })).status).toBe(413)
    expect((await call(h, {}, { headers: { 'content-type': 'application/json', 'content-length': '100000' } })).status).toBe(413)
    expect((await call(h, [1, 2])).status).toBe(400)
  }
  expect(sent.length).toBe(0)
})

test('address: one caller cannot ask without end', async () => {
  const from = '203.0.113.7'
  for (let i = 0; i < 20; i++) expect((await call(address, { token: hex(), env: 'sandbox', topic: 'com.example.t3bot' }, { from })).status).toBe(200)
  const r = await call(address, { token: hex(), env: 'sandbox', topic: 'com.example.t3bot' }, { from })
  expect(r.status).toBe(429)
  expect(r.headers['retry-after']).toBe('60')
  expect((await call(address, { token: hex(), env: 'sandbox', topic: 'com.example.t3bot' }, { from: '203.0.113.8' })).status).toBe(200)
})

// ---------- /api/ring ----------

test('ring: what the hook sends today rings the phone of the address, in its app and environment', async () => {
  const token = hex()
  const r = await call(ring, { to: addressFor(token, 'production'), thread: 'mcp:9d473594-e2ad-4791-ab0d-4f116a295b49', kind: 'request' })
  expect(r).toMatchObject({ status: 200, body: { ok: true } })
  expect(sent.length).toBe(1)
  expect(sent[0]).toMatchObject({ token, env: 'production', topic: 'com.example.t3bot' })
  expect(sent[0].payload.t3).toEqual({ thread: 'mcp:9d473594-e2ad-4791-ab0d-4f116a295b49', kind: 'request' })
  expect(sent[0].payload.aps.alert).toEqual({ title: 'T3 Bot', body: 'A bot needs you' })
  expect(sent[0].collapseId).toMatch(/^[0-9a-f]{32}$/)
  // The app's own test push: an empty thread.
  expect((await call(ring, { to: addressFor(), thread: '', kind: 'test' })).status).toBe(200)
  expect((await call(ring, { to: addressFor(), kind: 'reply' })).status).toBe(200)
})

test('ring: the caller chooses no words, no app and no phone', async () => {
  const token = hex()
  const r = await call(ring, { to: addressFor(token), thread: 't', kind: 'reply', token: hex(), topic: 'com.apple.Music', env: 'production',
    title: 'Your account is locked', body: 'Tap here', payload: { aps: { alert: 'spam' } }, pushType: 'voip', origin: 'https://elsewhere.example', budgetMs: 999999 })
  expect(r.status).toBe(200)
  expect(sent[0]).toMatchObject({ token, env: 'sandbox', topic: 'com.example.t3bot' })
  expect(sent[0].pushType).toBeUndefined()
  expect(sent[0].origin).toBeUndefined()
  expect(sent[0].budgetMs).toBeUndefined()
  expect(JSON.stringify(sent[0].payload)).not.toMatch(/locked|Tap here|spam/)
})

test('ring: an address nobody was given does nothing', async () => {
  const strangers = await withEnv({ SEAL_KEY: crypto.randomBytes(32).toString('base64') }, () => addressFor())
  const real = addressFor()
  for (const to of [undefined, '', 'abc', hex(), 'A'.repeat(180), strangers, real.slice(0, -3) + 'AAA', { to: real }, 'x'.repeat(5000).slice(0, 1500)]) {
    const r = await call(ring, { to, thread: 't', kind: 'request' })
    expect(r.status).toBe(400)
    expect(r.body).toEqual({ ok: false, code: 'bad_address', error: 'unknown address' })
  }
  expect(sent.length).toBe(0)
})

test('ring: an address for an app this sender no longer serves is refused', async () => {
  const to = addressFor(hex(), 'sandbox', 'com.example.other')
  await withEnv({ ALLOWED_TOPICS: 'com.example.t3bot' }, async () => expect((await call(ring, { to, thread: 't', kind: 'request' })).status).toBe(403))
  expect(sent.length).toBe(0)
})

test('ring: kind and thread are checked', async () => {
  const to = addressFor()
  for (const kind of [undefined, 'alert', 'REQUEST', 1, ['request']]) expect((await call(ring, { to, thread: 't', kind })).body.code).toBe('bad_kind')
  for (const thread of ['x'.repeat(301), 42, { a: 1 }, 'line\nbreak', 'nul\u0000']) expect((await call(ring, { to, thread, kind: 'reply' })).body.code).toBe('bad_thread')
  expect(sent.length).toBe(0)
})

test('ring: a dead phone is reported as gone, so the caller can drop the address', async () => {
  answer = () => ({ status: 410, reason: 'Unregistered' })
  const gone = await call(ring, { to: addressFor(), thread: 't', kind: 'request' })
  expect(gone).toMatchObject({ status: 410, body: { ok: false, gone: true, code: 'gone', error: 'Unregistered' } })
  expect(sent.length).toBe(1)
  answer = () => ({ status: 400, reason: 'DeviceTokenNotForTopic' })
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'request' })).body.gone).toBe(true)
})

test('ring: BadDeviceToken tries the other Apple environment once before calling the phone gone', async () => {
  // A TestFlight build that says sandbox: Apple's sandbox refuses the token, production takes it.
  answer = (p) => (p.env === 'sandbox' ? { status: 400, reason: 'BadDeviceToken' } : { status: 200, reason: '' })
  expect((await call(ring, { to: addressFor(hex(), 'sandbox'), thread: 't', kind: 'request' })).body).toEqual({ ok: true })
  expect(sent.map((p) => p.env)).toEqual(['sandbox', 'production'])
  // A token no environment knows.
  sent.length = 0
  answer = () => ({ status: 400, reason: 'BadDeviceToken' })
  const r = await call(ring, { to: addressFor(hex(), 'production'), thread: 't', kind: 'request' })
  expect(r).toMatchObject({ status: 410, body: { gone: true, error: 'BadDeviceToken' } })
  expect(sent.map((p) => p.env)).toEqual(['production', 'sandbox'])
})

test('ring: a token Apple refused is not sent to Apple again for a few minutes', async () => {
  const dead = hex()
  answer = () => ({ status: 400, reason: 'BadDeviceToken' })
  expect((await call(ring, { to: addressFor(dead), kind: 'request' })).status).toBe(410)
  const asked = sent.length
  expect(asked).toBe(2)
  // The same made-up token again, under a new address and from another caller: Apple is not asked.
  for (let i = 0; i < 5; i++) {
    const r = await call(ring, { to: addressFor(dead), kind: 'reply' })
    expect(r.status).toBe(410)
    expect(r.body.gone).toBe(true)
  }
  expect(sent.length).toBe(asked)
  // Another phone is not held back, and a refusal of the sender itself marks no phone.
  answer = () => ({ status: 200, reason: '' })
  expect((await call(ring, { to: addressFor(), kind: 'request' })).status).toBe(200)
  const fine = hex()
  answer = () => ({ status: 403, reason: 'InvalidProviderToken' })
  expect((await call(ring, { to: addressFor(fine), kind: 'request' })).status).toBe(502)
  answer = () => ({ status: 200, reason: '' })
  expect((await call(ring, { to: addressFor(fine), kind: 'request' })).status).toBe(200)
})

test('ring: Apple refusing the sender, or not answering, is a 502 that says which', async () => {
  answer = () => ({ status: 403, reason: 'InvalidProviderToken' })
  const auth = await call(ring, { to: addressFor(), thread: 't', kind: 'test' })
  expect(auth.status).toBe(502)
  expect(auth.body.code).toBe('apns_auth')
  expect(auth.body.error).toContain('InvalidProviderToken')
  expect(auth.body.gone).toBeUndefined()
  answer = () => ({ status: 0, reason: 'timeout' })
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'test' })).body).toEqual({ ok: false, code: 'apns_unreachable', error: 'Apple did not answer in time' })
  answer = () => ({ status: 0, reason: 'unreachable' })
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'test' })).body.code).toBe('apns_unreachable')
  answer = () => ({ status: 429, reason: 'TooManyRequests' })
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'test' })).status).toBe(429)
  answer = () => ({ status: 413, reason: 'PayloadTooLarge' })
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'test' })).body).toEqual({ ok: false, code: 'apns_refused', error: 'PayloadTooLarge' })
})

test('ring: counted per phone, so more addresses of one phone give no more rings', async () => {
  const token = hex()
  for (let i = 0; i < 30; i++) expect((await call(ring, { to: addressFor(token), thread: `t${i}`, kind: 'reply' })).status).toBe(200)
  const r = await call(ring, { to: addressFor(token), thread: 'more', kind: 'reply' })
  expect(r.status).toBe(429)
  expect(sent.length).toBe(30)
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'reply' })).status).toBe(200)
})

test('ring: one caller cannot ring without end, whatever the phones', async () => {
  const from = '198.51.100.9'
  for (let i = 0; i < 120; i++) await call(ring, { to: addressFor(), thread: 't', kind: 'reply' }, { from })
  expect(sent.length).toBe(120)
  expect((await call(ring, { to: addressFor(), thread: 't', kind: 'reply' }, { from })).status).toBe(429)
  expect(sent.length).toBe(120)
})

test('ring: an old address is refused only when the sender sets a maximum age', async () => {
  const old = seal({ t: hex(), e: 'sandbox', b: 'com.example.t3bot' }, Date.now() - 90 * 86_400_000)
  expect((await call(ring, { to: old, thread: 't', kind: 'reply' })).status).toBe(200)
  await withEnv({ ADDRESS_MAX_AGE_DAYS: '30' }, async () => {
    const r = await call(ring, { to: old, thread: 't', kind: 'reply' })
    expect(r).toMatchObject({ status: 410, body: { gone: true, code: 'expired' } })
  })
})

// ---------- what never leaves ----------

test('a failure inside says nothing of why, and no reply or log carries the token, the address or a key', async () => {
  const token = hex()
  const to = addressFor(token)
  const lines = []
  const keep = { error: console.error, warn: console.warn, log: console.log }
  console.error = console.warn = console.log = (...a) => lines.push(a.join(' '))
  try {
    apns.send = async () => { throw new Error(`secret ${process.env.APNS_KEY} ${token}`) }
    const boom = await call(ring, { to, thread: 't', kind: 'request' })
    expect(boom).toMatchObject({ status: 500, body: { ok: false, code: 'internal', error: 'the sender failed' } })
    apns.send = async () => ({ status: 400, reason: 'BadDeviceToken' })
    const gone = await call(ring, { to, thread: 't', kind: 'request' })
    const out = lines.join('\n') + JSON.stringify([boom, gone])
    expect(lines.length).toBeGreaterThan(0)
    for (const secret of [token, to, process.env.SEAL_KEY, 'PRIVATE KEY', process.env.APNS_KEY.split('\n')[1]]) expect(out).not.toContain(secret)
  } finally { Object.assign(console, keep) }
})

test('a sender with a setting missing says which, on every route, and sends nothing', async () => {
  await withEnv({ APNS_KEY: undefined, SEAL_KEY: 'c2hvcnQ=' }, async () => {
    for (const r of [await call(address, { token: hex(), env: 'sandbox', topic: 'com.example.t3bot' }), await call(ring, { to: 'x'.repeat(120), thread: 't', kind: 'test' })]) {
      expect(r.status).toBe(503)
      expect(r.body).toEqual({ ok: false, code: 'not_configured', error: 'this sender is not set up: SEAL_KEY, APNS_KEY' })
    }
    const h = await call(health, undefined, { method: 'GET' })
    expect(h.status).toBe(503)
    expect(h.body.missing).toEqual(['SEAL_KEY', 'APNS_KEY'])
  })
  expect(sent.length).toBe(0)
})

test('health: ok when everything is set, and it does not call Apple', async () => {
  const r = await call(health, undefined, { method: 'GET' })
  expect(r).toMatchObject({ status: 200, body: { ok: true } })
  expect((await call(health, {}, { method: 'POST' })).status).toBe(405)
  expect(sent.length).toBe(0)
})
