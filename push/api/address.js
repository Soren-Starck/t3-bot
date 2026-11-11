// POST /api/address {token, env, topic} -> {ok, address}
// The phone's push token sealed for this sender. Hooks on the Mac carry the address; only this sender can open it.
// Nothing is sent to Apple here, and nothing is stored.
import { seal, allowedTopics, post, reply, validToken, validEnv, ADDRESS_MAX } from '../lib/apns.js'

export default post('address', 20, (b, req, res) => {
  const token = typeof b.token === 'string' ? b.token.toLowerCase() : ''
  if (!validToken(token)) return reply(res, 400, { ok: false, code: 'bad_token', error: 'token: the hex push token of the device' })
  if (!validEnv(b.env)) return reply(res, 400, { ok: false, code: 'bad_env', error: 'env: sandbox or production' })
  if (typeof b.topic !== 'string' || !allowedTopics().includes(b.topic)) {
    return reply(res, 403, { ok: false, code: 'not_this_app', error: 'this sender does not push to that app. An app built with your own Apple team needs its own sender: see push/README.md' })
  }
  const address = seal({ t: token, e: b.env, b: b.topic })
  if (address.length > ADDRESS_MAX) return reply(res, 400, { ok: false, code: 'too_long', error: 'the token and bundle id are too long for one address' })
  return reply(res, 200, { ok: true, address })
})
