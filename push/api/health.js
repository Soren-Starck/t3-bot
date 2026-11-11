// GET /api/health -> {ok} when every setting is present and well formed, and the push key signs.
// It names a missing setting, never a value, and does not call Apple.
import { missing, bearer, reply, tooMany } from '../lib/apns.js'

export default function handler(req, res) {
  if (req.method !== 'GET') { res.setHeader('allow', 'GET'); return reply(res, 405, { ok: false, code: 'method', error: 'GET only' }) }
  const ip = String(req.headers?.['x-forwarded-for'] || '').split(',')[0].trim().slice(0, 64)
  if (tooMany(`health:${ip}`, 30)) { res.setHeader('retry-after', '60'); return reply(res, 429, { ok: false, code: 'too_many', error: 'too many requests' }) }
  const lacks = missing()
  if (!lacks.length) { try { bearer() } catch { lacks.push('APNS_KEY') } }
  if (lacks.length) return reply(res, 503, { ok: false, code: 'not_configured', error: `this sender is not set up: ${lacks.join(', ')}`, missing: lacks })
  return reply(res, 200, { ok: true })
}
