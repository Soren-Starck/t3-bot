import { test, expect } from 'bun:test'
import crypto from 'node:crypto'
import http2 from 'node:http2'

const pair = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
const P8 = pair.privateKey.export({ type: 'pkcs8', format: 'pem' })
process.env.SEAL_KEY = crypto.randomBytes(32).toString('base64')
process.env.ALLOWED_TOPICS = 'com.example.t3bot'
process.env.APNS_KEY = P8
process.env.APNS_KEY_ID = 'ABCDE12345'
process.env.APNS_TEAM_ID = 'TEAM123456'
delete process.env.ADDRESS_MAX_AGE_DAYS
const { seal, unseal, expired, ringPayload, tooMany, bearer, missing, readJson, send, ADDRESS_MAX } = await import('./apns.js')

const TOKEN = 'ab'.repeat(32)
const parts = (jwt) => jwt.split('.').slice(0, 2).map((p) => JSON.parse(Buffer.from(p, 'base64url').toString()))

/** Sets environment variables for one test and puts the old values back. */
async function withEnv(values, fn) {
  const old = Object.fromEntries(Object.keys(values).map((k) => [k, process.env[k]]))
  for (const [k, v] of Object.entries(values)) v === undefined ? delete process.env[k] : (process.env[k] = v)
  try { return await fn() } finally { for (const [k, v] of Object.entries(old)) v === undefined ? delete process.env[k] : (process.env[k] = v) }
}

test('seal and unseal', () => {
  const a = seal({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot' })
  expect(a).toMatch(/^[A-Za-z0-9_-]+$/)
  expect(unseal(a).t).toBe(TOKEN)
  const tampered = a.slice(0, -2) + (a.endsWith('A') ? 'BB' : 'AA')
  expect(() => unseal(tampered)).toThrow()
})

test('an address cannot be forged, guessed or made with another key', async () => {
  for (const bad of [undefined, null, 42, {}, '', 'abc', 'x'.repeat(200), '!'.repeat(80), 'A'.repeat(5000)]) expect(() => unseal(bad)).toThrow()
  const other = await withEnv({ SEAL_KEY: crypto.randomBytes(32).toString('base64') }, () => seal({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot' }))
  expect(() => unseal(other)).toThrow()
  // Sealed by this sender, but not the shape of an address.
  expect(() => unseal(seal({ t: 'nothex', e: 'sandbox', b: 'com.example.t3bot' }))).toThrow()
  expect(() => unseal(seal({ t: TOKEN, e: 'elsewhere', b: 'com.example.t3bot' }))).toThrow()
})

test('an address made before this version still opens', () => {
  // What 0.2 sealed: no day inside.
  const iv = crypto.randomBytes(12)
  const c = crypto.createCipheriv('aes-256-gcm', Buffer.from(process.env.SEAL_KEY, 'base64'), iv)
  const body = Buffer.concat([c.update(JSON.stringify({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot', v: 1 })), c.final()])
  const old = Buffer.concat([iv, body, c.getAuthTag()]).toString('base64url')
  expect(unseal(old)).toMatchObject({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot' })
  expect(expired(unseal(old))).toBe(false)
})

test('an address fits in the hook (the app drops one over 300 characters)', () => {
  expect(seal({ t: TOKEN, e: 'production', b: 'com.example.t3bot' }).length).toBeLessThan(220)
  expect(seal({ t: TOKEN, e: 'production', b: 'com.a-rather-long-company-name.some-product.t3bot' }).length).toBeLessThanOrEqual(ADDRESS_MAX)
})

test('addresses expire only when ADDRESS_MAX_AGE_DAYS says so', async () => {
  const day = 86_400_000, now = Date.now()
  const old = unseal(seal({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot' }, now - 40 * day))
  expect(expired(old, now)).toBe(false)
  await withEnv({ ADDRESS_MAX_AGE_DAYS: '30' }, () => {
    expect(expired(old, now)).toBe(true)
    expect(expired(unseal(seal({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot' }, now - 5 * day)), now)).toBe(false)
    expect(expired({ t: TOKEN, e: 'sandbox', b: 'com.example.t3bot', v: 1 }, now)).toBe(true)
  })
})

test('payload says nothing about the work', () => {
  const p = ringPayload('request', 'mcp:abc')
  expect(p.aps['mutable-content']).toBe(1)
  expect(p.aps.category).toBe('T3REQUEST')
  expect(p.t3).toEqual({ thread: 'mcp:abc', kind: 'request' })
  expect(ringPayload('reply', 'x').aps.alert.body).toBe('A bot answered')
  expect(JSON.stringify(ringPayload('reply', 'x'.repeat(300))).length).toBeLessThan(4096)
})

test('flood guard', () => {
  for (let i = 0; i < 30; i++) expect(tooMany('k')).toBe(false)
  expect(tooMany('k')).toBe(true)
  expect(tooMany('another')).toBe(false)
})

test('flood guard opens again after its window and does not grow without end', () => {
  const t0 = 1_000_000
  for (let i = 0; i < 3; i++) expect(tooMany('w', 3, 1000, t0)).toBe(false)
  expect(tooMany('w', 3, 1000, t0 + 999)).toBe(true)
  expect(tooMany('w', 3, 1000, t0 + 1000)).toBe(false)
  for (let i = 0; i < 12_000; i++) tooMany(`many:${i}`, 3, 1000, t0)
  expect(tooMany('w2', 1, 1000, t0 + 5000)).toBe(false)
})

test('provider token: ES256, signed by the key, the key id and team inside', () => {
  const now = 1_800_000_000
  const jwt = bearer(now)
  const [head, claims] = parts(jwt)
  expect(head).toEqual({ alg: 'ES256', kid: 'ABCDE12345' })
  expect(claims.iss).toBe('TEAM123456')
  const [h, c, s] = jwt.split('.')
  expect(crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: pair.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url'))).toBe(true)
})

test('provider token: signed once per half hour, never older than Apple allows', () => {
  const start = 1_800_000_000 - (1_800_000_000 % 1800)
  const first = bearer(start + 5)
  // Not signed again for each push.
  expect(bearer(start + 6)).toBe(first)
  expect(bearer(start + 1799)).toBe(first)
  const next = bearer(start + 1800)
  expect(next).not.toBe(first)
  for (const now of [start + 5, start + 1799, start + 1800, start + 3599]) {
    const iat = parts(bearer(now))[1].iat
    expect(iat).toBeLessThanOrEqual(now) // never in the future
    expect(now - iat).toBeLessThan(30 * 60) // Apple refuses over 60 minutes
    expect(iat % 1800).toBe(0) // every instance signs the same claims, which change every 30 minutes (Apple: not under 20)
  }
})

test('settings: what is missing is named, never shown', async () => {
  expect(missing()).toEqual([])
  await withEnv({ SEAL_KEY: 'short', APNS_KEY: '-----BEGIN PRIVATE KEY-----\nMIGHSECRETSECRET\n-----END PRIVATE KEY-----', APNS_KEY_ID: 'abc', APNS_TEAM_ID: undefined, ALLOWED_TOPICS: ' , ' }, () => {
    expect(missing()).toEqual(['SEAL_KEY', 'APNS_KEY', 'APNS_KEY_ID', 'APNS_TEAM_ID', 'ALLOWED_TOPICS'])
    let said = ''
    try { bearer() } catch (e) { said = String(e.message) + String(e.stack) }
    expect(said).toContain('APNS_KEY')
    expect(said).not.toContain('MIGHSECRET')
  })
  // An RSA key is not a push key.
  const rsa = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' })
  await withEnv({ APNS_KEY: rsa }, () => expect(missing()).toEqual(['APNS_KEY']))
})

test('settings: the key is read with escaped new lines, without its header lines, and with spaces around values', async () => {
  const escaped = P8.trim().replace(/\n/g, '\\n')
  const bare = P8.split('\n').filter((l) => l && !l.startsWith('-----')).join('')
  for (const APNS_KEY of [escaped, bare, `\n${P8}\n`]) await withEnv({ APNS_KEY, APNS_KEY_ID: ' ABCDE12345\n' }, () => {
    expect(missing()).toEqual([])
    expect(parts(bearer(1_900_000_000))[0].kid).toBe('ABCDE12345')
  })
})

test('request bodies: JSON only, small, an object', async () => {
  const json = { 'content-type': 'application/json' }
  expect((await readJson({ headers: {}, body: { a: 1 } })).status).toBe(415)
  expect((await readJson({ headers: { 'content-type': 'text/plain' }, body: '{}' })).status).toBe(415)
  expect((await readJson({ headers: { 'content-type': 'application/json; charset=utf-8' }, body: { a: 1 } })).value).toEqual({ a: 1 })
  expect((await readJson({ headers: { ...json, 'content-length': '999999' }, body: {} })).status).toBe(413)
  expect((await readJson({ headers: json, body: { big: 'x'.repeat(5000) } })).status).toBe(413)
  expect((await readJson({ headers: json, body: [1] })).status).toBe(400)
  expect((await readJson({ headers: json, body: 'not json' })).code).toBe('bad_json')
  // Vercel throws from `req.body` when the JSON is broken.
  expect((await readJson({ headers: json, get body() { throw new Error('Invalid JSON') } })).code).toBe('bad_json')
  // A bare stream is read up to the limit and no further.
  const stream = (chunks) => ({ headers: json, async *[Symbol.asyncIterator]() { for (const c of chunks) yield Buffer.from(c) } })
  expect((await readJson(stream(['{"to":', '"x"}']))).value).toEqual({ to: 'x' })
  let read = 0
  const endless = { headers: json, async *[Symbol.asyncIterator]() { for (;;) { read++; yield Buffer.alloc(1024, 97) } } }
  expect((await readJson(endless)).status).toBe(413)
  expect(read).toBeLessThan(5)
})

// ---------- sending, against a local stand-in for Apple ----------

async function apple(answer) {
  const seen = []
  const server = http2.createServer()
  server.on('stream', (stream, headers) => {
    let body = ''
    stream.on('data', (c) => { body += c })
    stream.on('end', () => {
      seen.push({ headers, body })
      const a = answer(seen.length, headers)
      if (!a) return // never answers
      stream.respond({ ':status': a.status })
      stream.end(a.reason ? JSON.stringify({ reason: a.reason }) : '')
    })
  })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  return { seen, origin: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => { server.close(r); setTimeout(r, 50) }) }
}
const push = { token: TOKEN, env: 'sandbox', topic: 'com.example.t3bot', payload: ringPayload('request', 'mcp:abc'), collapseId: 'c1' }

test('send: one request with the token, the app and the provider token', async () => {
  const a = await apple(() => ({ status: 200 }))
  expect(await send({ ...push, origin: a.origin })).toEqual({ status: 200, reason: '' })
  expect(a.seen.length).toBe(1)
  const h = a.seen[0].headers
  expect(h[':path']).toBe(`/3/device/${TOKEN}`)
  expect(h['apns-topic']).toBe('com.example.t3bot')
  expect(h['apns-push-type']).toBe('alert')
  expect(h['apns-collapse-id']).toBe('c1')
  expect(h.authorization).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/)
  expect(JSON.parse(a.seen[0].body).t3.kind).toBe('request')
  await a.close()
})

test('send: a dead token comes back as Apple said it, with no second try', async () => {
  const a = await apple(() => ({ status: 410, reason: 'Unregistered' }))
  expect(await send({ ...push, origin: a.origin })).toEqual({ status: 410, reason: 'Unregistered' })
  expect(a.seen.length).toBe(1)
  const b = await apple(() => ({ status: 400, reason: 'BadDeviceToken' }))
  expect(await send({ ...push, origin: b.origin })).toEqual({ status: 400, reason: 'BadDeviceToken' })
  expect(b.seen.length).toBe(1)
  await a.close(); await b.close()
})

test('send: tried again after a 503, which cannot have rung the phone', async () => {
  const a = await apple((n) => (n === 1 ? { status: 503, reason: 'ServiceUnavailable' } : { status: 200 }))
  expect((await send({ ...push, origin: a.origin })).status).toBe(200)
  expect(a.seen.length).toBe(2)
  await a.close()
})

test('send: a provider token Apple calls expired is signed again, once', async () => {
  const a = await apple((n) => (n === 1 ? { status: 403, reason: 'ExpiredProviderToken' } : { status: 200 }))
  expect((await send({ ...push, origin: a.origin })).status).toBe(200)
  expect(a.seen.length).toBe(2)
  expect(a.seen[1].headers.authorization).not.toBe(a.seen[0].headers.authorization)
  const b = await apple(() => ({ status: 403, reason: 'InvalidProviderToken' }))
  expect(await send({ ...push, origin: b.origin })).toEqual({ status: 403, reason: 'InvalidProviderToken' })
  expect(b.seen.length).toBe(1)
  await a.close(); await b.close()
})

test('send: no answer in time is a timeout, and is not tried again (the phone may have rung)', async () => {
  const a = await apple(() => null)
  const t = Date.now()
  expect(await send({ ...push, origin: a.origin, budgetMs: 300 })).toEqual({ status: 0, reason: 'timeout' })
  expect(Date.now() - t).toBeLessThan(1500)
  expect(a.seen.length).toBe(1)
  await a.close()
})

test('send: nothing listening gives a plain failure, with nothing about the network in it', async () => {
  const a = await apple(() => ({ status: 200 }))
  await a.close()
  const r = await send({ ...push, origin: a.origin, budgetMs: 2000 })
  expect(r).toEqual({ status: 0, reason: 'unreachable' })
})

test('send: Apple\'s reason is passed on only when it looks like one', async () => {
  const a = await apple(() => ({ status: 400, reason: '<script>alert(1)</script>' }))
  expect(await send({ ...push, origin: a.origin })).toEqual({ status: 400, reason: '' })
  await a.close()
})
