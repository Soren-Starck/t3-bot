/**
 * Guards on what the server is sent, shared by the real server (t3bot.ts) and the demo (demo.ts) so both refuse
 * the same things with the same words. Pure code, no state: demo-check.ts checks it line by line.
 */

/** A request refused because of what it was sent: answered with 400 and these words. */
export class BadInput extends Error {}

const MB = 1024 * 1024
/**
 * The largest body a route reads. Only the routes that carry photos get room for them, the phone's calendar and
 * contacts get a few megabytes, and everything else is small JSON: a megabyte is far more than any of it needs.
 */
export function bodyLimit(path: string): number {
  if (path === '/v1/share' || /^\/v1\/agents\/[a-z0-9-]+\/send$/.test(path)) return 64 * MB
  if (path === '/v1/phone/sync') return 16 * MB
  return MB
}
export const tooLarge = (path: string) => `the request is too large (this route takes ${bodyLimit(path) / MB} MB at most)`
/** True when the request says, or its body shows, more bytes than its route takes. */
export function overLimit(path: string, contentLength: string | null, read = 0): boolean {
  const limit = bodyLimit(path), said = Number(contentLength ?? 0)
  return (Number.isFinite(said) && said > limit) || read > limit
}

/** A request body as the routes read it: empty is an empty object, anything else must be a JSON object. */
export function readBody(raw: string): { body: Record<string, any>; error?: undefined } | { body?: undefined; error: string } {
  if (!raw.trim()) return { body: {} }
  let body: unknown
  try { body = JSON.parse(raw) } catch { return { error: 'the body is not valid JSON' } }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'the body must be a JSON object' }
  return { body: body as Record<string, any> }
}

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/
const minutes = (s: string) => { const [h, m] = s.split(':').map(Number); return h * 60 + m }
/**
 * Minutes since the last time the clock showed `at` ("HH:MM"), from 0 to 1439, so a window that starts late in the
 * evening goes on past midnight. -1 when `at` is not a time.
 */
export function minutesSince(at: string, minuteOfDay: number): number {
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(String(at))
  if (!m) return -1
  return (((Math.floor(minuteOfDay) - (Number(m[1]) * 60 + Number(m[2]))) % 1440) + 1440) % 1440
}

/**
 * Whether a minute of the day (0 to 1439, local time) falls inside quiet hours. The window can cross midnight
 * (23:00 to 08:00). Its start is inside and its end is not. The same start and end is no window at all, and
 * hours that are not HH:MM (a damaged setting) are no window either: better a ring than a night of silence.
 */
export function inQuiet(from: string, to: string, minuteOfDay: number): boolean {
  if (!HHMM.test(from) || !HHMM.test(to)) return false
  const a = minutes(from), b = minutes(to)
  return a > b ? minuteOfDay >= a || minuteOfDay < b : minuteOfDay >= a && minuteOfDay < b
}

export const NOTE_KINDS = ['alarm', 'approve', 'do', 'know', 'draft'] as const
const DRAFT_KEYS = ['to', 'text', 'via', 'subject', 'event', 'start', 'end', 'location'] as const
const CHECK_STATES = ['pass', 'fail', 'pending']
const text = (x: unknown, max: number) => (typeof x === 'string' || typeof x === 'number' || typeof x === 'boolean' ? String(x).trim().slice(0, max) : '')
const isObject = (x: unknown): x is Record<string, any> => !!x && typeof x === 'object' && !Array.isArray(x)

export type TidyNote = {
  kind: (typeof NOTE_KINDS)[number]; title: string; body?: string; link?: string; key?: string; agent: string; faceId: boolean
  fields?: { label: string; value: string }[]
  checks?: { label: string; state: string }[]
  edit?: { label: string; text: string }
  actions?: { id: string; label: string; message?: string; handler?: string; faceId?: boolean }[]
  draft: Record<string, string>
}
/**
 * What `t3bot notify` (or any script) posted, brought to the types and sizes the app reads. The app refuses the
 * whole home screen when one value has the wrong type, and a note is kept for a long time: so every text is a
 * string of a bounded length, a check has one of the three states, and a draft only holds the fields the phone's
 * composer takes. Throws BadInput for a kind that does not exist or a missing title.
 */
export function tidyNote(n: unknown): TidyNote {
  const o = isObject(n) ? n : {}
  const kind = kindOf(o.kind)
  if (!(NOTE_KINDS as readonly string[]).includes(kind)) throw new BadInput('kind must be alarm, approve, do, know or draft')
  const title = text(o.title, 300)
  if (!title) throw new BadInput('title is required')
  const list = (x: unknown, max: number) => (Array.isArray(x) ? x.filter(isObject).slice(0, max) : undefined)
  const draft: Record<string, string> = {}
  if (isObject(o.draft)) for (const k of DRAFT_KEYS) { const v = text(o.draft[k], 20000); if (v) draft[k] = v }
  return {
    kind: kind as TidyNote['kind'], title, agent: text(o.agent, 100), faceId: !!o.faceId,
    body: text(o.body, 8000) || undefined, link: text(o.link, 2000) || undefined, key: text(o.key, 200) || undefined,
    fields: list(o.fields, 40)?.map((f) => ({ label: text(f.label, 200), value: text(f.value, 2000) })),
    checks: list(o.checks, 40)?.map((c) => ({ label: text(c.label, 200), state: CHECK_STATES.includes(c.state) ? c.state : 'pending' })),
    edit: isObject(o.edit) && o.edit.text !== undefined && o.edit.text !== null
      ? { label: text(o.edit.label, 100) || 'Text', text: String(typeof o.edit.text === 'object' ? '' : o.edit.text).slice(0, 20000) } : undefined,
    actions: list(o.actions, 12)?.filter((a) => text(a.label, 60)).slice(0, 6).map((a, i) => ({
      id: text(a.id, 64) || `a${i}`, label: text(a.label, 60), message: text(a.message, 4000) || undefined, handler: text(a.handler, 100) || undefined,
      faceId: a.faceId === undefined || a.faceId === null ? undefined : !!a.faceId,
    })),
    draft,
  }
}

export type StoredNote = {
  id: string; agent: string; kind: (typeof NOTE_KINDS)[number]; title: string; body?: string; link?: string; key?: string; created_at: string
  /** The card parts kept beside the note; for a draft, `draft` holds the composer fields and the rest is unset. */
  draft?: Record<string, string>
  fields?: { label: string; value: string }[]
  checks?: { label: string; state: string }[]
  edit?: { label: string; text: string }
  actions?: { id: string; label: string; kind: string; style?: string; faceId?: boolean; message?: string; handler?: string }[]
  faceId: boolean
}
/**
 * A note as the database holds it, read back into the shape the app decodes. Notes are kept for weeks, so one
 * saved before tidyNote existed (or by hand) can hold a number where a text belongs, a check with an unknown
 * state or card parts that are not lists: the app refuses the whole home screen for one such value. Every part
 * is brought to its type here, with the same sizes as tidyNote, and a part that cannot be read is left out;
 * the note itself is always kept. Only a row with no id or a kind that does not exist gives null.
 */
export function storedNote(row: unknown): StoredNote | null {
  const r = isObject(row) ? row : {}
  // The id is the row's key and is kept as it is, so the card's buttons still find the row.
  const id = typeof r.id === 'string' ? r.id : text(r.id, 400), kind = text(r.kind, 20)
  if (!id || !(NOTE_KINDS as readonly string[]).includes(kind)) return null
  let data: unknown = {}
  if (typeof r.data === 'string' && r.data) { try { data = JSON.parse(r.data) } catch {} } else if (isObject(r.data)) data = r.data
  const d = isObject(data) ? data : {}
  // The date goes out the way the server writes one (2026-11-10T09:00:00.000Z): a date written today is unchanged.
  const at = new Date(typeof r.created_at === 'string' && Number.isFinite(Date.parse(r.created_at)) ? Date.parse(r.created_at) : 0).toISOString()
  const base = {
    id, agent: text(r.agent, 100), kind: kind as StoredNote['kind'], title: text(r.title, 300) || '(no title)',
    body: text(r.body, 8000) || undefined, link: text(r.link, 2000) || undefined, key: text(r.key, 200) || undefined, created_at: at,
  }
  if (kind === 'draft') {
    const draft: Record<string, string> = {}
    for (const k of DRAFT_KEYS) { const v = text(d[k], 20000); if (v) draft[k] = v }
    return { ...base, draft, faceId: false }
  }
  const list = (x: unknown, max: number) => (Array.isArray(x) ? x.filter(isObject).slice(0, max) : undefined)
  const actions = list(d.actions, 12)?.filter((a) => text(a.label, 60)).map((a, i) => ({
    id: text(a.id, 64) || `a${i}`, label: text(a.label, 60), kind: text(a.kind, 20) || (text(a.handler, 100) ? 'command' : 'message'),
    style: text(a.style, 20) || undefined, faceId: a.faceId === undefined || a.faceId === null ? undefined : !!a.faceId,
    message: text(a.message, 4000) || undefined, handler: text(a.handler, 100) || undefined,
  }))
  return {
    ...base, faceId: !!d.faceId,
    fields: list(d.fields, 40)?.map((f) => ({ label: text(f.label, 200), value: text(f.value, 2000) })),
    checks: list(d.checks, 40)?.map((c) => ({ label: text(c.label, 200), state: CHECK_STATES.includes(c.state) ? c.state : 'pending' })),
    edit: isObject(d.edit) && d.edit.text !== undefined && d.edit.text !== null
      ? { label: text(d.edit.label, 100) || 'Text', text: String(typeof d.edit.text === 'object' ? '' : d.edit.text).slice(0, 20000) } : undefined,
    actions: actions?.length ? actions : undefined,
  }
}

/**
 * The methods each known path takes, for the answer to a wrong one: 405 with an Allow header, where an unknown
 * path stays 404. Both servers ask this only after no route matched, and only for a request with a valid token.
 */
const ROUTES: [RegExp, string][] = [
  [/^\/v1\/(hello|home|file|skins|search|know|phone\/calendar|phone\/contacts)$/, 'GET'],
  [/^\/v1\/agents\/[a-z0-9-]+$/, 'GET'],
  [/^\/v1\/settings$/, 'GET, POST'],
  [/^\/v1\/(answer|cards\/(done|snooze|handle|act)|devices|devices\/remove|notify|share|live|notes\/wrong|agents|routines\/enabled|phone\/sync|phone\/forget|test-push)$/, 'POST'],
  [/^\/v1\/agents\/[a-z0-9-]+\/(send|edit)$/, 'POST'],
]
/** The Allow header for a request whose path exists but not with this method, else null (the path is unknown, or the method is one it takes). */
export function wrongMethod(path: string, method: string, more: [RegExp, string][] = []): string | null {
  const hit = [...ROUTES, ...more].find(([re]) => re.test(path))
  return hit && !hit[1].split(', ').includes(method) ? hit[1] : null
}
/** Kinds as scripts have written them: any case, spaces around. An unknown kind is still refused by tidyNote. */
export const kindOf = (x: unknown) => (x === undefined || x === null ? 'know' : String(x).trim().toLowerCase())
