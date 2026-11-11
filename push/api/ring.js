// POST /api/ring {to, thread, kind: "request" | "reply" | "test"} -> {ok}
// Called by the Claude Code hooks T3 Bot puts in T3 Code's launch arguments. Sends a generic push; the phone reads
// the words from T3 Code itself. Nothing is stored. The caller chooses none of the words, the app or the phone:
// the address fixes the phone and the app, and only this sender can make one.
import crypto from 'node:crypto'
import { unseal, expired, allowedTopics, apns, ringPayload, post, reply, tooMany, markGone, isGone } from '../lib/apns.js'

const KINDS = ['request', 'reply', 'test']
// The token is not this app's, or no longer any phone's: the caller should drop the address.
const GONE = ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic']

export default post('ring', 120, async (b, req, res) => {
  if (!KINDS.includes(b.kind)) return reply(res, 400, { ok: false, code: 'bad_kind', error: 'kind: request, reply or test' })
  const thread = b.thread ?? ''
  if (typeof thread !== 'string' || thread.length > 300 || /[\u0000-\u001f\u007f]/.test(thread)) {
    return reply(res, 400, { ok: false, code: 'bad_thread', error: 'thread: a thread id of at most 300 characters' })
  }
  let to
  try { to = unseal(b.to) } catch { return reply(res, 400, { ok: false, code: 'bad_address', error: 'unknown address' }) }
  if (!allowedTopics().includes(to.b)) return reply(res, 403, { ok: false, code: 'not_this_app', error: 'this sender does not push to that app' })
  if (expired(to)) return reply(res, 410, { ok: false, gone: true, code: 'expired', error: 'this address is too old: turn Ring this phone off and on' })
  // Counted per phone, not per address: asking for more addresses of one phone gives no more rings.
  const phone = crypto.createHash('sha256').update(to.t).digest('hex').slice(0, 24)
  if (tooMany(`phone:${phone}`, 30)) { res.setHeader('retry-after', '60'); return reply(res, 429, { ok: false, code: 'too_many', error: 'too many pushes' }) }

  // Apple refused this token a moment ago: the same answer, without asking Apple again.
  // Remembered per app: a token that is not one app's can be another's.
  const seen = `${phone}:${to.b}`
  if (isGone(seen)) return reply(res, 410, { ok: false, gone: true, code: 'gone', error: 'Unregistered' })

  const collapseId = crypto.createHash('sha256').update(`${thread}|${b.kind}`).digest('hex').slice(0, 32)
  const push = { token: to.t, topic: to.b, payload: ringPayload(b.kind, thread), collapseId }
  const started = Date.now()
  let r = await apns.send({ ...push, env: to.e })
  let refusedByBoth = false
  // A token belongs to one of Apple's two environments. A build that names the wrong one (a TestFlight build
  // that says sandbox) gets BadDeviceToken there, so the other is tried once before the phone is called gone.
  if (r.status === 400 && r.reason === 'BadDeviceToken' && Date.now() - started < 2500) {
    const other = to.e === 'production' ? 'sandbox' : 'production'
    const second = await apns.send({ ...push, env: other, budgetMs: 2500 })
    if (second.status === 200) r = second
    else refusedByBoth = second.status === 410 || GONE.includes(second.reason)
  }
  if (r.status === 200) return reply(res, 200, { ok: true })

  console.warn(`push ring: ${b.kind} refused (${r.status} ${r.reason || 'no reason'})`)
  // Remembered only when no environment can take the token: Apple knew it and says it is gone or another app's,
  // or both environments refused it. One environment refusing while the other did not answer proves nothing.
  if (r.status === 410 || r.reason === 'Unregistered' || r.reason === 'DeviceTokenNotForTopic' || refusedByBoth) markGone(seen)
  if (r.status === 410 || GONE.includes(r.reason)) return reply(res, 410, { ok: false, gone: true, code: 'gone', error: r.reason || 'Unregistered' })
  if (r.status === 429) { res.setHeader('retry-after', '60'); return reply(res, 429, { ok: false, code: 'too_many', error: r.reason || 'too many pushes' }) }
  // Apple refuses the sender itself: its key, key id, team id, or the bundle id.
  if (r.status === 403 || r.reason === 'TopicDisallowed') return reply(res, 502, { ok: false, code: 'apns_auth', error: `${r.reason || 'Forbidden'}: Apple refused this sender. Check APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID and ALLOWED_TOPICS` })
  if (r.status === 0) return reply(res, 502, { ok: false, code: 'apns_unreachable', error: r.reason === 'timeout' ? 'Apple did not answer in time' : 'could not reach Apple' })
  return reply(res, 502, { ok: false, code: 'apns_refused', error: r.reason || `APNs answered ${r.status}` })
})
