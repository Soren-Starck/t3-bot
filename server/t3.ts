/**
 * Everything T3 Bot needs from T3 Code, on the machine that runs it.
 * Reads: T3 Code's own SQLite projection, opened read-only (threads, messages, runs, pending questions).
 * Writes: one orchestration command over T3 Code's local /ws socket, with a session token from its own CLI
 * (`t3 auth session issue`).
 *
 * T3 Code's folder is ~/.t3 unless $T3BOT_T3_HOME or $T3CODE_HOME says otherwise. With T3BOT_READONLY=1 nothing
 * is ever sent to T3 Code: every write answers with an error instead (for tests against a real install).
 */
import { Database } from 'bun:sqlite'
import { existsSync, readFileSync } from 'fs'
import { join } from 'path'
import { HOME, tilde, untilde } from './config'

export const T3_HOME = untilde(process.env.T3BOT_T3_HOME || process.env.T3CODE_HOME || join(HOME, '.t3'))
const RUNTIME = join(T3_HOME, 'userdata/server-runtime.json')
export const DB_PATH = process.env.T3BOT_T3_DB || join(T3_HOME, 'userdata/statev2.sqlite')
export const READONLY = process.env.T3BOT_READONLY === '1'

let db: Database | null = null
let lastError = ''
function t3db(): Database {
  if (!db) db = new Database(DB_PATH, { readonly: true })
  return db
}
/** A read of T3 Code's state that failed for now, in words the app can show as they are. */
export class ReadError extends Error {}
/** Failures that waiting does not cure: the file is not T3 Code's state, or it has other tables than T3 Bot reads. */
const WILL_NOT_HEAL = /no such table|no such column|not a database|malformed|unable to open/i
/** The tables every screen of the app is built from. */
const CORE_TABLES = ['threads', 'runs', 'messages', 'runtime_requests', 'turn_items'].map((t) => `orchestration_v2_projection_${t}`)

/**
 * One read. With no T3 Code state on this machine it answers with no rows, so a fresh install shows an empty app
 * instead of failing. A query that fails is tried once more on a fresh handle (T3 Code can replace the file when
 * it updates), then throws a ReadError: the caller must not mistake "could not read" for "nothing there".
 * The exception is a state file T3 Bot cannot read at all (another T3 Code generation, or not a database): that
 * answers with no rows like a machine without T3 Code, and status() tells the person why the app is empty.
 */
export function q<T = any>(sql: string, ...params: any[]): T[] {
  if (!existsSync(DB_PATH)) {
    try { db?.close() } catch {}
    db = null
    lastError = `no T3 Code state at ${DB_PATH}`
    return []
  }
  try {
    const rows = t3db().query(sql).all(...params) as T[]
    lastError = ''
    return rows
  } catch {
    try { db?.close() } catch {}
    db = null
    try {
      const rows = t3db().query(sql).all(...params) as T[]
      lastError = ''
      return rows
    } catch (e) {
      lastError = String((e as any)?.message ?? e).slice(0, 200)
      try { db?.close() } catch {}
      db = null
      if (WILL_NOT_HEAL.test(lastError)) return []
      throw new ReadError(`T3 Code's data could not be read just now (${lastError}). Try again in a moment.`)
    }
  }
}

/** Why a state file that is there cannot be used, in one sentence that says what to do; null when it reads fine. */
function unreadable(): string | null {
  try {
    const have = new Set(t3db().query(`select name from sqlite_master where type = 'table'`).all().map((r: any) => String(r.name)))
    const missing = CORE_TABLES.filter((t) => !have.has(t))
    return missing.length
      ? `T3 Bot cannot read the data of this T3 Code (${tilde(DB_PATH)} has no table ${missing[0]}). One of the two is too old for the other: update T3 Code and T3 Bot, then restart T3 Bot.`
      : null
  } catch (e) {
    try { db?.close() } catch {}
    db = null
    return `T3 Bot cannot read T3 Code's data at ${tilde(DB_PATH)} (${String((e as any)?.message ?? e).slice(0, 120)}). ` +
      'Check that the file is T3 Code\'s and that this account may read it. If T3 Code keeps its data elsewhere, set T3BOT_T3_HOME to that folder.'
  }
}
const parse = (s: unknown): any => { try { return JSON.parse(String(s ?? '')) ?? {} } catch { return {} } }

export type Thread = { id: string; title: string; projectId: string; status: string; updatedAt: string }

export function threadsByIds(ids: string[]): Map<string, Thread> {
  const out = new Map<string, Thread>()
  if (!ids.length) return out
  const rows = q<any>(
    `select thread_id, title, project_id, updated_at from orchestration_v2_projection_threads
     where thread_id in (${ids.map(() => '?').join(',')}) and deleted_at is null`, ...ids)
  for (const r of rows) out.set(r.thread_id, { id: r.thread_id, title: r.title, projectId: r.project_id, status: lastRunStatus(r.thread_id), updatedAt: r.updated_at })
  return out
}

export function threadsByPrefix(prefixes: string[]): Thread[] {
  if (!prefixes.length) return []
  const rows = q<any>(
    `select thread_id, title, project_id, updated_at from orchestration_v2_projection_threads
     where deleted_at is null and archived_at is null and (${prefixes.map(() => 'title like ?').join(' or ')})`,
    ...prefixes.map((p) => p.replace(/[%_]/g, '') + '%'))
  return rows.map((r) => ({ id: r.thread_id, title: r.title, projectId: r.project_id, status: lastRunStatus(r.thread_id), updatedAt: r.updated_at }))
}

export function lastRun(threadId: string): { id: string; status: string; requestedAt: string; completedAt: string | null } | null {
  const r = q<any>(`select run_id, status, requested_at, completed_at from orchestration_v2_projection_runs
                    where thread_id = ? order by ordinal desc limit 1`, threadId)[0]
  return r ? { id: r.run_id, status: r.status, requestedAt: r.requested_at, completedAt: r.completed_at } : null
}
export function lastRunStatus(threadId: string): string {
  return lastRun(threadId)?.status ?? 'idle'
}
export const isActive = (status: string) => ['running', 'starting', 'preparing', 'queued'].includes(status)

export type Msg = { id: string; role: 'user' | 'assistant'; text: string; at: string; runId: string | null; createdBy: string; streaming: boolean }

export function messages(threadId: string, limit = 120): Msg[] {
  const rows = q<any>(
    `select message_id, role, streaming, created_at, run_id, payload_json from orchestration_v2_projection_messages
     where thread_id = ? and role in ('user','assistant') order by created_at desc limit ?`, threadId, limit)
  return rows.reverse().map((r) => {
    let p: any = {}
    try { p = JSON.parse(r.payload_json) } catch {}
    return { id: r.message_id, role: r.role, text: String(p.text ?? ''), at: r.created_at, runId: r.run_id, createdBy: p.createdBy ?? '', streaming: !!r.streaming }
  })
}

export function lastAssistant(threadId: string): Msg | null {
  const r = q<any>(
    `select message_id, role, streaming, created_at, run_id, payload_json from orchestration_v2_projection_messages
     where thread_id = ? and role = 'assistant' order by created_at desc limit 1`, threadId)[0]
  if (!r) return null
  const p = parse(r.payload_json)
  return { id: r.message_id, role: 'assistant', text: String(p.text ?? ''), at: r.created_at, runId: r.run_id, createdBy: p.createdBy ?? '', streaming: !!r.streaming }
}

export type Question = { id: string; question: string; header?: string; multiSelect: boolean; options: { label: string; description?: string }[] }
export type Pending = {
  requestId: string; threadId: string; threadTitle: string; kind: 'user_input' | 'command'; createdAt: string
  questions: Question[]; command?: string
  /** For an approval: what the agent says it wants to do, when it says it. */
  description?: string
}

/** Every question or approval an agent is waiting on, in any thread of this server, that can still be answered. */
export function pendingRequests(maxAgeDays = 14): Pending[] {
  const since = new Date(Date.now() - maxAgeDays * 86400e3).toISOString()
  const rows = q<any>(
    `select r.runtime_request_id, r.thread_id, r.kind, r.created_at, r.payload_json, t.title
       from orchestration_v2_projection_runtime_requests r
       join orchestration_v2_projection_threads t on t.thread_id = r.thread_id
      where r.status = 'pending' and r.created_at > ? and t.deleted_at is null and t.archived_at is null
      order by r.created_at`, since)
  const out: Pending[] = []
  for (const r of rows) {
    let p: any = {}
    try { p = JSON.parse(r.payload_json) } catch {}
    if (p.responseCapability?.type && p.responseCapability.type !== 'live') continue
    const item = q<any>(
      `select payload_json from orchestration_v2_projection_turn_items
        where thread_id = ? and type in ('user_input_request','approval_request','command_approval_request')
        order by updated_at desc limit 20`, r.thread_id)
      .map((x) => { try { return JSON.parse(x.payload_json) } catch { return {} } })
      .find((x) => x.requestId === r.runtime_request_id)
    const questions: Question[] = (item?.questions ?? []).map((qq: any) => ({
      id: String(qq.id ?? qq.question), question: String(qq.question ?? ''), header: qq.header,
      multiSelect: !!qq.multiSelect, options: (qq.options ?? []).map((o: any) => ({ label: String(o.label), description: o.description })),
    }))
    if (r.kind === 'user_input' && !questions.length) continue
    out.push({
      requestId: r.runtime_request_id, threadId: r.thread_id, threadTitle: r.title, kind: r.kind, createdAt: r.created_at,
      questions, command: item?.prompt ?? item?.command ?? item?.detail ?? undefined,
      description: [item?.reason, item?.title].find((x: unknown) => typeof x === 'string' && x.trim() && x !== (item?.prompt ?? item?.command)) ?? undefined,
    })
  }
  return out
}

// ---------- T3 Code itself: where it runs, its CLI, its projects ----------

/** The running T3 Code server, from the file it writes at start. Null when T3 Code has never run here. */
export function runtime(): { port: number; serverVersion: string; pid?: number } | null {
  try {
    const r = JSON.parse(readFileSync(RUNTIME, 'utf8'))
    return r && Number(r.port) > 0 ? r : null
  } catch { return null }
}

/** T3 Code's command line: the one that ships with the running server first, then whatever `t3` is installed. */
export function cliPath(): string | null {
  const rt = runtime()
  const candidates = [
    process.env.T3BOT_T3_CLI ? untilde(process.env.T3BOT_T3_CLI) : null,
    ...(rt?.serverVersion ? ['t3.real', 't3'].map((n) => join(T3_HOME, 'runtime/versions', String(rt.serverVersion), n)) : []),
    Bun.which('t3'), join(HOME, '.bun/bin/t3'), join(HOME, '.local/bin/t3'), '/opt/homebrew/bin/t3', '/usr/local/bin/t3',
  ]
  return candidates.find((p): p is string => !!p && existsSync(p)) ?? null
}

export type Project = { id: string; title: string; path: string; updatedAt: string }
/** The projects in T3 Code, pinned and recently used first. */
export function listProjects(): Project[] {
  try {
    return q<any>(`select project_id, title, workspace_root, updated_at from projection_projects
                    where deleted_at is null and archived_at is null
                    order by (pinned_at is null), updated_at desc`)
      .map((r) => ({ id: r.project_id, title: String(r.title ?? ''), path: String(r.workspace_root ?? ''), updatedAt: r.updated_at }))
  } catch { return [] }
}

/** T3 Code's id for this machine, which the app uses in links back to a thread. */
export function environmentId(): string {
  try { return readFileSync(join(T3_HOME, 'userdata/environment-id'), 'utf8').trim() } catch { return '' }
}

/** What `t3bot doctor` and the app show about T3 Code. `problem` is one plain sentence, or null when all is well. */
export function status() {
  const rt = runtime()
  let alive = false
  if (rt?.pid) { try { process.kill(rt.pid, 0); alive = true } catch (e: any) { alive = e?.code === 'EPERM' } }
  const dbFound = existsSync(DB_PATH)
  const cli = cliPath()
  const running = !!rt && (rt.pid ? alive : true)
  const problem = !dbFound ? `T3 Code is not set up on this machine (nothing at ${tilde(DB_PATH)}). Install it and open it once.`
    : unreadable() ?? (!running ? 'T3 Code is not running. Open it, then try again.'
    : !cli ? 'T3 Code is running but its `t3` command was not found. Set T3BOT_T3_CLI to its path.'
    : null)
  return { home: T3_HOME, db: DB_PATH, dbFound, running, port: rt?.port ?? null, version: rt?.serverVersion ?? null, cli, readError: lastError || null, problem }
}

// ---------- writes ----------

let session: { token: string; until: number } | null = null
let issuing: Promise<string> | null = null
async function sessionToken(): Promise<string> {
  if (session && session.until > Date.now() + 10 * 60e3) return session.token
  if (issuing) return issuing
  issuing = (async () => {
    const cli = cliPath()
    if (!cli) throw new Error('the `t3` command of T3 Code was not found (is T3 Code installed? T3BOT_T3_CLI can point at it)')
    const p = Bun.spawn([cli, 'auth', 'session', 'issue', '--ttl', '12h', '--label', 't3bot', '--json'], { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe' })
    // Stopped after 15 seconds. A child of the command can keep its pipes open after the kill, and every write to
    // T3 Code waits on this one promise: so it gives up by itself instead of waiting for the pipes to close.
    let giveUp: ReturnType<typeof setTimeout> | undefined
    const timer = setTimeout(() => { try { p.kill(9) } catch {} }, 15000)
    const done = await Promise.race([
      Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]),
      new Promise<null>((r) => { giveUp = setTimeout(() => r(null), 17000) }),
    ])
    clearTimeout(timer); clearTimeout(giveUp)
    if (!done) throw new Error('T3 Code did not issue a session in 15 seconds (is it starting up?)')
    const [out, err, code] = done
    const token = String(parse(out).token ?? '')
    if (code !== 0 || !token) throw new Error(`T3 Code did not issue a session (${(err || out).trim().slice(0, 200) || `exit ${code}`})`)
    session = { token, until: Date.now() + 11 * 3600e3 }
    return token
  })()
  try { return await issuing } finally { issuing = null }
}

type Result = { ok: boolean; value?: any; error?: string }

/** One request over the socket. `retry` is set when nothing reached T3 Code, so asking again cannot do it twice. */
async function once(tag: string, payload: unknown, firstChunk: boolean): Promise<Result & { retry?: boolean }> {
  const rt = runtime()
  if (!rt) return { ok: false, error: 'T3 Code is not running on this machine. Open it, then try again.' }
  let token: string
  try { token = await sessionToken() } catch (e: any) { return { ok: false, error: String(e?.message ?? e) } }
  return await new Promise((resolve) => {
    let sent = false, settled = false
    let ws: WebSocket
    const done = (r: Result & { retry?: boolean }) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { ws?.close() } catch {}
      resolve(r)
    }
    const timer = setTimeout(() => done({ ok: false, error: 'T3 Code did not answer in 20 seconds' }), 20000)
    try {
      ws = new WebSocket(`ws://127.0.0.1:${rt.port}/ws?orchestrationProtocol=2`, { headers: { Authorization: `Bearer ${token}` } } as any)
    } catch (e) { return done({ ok: false, error: `could not reach T3 Code: ${String(e).slice(0, 120)}` }) }
    ws.onerror = () => { session = null; done({ ok: false, error: 'could not reach T3 Code (is it running?)', retry: !sent }) }
    ws.onclose = () => done(sent ? { ok: false, error: 'T3 Code closed the connection before answering' }
                                 : { ok: false, error: 'could not reach T3 Code (is it running?)', retry: true })
    ws.onopen = () => {
      try { ws.send(JSON.stringify({ _tag: 'Request', id: '1', tag, payload, headers: [] })); sent = true }
      catch { done({ ok: false, error: 'could not reach T3 Code (is it running?)', retry: true }) }
    }
    ws.onmessage = (ev) => {
      let parsed: any
      try { parsed = JSON.parse(String(ev.data)) } catch { return }
      for (const m of Array.isArray(parsed) ? parsed : [parsed]) {
        if (!m || typeof m !== 'object') continue
        try {
          if (m._tag === 'Ping') ws.send(JSON.stringify({ _tag: 'Pong' }))
          else if (firstChunk && m._tag === 'Chunk' && m.requestId === '1') {
            ws.send(JSON.stringify({ _tag: 'Interrupt', requestId: '1', interruptors: [] }))
            done({ ok: true, value: m.values?.[0] })
          } else if (m._tag === 'Exit' && m.requestId === '1') {
            if (m.exit?._tag === 'Success') return done({ ok: true, value: m.exit.value })
            const error = JSON.stringify(m.exit ?? null).slice(0, 500)
            const auth = /unauthori[sz]ed|not authori[sz]ed|authorization|authentication/i.test(error)
            if (auth) session = null
            done({ ok: false, error, retry: auth })
          }
        } catch {}
      }
    }
  })
}

/** A request, asked a second time with a fresh session when the first never got through or was refused as unauthorized. */
async function call(tag: string, payload: unknown, firstChunk = false): Promise<Result> {
  if (READONLY) return { ok: false, error: 'read-only mode (T3BOT_READONLY=1): nothing is sent to T3 Code' }
  let r = await once(tag, payload, firstChunk)
  if (!r.ok && r.retry && runtime()) {
    session = null
    r = await once(tag, payload, firstChunk)
  }
  return r.ok ? { ok: true, value: r.value } : { ok: false, error: r.error }
}

export async function dispatch(command: Record<string, unknown>): Promise<{ ok: boolean; error?: string }> {
  const r = await call('orchestration.dispatchCommand', command)
  return r.ok ? { ok: true } : { ok: false, error: r.error }
}

/** `clientId` is the app's own id for this message: a retry with the same id is the same message to T3 Code. */
export async function sendMessage(threadId: string, text: string, clientId?: string) {
  const id = clientId && /^[A-Za-z0-9-]{8,64}$/.test(clientId) ? clientId.toLowerCase() : crypto.randomUUID()
  const mode = isActive(lastRunStatus(threadId)) ? { type: 'queue_after_active' } : { type: 'start_immediately' }
  return dispatch({
    type: 'message.dispatch', createdBy: 'user', creationSource: 'mobile',
    commandId: `t3bot:send:${id}`, messageId: `t3bot:${id}`, threadId, text, attachments: [], dispatchMode: mode,
  })
}

export async function answer(threadId: string, requestId: string, answers: Record<string, string | string[]>) {
  return dispatch({ type: 'runtime-request.respond', commandId: `t3bot:answer:${crypto.randomUUID()}`, threadId, requestId, answers })
}

export async function decide(threadId: string, requestId: string, decision: string) {
  return dispatch({ type: 'runtime-request.respond', commandId: `t3bot:decide:${crypto.randomUUID()}`, threadId, requestId, decision })
}

// ---------- generic RPC (scheduled tasks) ----------

/** One RPC call. A `*.subscribe` tag returns its first chunk (T3 Code 0.1.7 removed scheduledTasks.list). */
export const rpc = (tag: string, payload: unknown): Promise<{ ok: boolean; value?: any; error?: string }> =>
  call(tag, payload, tag.endsWith('.subscribe'))

export type Routine = { id: string; title: string; enabled: boolean; schedule: any; threadId: string | null; nextRunAt: string | null; lastRunAt: string | null; lastRunStatus: string | null; prompt: string }

export function routines(threadIds: string[]): Routine[] {
  if (!threadIds.length) return []
  let rows: any[] = []
  // An older T3 Code has no scheduled tasks table: that is no routines, not an error.
  try {
    rows = q<any>(`select task_id, title, prompt, enabled, schedule_json, thread_id, next_run_at, last_run_at, last_run_status
                     from scheduled_tasks where thread_id in (${threadIds.map(() => '?').join(',')}) order by title`, ...threadIds)
  } catch { return [] }
  return rows.map((r) => ({ id: r.task_id, title: String(r.title ?? ''), enabled: !!r.enabled, schedule: parse(r.schedule_json), threadId: r.thread_id,
    nextRunAt: r.next_run_at, lastRunAt: r.last_run_at, lastRunStatus: r.last_run_status, prompt: String(r.prompt ?? '') }))
}

/** The thread a routine posts into, or undefined when there is no such routine. */
export function routineThread(taskId: string): string | null | undefined {
  try {
    const r = q<any>(`select thread_id from scheduled_tasks where task_id = ?`, taskId)[0]
    return r ? r.thread_id ?? null : undefined
  } catch { return undefined }
}

export async function setRoutineEnabled(taskId: string, enabled: boolean) {
  let r: any
  try { r = q<any>(`select * from scheduled_tasks where task_id = ?`, taskId)[0] } catch { r = null }
  if (!r) return { ok: false, error: 'routine not found' }
  let input: any
  try {
    input = {
      id: r.task_id, requireExisting: true, title: r.title, prompt: r.prompt, enabled, schedule: JSON.parse(r.schedule_json),
      projectId: r.project_id, threadId: r.thread_id ?? null, workspaceStrategy: JSON.parse(r.workspace_strategy_json),
      modelSelection: JSON.parse(r.model_selection_json), runtimeMode: r.runtime_mode, interactionMode: r.interaction_mode,
    }
  } catch { return { ok: false, error: 'this routine is stored in a form T3 Bot cannot read' } }
  if (r.created_by) input.createdBy = r.created_by
  if (r.creation_source) input.creationSource = r.creation_source
  const res = await rpc('scheduledTasks.upsert', input)
  return res.ok ? { ok: true } : { ok: false, error: res.error }
}

// ---------- new threads (new bots and groups) ----------

/** `d` is the model, effort and runtime mode from the config's `defaults` (config.ts, threadDefaults). */
export async function createThread(projectId: string, title: string, firstMessage: string,
                                   d: { instanceId: string; model: string; effort: string; runtimeMode: string }) {
  const threadId = crypto.randomUUID()
  const create = await dispatch({
    type: 'thread.create', createdBy: 'user', creationSource: 'mobile', commandId: `t3bot:create:${threadId}`, threadId, projectId, title,
    modelSelection: { instanceId: d.instanceId, model: d.model, options: [{ id: 'effort', value: d.effort }] },
    runtimeMode: d.runtimeMode, interactionMode: 'default', branch: null, worktreePath: null,
  })
  if (!create.ok) return { ok: false, error: create.error }
  await dispatch({ type: 'thread.auto-settle.set', commandId: `t3bot:optout:${threadId}`, threadId, enabled: false })
  const sent = await sendMessage(threadId, firstMessage)
  return sent.ok ? { ok: true, threadId } : { ok: false, error: sent.error, threadId }
}

// ---------- bot thread hygiene ----------

/** Title and whether T3 may auto-settle it, for a thread. */
export function threadMeta(threadId: string): { title: string; autoSettleOff: boolean; settled: boolean; pinned: boolean } | null {
  const r = q<any>(`select title, payload_json from orchestration_v2_projection_threads where thread_id = ? and deleted_at is null`, threadId)[0]
  if (!r) return null
  let p: any = {}
  try { p = JSON.parse(r.payload_json) } catch {}
  return { title: r.title, autoSettleOff: !!p.autoSettleDisabledAt, settled: p.settledOverride === 'settled', pinned: !!p.pinnedAt }
}

export const rename = (threadId: string, title: string) =>
  dispatch({ type: 'thread.metadata.update', commandId: `t3bot:title:${crypto.randomUUID()}`, threadId, title })

export const keepUp = (threadId: string) =>
  dispatch({ type: 'thread.auto-settle.set', commandId: `t3bot:optout:${crypto.randomUUID()}`, threadId, enabled: false })

/** Runs started by T3 Bot's own notices to its bots (message ids `t3bot:rule:` or `t3bot:sys:`): never shown, never rung.
 *  Notices sent while the project was still called Crew keep their old `crew:` ids in T3 Code's store. */
export function systemRuns(threadId: string): Set<string> {
  return new Set(q<any>(`select distinct run_id from orchestration_v2_projection_messages
                         where thread_id = ? and (message_id like 't3bot:rule:%' or message_id like 't3bot:sys:%'
                           or message_id like 'crew:rule:%' or message_id like 'crew:sys:%')`, threadId)
    .map((r) => r.run_id).filter(Boolean))
}

export const settle = (threadId: string, runId: string) =>
  dispatch({ type: 'thread.settle', commandId: `t3bot:settle:${crypto.randomUUID()}`, threadId, expectedLatestRunId: runId })

export const unsettle = (threadId: string) =>
  dispatch({ type: 'thread.unsettle', commandId: `t3bot:unsettle:${crypto.randomUUID()}`, threadId, reason: 'user' })

export const unpin = (threadId: string) =>
  dispatch({ type: 'thread.unpin', commandId: `t3bot:unpin:${crypto.randomUUID()}`, threadId })

/** A message from T3 Bot itself (not the person): shown in the app as an automatic line. `kind` tags its run. */
export async function sendSystem(threadId: string, text: string, kind: 'brief' | 'sys' | 'rule') {
  const id = crypto.randomUUID()
  const mode = isActive(lastRunStatus(threadId)) ? { type: 'queue_after_active' } : { type: 'start_immediately' }
  return dispatch({ type: 'message.dispatch', createdBy: 'agent', creationSource: 'server', commandId: `t3bot:${kind}:${id}`,
    messageId: `t3bot:${kind}:${id}`, threadId, text, attachments: [], dispatchMode: mode })
}

export function runHas(threadId: string, runId: string, prefix: string): boolean {
  return !!q<any>(`select 1 from orchestration_v2_projection_messages where thread_id = ? and run_id = ? and message_id like ? limit 1`,
    threadId, runId, `${prefix}%`)[0]
}

/** Messages in these threads whose text contains q (case-insensitive), newest first. */
export function searchMessages(threadIds: string[], qText: string, limit = 40): (Msg & { threadId: string })[] {
  if (!threadIds.length || !qText.trim()) return []
  // % and _ are wildcards in LIKE: escaped, so a search for read_file or 50% finds exactly that.
  const like = `%${qText.replace(/[\\%_]/g, '\\$&')}%`
  return q<any>(`select message_id, thread_id, role, created_at, run_id, payload_json from orchestration_v2_projection_messages
                  where thread_id in (${threadIds.map(() => '?').join(',')}) and role in ('user','assistant')
                    and json_extract(payload_json, '$.text') like ? escape '\\'
                  order by created_at desc limit ?`, ...threadIds, like, limit)
    .map((r) => { const p = parse(r.payload_json); return { id: r.message_id, threadId: r.thread_id, role: r.role, text: String(p.text ?? ''), at: r.created_at, runId: r.run_id, createdBy: p.createdBy ?? '', streaming: false } })
}

/** True when the run was started by the person's own message (not by an automated thread, a schedule or T3 Bot). */
export function runStartedByUser(threadId: string, runId: string): boolean {
  const r = q<any>(`select payload_json from orchestration_v2_projection_messages where thread_id = ? and run_id = ? and role = 'user'
                    order by created_at limit 1`, threadId, runId)[0]
  if (!r) return false
  try { return JSON.parse(r.payload_json).createdBy === 'user' } catch { return false }
}

export const archive = (threadId: string) =>
  dispatch({ type: 'thread.archive', commandId: `t3bot:archive:${crypto.randomUUID()}`, threadId })

/**
 * What a working thread is doing right now, from its newest step: thinking, reading, running, writing, web,
 * delegating or asking. The app picks the face's animation from it.
 */
export function activity(threadId: string): string | null {
  const rows = q<any>(`select type, status, payload_json from orchestration_v2_projection_turn_items
                       where thread_id = ? order by updated_at desc limit 6`, threadId)
  const step = rows.find((r) => r.status === 'running' || r.status === 'waiting') ?? rows[0]
  if (!step) return null
  let p: any = {}
  try { p = JSON.parse(step.payload_json) } catch {}
  switch (step.type) {
    case 'reasoning': case 'assistant_message': return 'thinking'
    case 'file_change': return 'writing'
    case 'web_search': return 'web'
    case 'subagent': return 'delegating'
    case 'user_input_request': case 'approval_request': return 'asking'
    case 'command_execution': {
      const cmd = String(p.input ?? '').trim()
      if (/^(curl|wget)\b/.test(cmd)) return 'web'
      if (/^(cat|head|tail|grep|rg|ls|find|sed -n|wc|jq|less|stat|du|df|tree|git (log|show|diff|status)|sqlite3 -readonly|python3 -I -c)\b/.test(cmd)) return 'reading'
      return 'running'
    }
    case 'dynamic_tool': {
      const t = String(p.toolName ?? '')
      if (/^(Read|Grep|Glob|NotebookRead|LS)$/.test(t) || /thread_read|thread_list|thread_search|read_file|list_/.test(t)) return 'reading'
      if (/^(Edit|Write|MultiEdit|NotebookEdit)$/.test(t)) return 'writing'
      if (/^(WebSearch|WebFetch)$/.test(t) || /preview|chrome|browser|html_render/.test(t)) return 'web'
      if (/^(Agent|Task)$/.test(t) || /thread_send|thread_wait|delegate|thread_launch/.test(t)) return 'delegating'
      if (/AskUserQuestion/.test(t)) return 'asking'
      if (/^Bash$/.test(t)) return 'running'
      return 'thinking'
    }
  }
  return 'thinking'
}
