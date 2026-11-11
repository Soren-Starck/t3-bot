/**
 * The demo world: one invented indie developer (Sam) who ships a notes app called Paperkite with a small crew
 * of bots. Everything here is made up. No real people, customers or products.
 *
 * `seed(base)` builds the whole in-memory state with timestamps relative to `base` (the server's start, or the
 * moment of the last reset), so the same world comes back on every start.
 */

export type Phase = { activity: string; step: string; secs: number }
export type EntryImage = { path: string; alt: string }
export type Entry = {
  id: string; type: 'me' | 'agent' | 'auto'; text: string; at: string; steps: string[]
  working?: boolean; suggestions?: string[]; auto?: boolean; images?: EntryImage[]
}
export type Routine = {
  id: string; title: string; enabled: boolean; when: string
  nextRunAt: string | null; lastRunAt: string | null; lastRunStatus: string | null; own: boolean
}
export type RunInfo = { threadId: string; title: string; status: string; at: string; text: string }
export type Question = { id: string; question: string; header?: string; multiSelect: boolean; options: { label: string; description?: string }[] }
export type Action = { id: string; label: string; kind: 'done' | 'snooze' | 'handle' | 'message' | 'command'; style?: string; faceId?: boolean; message?: string; handler?: string }
export type Draft = { to?: string; text?: string; via?: string; subject?: string; event?: string; start?: string; end?: string; location?: string }
export type Card = {
  id: string; source: 'question' | 'desk' | 'note'; agent: string; rank: number
  title: string; detail?: string; why?: string; steps?: string; urgency?: string; customer?: boolean; minutes?: number
  desk?: string; deskName?: string; key?: string; at: string
  threadId?: string; threadTitle?: string; requestId?: string; requestKind?: string; questions?: Question[]
  kind?: string; link?: string; draft?: Draft
  fields?: { label: string; value: string }[]; checks?: { label: string; state: 'pass' | 'fail' | 'pending' }[]
  edit?: { label: string; text: string }; actions?: Action[]; ref?: string
}
/** A turn in progress: the phases it walks through, then the reply it posts. */
export type Run = {
  startedAt: number; at: string; workingId: string; phases: Phase[]
  reply: string; images?: EntryImage[]; auto?: boolean
  /** Stops after this many phases and waits for an answer (a pending question). */
  askAfter?: number
  /** Card to drop when the run ends (the bot dealt with it). */
  resolves?: string
}
export type Bot = {
  id: string; name: string; role: string; kind: 'bot' | 'group'; skin: string; hidden: boolean; members: string[]
  threadId: string; threadTitle: string
  /** Titles of its autopilot threads that are running right now (the "watching" mood). */
  watching: string[]
  failed: boolean
  entries: Entry[]; routines: Routine[]; runs: RunInfo[]
  run: Run | null
  /** Background work that keeps the bot busy when nobody talks to it (live mode only). */
  ambient: { prompt: string; phases: Phase[]; reply: string }[]
  ambientIndex: number; ambientAt: number
  sent: number
}
export type Note = { id: string; agent: string; kind: string; title: string; body: string | null; created_at: string; link: string | null; key: string | null }
export type Settings = {
  quiet: { enabled: boolean; from: string; to: string; alarms: boolean }
  brief: { enabled: boolean; at: string; agent: string }
  quickReplies: string[]
}
export type World = {
  base: number
  bots: Bot[]
  cards: Card[]
  snoozed: Map<string, number>
  /** Cards taken off the list, kept so an undo can bring them back. */
  removed: Map<string, Card>
  notes: Note[]
  settings: Settings
  phone: { at: string; calendar: any[]; contacts: any[] } | null
  devices: Map<string, string>
  live: Map<string, { token: string; startedAt: number }>
  uploads: Map<string, { bytes: Uint8Array; type: string }>
  seq: number
}

export const USER = 'Sam'
export const CHIEF = 'chief'
export const IMAGES = {
  speed: '/demo/assets/pricing-speed.png',
  preview: '/demo/assets/pricing-preview.png',
  revenue: '/demo/assets/revenue.png',
  revenueOctober: '/demo/assets/revenue-october.png',
}

const MIN = 60e3
const HOUR = 3600e3

export const DEFAULT_ACTIONS = (faceId = false): Action[] => [
  { id: 'handle', label: 'Handle it', kind: 'handle', style: 'primary', faceId },
  { id: 'done', label: 'Done', kind: 'done' },
  { id: 'snooze', label: 'Not now', kind: 'snooze' },
]
const TAIL: Action[] = [{ id: 'done', label: 'Done', kind: 'done' }, { id: 'snooze', label: 'Not now', kind: 'snooze' }]

export function seed(base: number): World {
  const at = (msAgo: number) => new Date(base - msAgo).toISOString()
  const later = (ms: number) => new Date(base + ms).toISOString()
  let n = 0
  const e = (bot: string, type: Entry['type'], msAgo: number, text: string, more: Partial<Entry> = {}): Entry =>
    ({ id: `e-${bot}-${++n}`, type, text, at: at(msAgo), steps: [], ...more })
  const bot = (b: Partial<Bot> & Pick<Bot, 'id' | 'name' | 'role' | 'skin'>): Bot => ({
    kind: 'bot', hidden: false, members: [], threadId: `demo-thread-${b.id}`, threadTitle: `%BOT ${b.name}`,
    watching: [], failed: false, entries: [], routines: [], runs: [], run: null,
    ambient: [], ambientIndex: 0, ambientAt: base + 30e3, sent: 0, ...b,
  })
  const routine = (id: string, title: string, when: string, own: boolean, next: number | null, last: number | null, status: string | null, enabled = true): Routine =>
    ({ id, title, enabled, when, own, nextRunAt: next === null ? null : later(next), lastRunAt: last === null ? null : at(last), lastRunStatus: status })

  // ---------- Chief ----------
  const chief = bot({
    id: 'chief', name: 'Chief', skin: '902',
    role: 'Plans the day, keeps the list of what needs you, and passes work to the right bot',
    watching: ['Docs autopilot'],
    entries: [
      e('chief', 'agent', 5.5 * HOUR, [
        '## Morning brief',
        'Good morning. Three things need you today, the rest is moving on its own.',
        '',
        '- **API** is waiting on one answer about rate limits before it can finish.',
        '- **Releases** has 2.4.1 ready and wants your go to ship it.',
        '- **Support** drafted a refund reply for a customer charged twice.',
        '',
        '| Yesterday | Count |',
        '|---|---|',
        '| New trials | 41 |',
        '| Paid | 6 |',
        '| Refunds | 1 |',
        '',
        'Overnight the crew closed 5 things alone. They are in [the digest](https://example.com/digest).',
      ].join('\n'), { steps: ['Read the needs list', 'Asked Releases, Support and Finance for their night', 'Read yesterday\'s numbers'] }),
      e('chief', 'me', 95 * MIN, 'What should I do first today?'),
      e('chief', 'agent', 94 * MIN, [
        'In this order:',
        '',
        '1. Answer **API** on the rate limit. It unblocks the launch branch and takes one tap.',
        '2. Read the crash alarm from **Releases**, then approve 2.4.1 if the numbers look right.',
        '3. Send the refund reply **Support** drafted. The customer has waited since last night.',
        '',
        'Everything else can wait until the afternoon.',
      ].join('\n'), {
        steps: ['Read the needs list', 'Checked what blocks other work'],
        suggestions: ['Open the API question', 'Show me the crash numbers', 'What can wait?'],
      }),
    ],
    routines: [
      routine('r-chief-brief', 'Morning brief', 'Every day at 08:00', true, 18.5 * HOUR, 5.5 * HOUR, 'completed'),
      routine('r-chief-week', 'Weekly review', 'Mon at 09:00', true, 3 * 24 * HOUR, 4 * 24 * HOUR, 'completed'),
      routine('r-chief-docs', 'Docs autopilot', 'Every 2 h', false, 90 * MIN, 30 * MIN, 'running'),
    ],
    runs: [
      { threadId: 'demo-thread-docs', title: 'Docs autopilot', status: 'running', at: at(30 * MIN), text: 'Rewriting the sync troubleshooting page from the last 20 support threads. Two sections done, three to go.' },
      { threadId: 'demo-thread-nightly', title: 'Nightly review', status: 'completed', at: at(9.5 * HOUR), text: 'All five bots ran. One failure: Finance could not export October revenue (expired API key). Nothing else needs you.' },
    ],
  })

  // ---------- Website (working) ----------
  const web = bot({
    id: 'web', name: 'Website', skin: '102',
    role: 'Owns the marketing site: pages, speed, SEO and the pricing tests',
    entries: [
      e('web', 'me', 26.5 * HOUR, 'Can you make the pricing page load faster?'),
      e('web', 'agent', 26.4 * HOUR, [
        'Done, and it is live. The hero image was the problem: 1.8 MB, loaded before anything else.',
        '',
        '| Metric | Before | After |',
        '|---|---|---|',
        '| Largest paint | 3.4 s | 1.2 s |',
        '| Page weight | 2.6 MB | 610 KB |',
        '| Speed score | 61 | 97 |',
        '',
        'The change, in `app/pricing/page.tsx`:',
        '',
        '```tsx',
        '<Image',
        '  src="/hero.avif"',
        '  width={1200}',
        '  height={630}',
        '  priority',
        '  sizes="(max-width: 768px) 100vw, 1200px"',
        '/>',
        '```',
        '',
        'I also moved the testimonials below the fold so they load on scroll.',
      ].join('\n'), {
        steps: ['Read app/pricing/page.tsx', 'Ran a speed audit on the live page', 'Converted hero.png to AVIF', 'Ran bun test and the build', 'Deployed and checked the live page'],
        images: [{ path: IMAGES.speed, alt: 'Pricing page speed, before and after' }],
      }),
      e('web', 'auto', 7.5 * HOUR, 'Scheduled run: check the site for broken links'),
      e('web', 'agent', 7.4 * HOUR, 'Checked 214 links. Four on the docs pointed at the old changelog path. Fixed and deployed.', { auto: true, steps: ['Crawled the sitemap', 'Fixed 4 links in docs/'] }),
      e('web', 'me', 4 * MIN, 'Try a shorter headline on the pricing page and show me a preview before it goes live'),
    ],
    routines: [
      routine('r-web-links', 'Check broken links', 'Every day at 06:30', true, 16.5 * HOUR, 7.5 * HOUR, 'completed'),
      routine('r-web-seo', 'Page of the day', 'Every day at 02:00', false, 12 * HOUR, 12 * HOUR, 'completed', false),
    ],
    run: {
      startedAt: base - 14e3, at: at(4 * MIN - 2e3), workingId: 'e-web-working',
      phases: [
        { activity: 'reading', step: 'Read app/pricing/page.tsx', secs: 5 },
        { activity: 'thinking', step: 'Wrote three shorter headlines', secs: 5 },
        { activity: 'writing', step: 'Edited the hero copy on a preview branch', secs: 12 },
        { activity: 'running', step: 'Ran bun run build', secs: 10 },
        { activity: 'web', step: 'Opened the preview and took a screenshot', secs: 8 },
      ],
      reply: [
        'Preview is up. I went with **"Notes that find themselves"** over the old two-line headline.',
        '',
        '- Headline: 9 words down to 4',
        '- The price sits above the fold on a phone now',
        '- Nothing is live yet, this is the preview branch only',
        '',
        'Look at it here: [pricing preview](https://example.com/preview/pricing)',
        '',
        '» Ship it · Try another headline · Keep the old one',
      ].join('\n'),
      images: [{ path: IMAGES.preview, alt: 'Pricing page preview with the shorter headline' }],
    },
    ambient: [
      {
        prompt: 'Scheduled run: check the preview deploys',
        phases: [
          { activity: 'reading', step: 'Read the open preview branches', secs: 7 },
          { activity: 'running', step: 'Ran bun run build on pricing-headline', secs: 12 },
          { activity: 'web', step: 'Opened the preview on a phone viewport', secs: 9 },
          { activity: 'thinking', step: 'Compared it with production', secs: 6 },
          { activity: 'writing', step: 'Wrote the summary', secs: 6 },
        ],
        reply: 'Both preview branches build and render. Nothing to fix.',
      },
      {
        prompt: 'Scheduled run: look at search traffic for the pricing page',
        phases: [
          { activity: 'web', step: 'Read the search report for the last 7 days', secs: 9 },
          { activity: 'thinking', step: 'Picked the three queries that moved', secs: 7 },
          { activity: 'writing', step: 'Updated the page title and description', secs: 11 },
          { activity: 'running', step: 'Ran the build and the link check', secs: 10 },
        ],
        reply: 'Clicks on "notes app pricing" are up 18% week over week. I tightened the page title to match that query.',
      },
    ],
  })

  // ---------- API (waiting on a question) ----------
  const api = bot({
    id: 'api', name: 'API', skin: '103',
    role: 'Builds and watches the backend: endpoints, sync, uptime',
    entries: [
      e('api', 'me', 25 * HOUR, 'How do I test the new export endpoint?'),
      e('api', 'agent', 24.9 * HOUR, [
        'It is on staging. Call it with a personal token:',
        '',
        '```bash',
        'curl -s https://example.com/v2/export \\',
        '  -H "Authorization: Bearer $PAPERKITE_TOKEN" \\',
        '  -d \'{"format": "markdown", "since": "2026-10-01"}\'',
        '```',
        '',
        'It answers with a job id. Poll `/v2/export/<id>` until `status` is `ready`, then download `url`.',
        '',
        '| Format | Limit | Typical time |',
        '|---|---|---|',
        '| markdown | 10,000 notes | 4 s |',
        '| json | 50,000 notes | 9 s |',
        '| pdf | 500 notes | 40 s |',
      ].join('\n'), { steps: ['Read src/routes/export.ts', 'Ran the endpoint against staging'], suggestions: ['Add a CSV format', 'Ship it to production'] }),
      e('api', 'me', 12 * MIN, 'Add rate limiting to the public API before the launch'),
    ],
    routines: [
      routine('r-api-uptime', 'Uptime check', 'Every 30 min', true, 12 * MIN, 18 * MIN, 'completed'),
      routine('r-api-deps', 'Dependency updates', 'Mon at 07:00', true, 3 * 24 * HOUR, 4 * 24 * HOUR, 'completed'),
    ],
    run: {
      startedAt: base - 10 * MIN, at: at(12 * MIN - 3e3), workingId: 'e-api-working', askAfter: 3,
      phases: [
        { activity: 'reading', step: 'Read src/middleware/limits.ts and the gateway config', secs: 6 },
        { activity: 'running', step: 'Ran bun test api (212 pass)', secs: 8 },
        { activity: 'thinking', step: 'Measured real traffic: the busiest client makes 22 requests a minute', secs: 6 },
        { activity: 'writing', step: 'Wrote the limiter and its tests', secs: 3 },
        { activity: 'running', step: 'Ran bun test api (219 pass)', secs: 3 },
      ],
      reply: 'Rate limiting is in on the launch branch.',
    },
  })

  // ---------- Releases (working) ----------
  const rel = bot({
    id: 'releases', name: 'Releases', skin: '304',
    role: 'Builds, signs and ships the Mac and Windows apps, and watches crashes',
    entries: [
      e('releases', 'agent', 19 * HOUR, [
        'Nightly build finished.',
        '',
        '| Platform | Build | Tests | Size |',
        '|---|---|---|---|',
        '| macOS | 411 | 1,204 pass | 18.1 MB |',
        '| Windows | 411 | 1,187 pass | 24.6 MB |',
        '',
        'Both are signed and waiting on the beta channel.',
      ].join('\n'), { auto: true, steps: ['Ran the Mac build', 'Ran the Windows build', 'Signed and notarized both'] }),
      e('releases', 'me', 5 * HOUR, 'Why did crashes go up on 2.4.0?'),
      e('releases', 'agent', 4.9 * HOUR, [
        'One bug: the sync queue reads a note that was deleted on another device. It only hits people with two Macs.',
        '',
        '```swift',
        'guard let note = store.note(id: change.noteID) else {',
        '    queue.drop(change)   // was: fatalError("missing note")',
        '    return',
        '}',
        '```',
        '',
        'The fix is in 2.4.1, built and tested. It needs your go to ship.',
      ].join('\n'), { steps: ['Read 38 crash reports', 'Found the shared stack in SyncQueue.apply', 'Wrote the fix and a test', 'Built 2.4.1 (412)'], suggestions: ['Ship 2.4.1', 'Show me the crash reports'] }),
      e('releases', 'me', 6 * MIN, 'Start the 2.5 beta build for Mac and Windows'),
    ],
    routines: [
      routine('r-rel-nightly', 'Nightly build', 'Every day at 01:30', true, 12 * HOUR, 12 * HOUR, 'completed'),
      routine('r-rel-review', 'Check store review status', 'Every 2 h', true, 50 * MIN, 70 * MIN, 'completed'),
    ],
    run: {
      startedAt: base - 20e3, at: at(6 * MIN - 2e3), workingId: 'e-releases-working',
      phases: [
        { activity: 'reading', step: 'Read CHANGELOG.md and the 2.5 milestone', secs: 6 },
        { activity: 'running', step: 'Ran bun run build:mac (build 420)', secs: 16 },
        { activity: 'running', step: 'Ran the Mac test suite: 1,231 pass', secs: 10 },
        { activity: 'delegating', step: 'Asked the Windows machine to build 420', secs: 12 },
        { activity: 'running', step: 'Signed and notarized the Mac build', secs: 10 },
        { activity: 'writing', step: 'Wrote the beta release notes', secs: 6 },
      ],
      reply: [
        '2.5 beta (build 420) is ready on both platforms.',
        '',
        '| Platform | Tests | Signed |',
        '|---|---|---|',
        '| macOS | 1,231 pass | yes |',
        '| Windows | 1,209 pass | yes |',
        '',
        'It is not published. Say the word and it goes to the 180 beta testers.',
        '',
        '» Send it to testers · Show me the notes · Wait for 2.4.1 first',
      ].join('\n'),
    },
    ambient: [
      {
        prompt: 'Scheduled run: check crash reports for the last hour',
        phases: [
          { activity: 'web', step: 'Pulled the last hour of crash reports', secs: 8 },
          { activity: 'reading', step: 'Grouped 6 reports by stack', secs: 8 },
          { activity: 'thinking', step: 'Compared with the 2.4.0 baseline', secs: 7 },
          { activity: 'writing', step: 'Updated the crash board', secs: 6 },
        ],
        reply: 'Six crashes in the last hour, all the known sync queue bug on 2.4.0. Nothing new.',
      },
      {
        prompt: 'Scheduled run: check the store review status',
        phases: [
          { activity: 'web', step: 'Read the review status for 2.4.1', secs: 9 },
          { activity: 'running', step: 'Verified the uploaded build hash', secs: 9 },
          { activity: 'writing', step: 'Noted the status on the release board', secs: 6 },
        ],
        reply: '2.4.1 is still "Waiting for review". Average wait this month: 9 hours.',
      },
    ],
  })

  // ---------- Support (waiting: a reply to approve) ----------
  const support = bot({
    id: 'support', name: 'Support', skin: '305',
    role: 'Reads the inbox, drafts replies for you to send, and files bugs with the right bot',
    entries: [
      e('support', 'auto', 4.5 * HOUR, 'Scheduled run: inbox check'),
      e('support', 'agent', 4.5 * HOUR - 40e3, 'Two new mails. Both are licence questions the saved replies cover. Drafted, nothing urgent.', { auto: true, steps: ['Read 2 new mails'] }),
      e('support', 'auto', 4 * HOUR, 'Scheduled run: inbox check'),
      e('support', 'agent', 4 * HOUR - 35e3, 'Nothing new.', { auto: true }),
      e('support', 'auto', 3.5 * HOUR, 'Scheduled run: inbox check'),
      e('support', 'agent', 3.5 * HOUR - 50e3, 'One new mail: Mara L. was charged twice for the yearly plan. I checked the payments, she is right. Draft ready for you.', { auto: true, steps: ['Read 1 new mail', 'Looked up both charges'] }),
      e('support', 'me', 2.5 * HOUR, 'Anything from customers this morning?'),
      e('support', 'agent', 2.5 * HOUR - 50e3, [
        'Three conversations are open:',
        '',
        '- **Mara L.** was charged twice for the yearly plan on 3 Nov. The refund reply is drafted and waits for you.',
        '- **Jonas K.** cannot activate on his second Mac. His licence allows it, the seat counter is stuck. Only you can reset it.',
        '- **Priya S.** asked for a student discount. I answered with the saved reply and the form link.',
        '',
        'Median first answer this week: 2 h 10 min.',
      ].join('\n'), { steps: ['Read the inbox', 'Matched each sender to their purchase'], suggestions: ['Show me the refund reply', 'Reset the seat for Jonas', 'Who is still waiting?'] }),
    ],
    routines: [
      routine('r-sup-inbox', 'Inbox check', 'Every 30 min', true, 20 * MIN, 10 * MIN, 'completed'),
      routine('r-sup-week', 'Weekly support summary', 'Fri at 17:00', true, 2 * 24 * HOUR, 5 * 24 * HOUR, 'completed'),
    ],
  })

  // ---------- Finance (failed) ----------
  const finance = bot({
    id: 'finance', name: 'Finance', skin: '306', failed: true,
    role: 'Tracks revenue, costs and invoices, and warns you before a bill surprises you',
    entries: [
      e('finance', 'me', 28 * HOUR, 'How did September go?'),
      e('finance', 'agent', 27.9 * HOUR, [
        'September closed at **$6,840**, up 12% on August.',
        '',
        '| Plan | Customers | Revenue |',
        '|---|---|---|',
        '| Monthly | 212 | $1,908 |',
        '| Yearly | 96 | $4,608 |',
        '| Team | 3 | $324 |',
        '',
        'Costs were $412 (hosting $180, mail $29, tools $203), so about **$6,430** stays.',
      ].join('\n'), { steps: ['Read the payments export', 'Read the hosting and tool invoices'], images: [{ path: IMAGES.revenue, alt: 'Monthly revenue, last six months' }] }),
      e('finance', 'me', 3.5 * HOUR, 'Export October revenue by plan'),
      e('finance', 'agent', 3.5 * HOUR - 70e3, [
        'The export stopped halfway: the payments API answered **401**. The restricted key I use expired on 1 Nov.',
        '',
        'I kept the partial file (1 to 19 Oct). Give me a new read-only key and I will run it again from the start.',
      ].join('\n'), { steps: ['Started the October export', 'Fetched 1 to 19 Oct', 'Request failed: 401 from the payments API'], suggestions: ['How do I make the key?', 'Use the partial file for now'] }),
    ],
    routines: [
      routine('r-fin-daily', 'Daily revenue snapshot', 'Every day at 07:00', true, 17.5 * HOUR, 6.5 * HOUR, 'failed'),
      routine('r-fin-bills', 'Bill watch', 'Every day at 09:00', true, 19.5 * HOUR, 4.5 * HOUR, 'completed'),
    ],
  })

  // ---------- Launch crew (group) ----------
  const crew = bot({
    id: 'launch-crew', name: 'Launch crew', kind: 'group', skin: '706', members: ['web', 'api', 'releases'],
    role: 'Group: Website, API, Releases', threadTitle: '%BOT Group: Launch crew',
    entries: [
      e('launch-crew', 'me', 20 * HOUR, 'Are we ready to launch 2.5 on Thursday?'),
      e('launch-crew', 'agent', 20 * HOUR - 80e3, [
        '**Website:** The 2.5 page and the changelog are written and sit on a preview branch. I need the final screenshots from Releases, then it is one deploy.',
        '',
        '**API:** Sync for shared folders is live behind a flag. The one open item is rate limiting on the public API, and I am on it.',
        '',
        '**Releases:** The Mac build is green. Windows fails one test on long paths. I expect both ready on Wednesday, which leaves a day of beta.',
      ].join('\n'), { steps: ['Website checked its preview branch', 'API read the launch checklist', 'Releases read the build board'], suggestions: ['What could slip?', 'Plan the launch day', 'Move it to Friday'] }),
    ],
  })

  // ---------- Lab (hidden) ----------
  const lab = bot({
    id: 'lab', name: 'Lab', skin: '806', hidden: true,
    role: 'Tries risky ideas on a branch so the main bots stay clean',
    entries: [
      e('lab', 'me', 3 * 24 * HOUR, 'Could search work fully offline?'),
      e('lab', 'agent', 3 * 24 * HOUR - 4 * MIN, 'Yes for up to about 20,000 notes. A local index adds 6 MB and answers in under 30 ms on a three year old phone. The prototype is on the branch `lab/offline-search`.', { steps: ['Built a local index prototype', 'Measured it on 5,000, 20,000 and 80,000 notes'], suggestions: ['Show me the numbers', 'Hand it to API'] }),
    ],
  })

  // ---------- what needs Sam ----------
  const cards: Card[] = [
    {
      id: 'req:demo-q-api', source: 'question', agent: 'api', rank: 0,
      title: 'Which rate limit should the public API launch with?', detail: '2 questions',
      at: at(10 * MIN), threadId: api.threadId, threadTitle: api.threadTitle, requestId: 'demo-q-api', requestKind: 'user_input',
      questions: [
        {
          id: 'limit', header: 'Rate limit', question: 'Which rate limit should the public API launch with?', multiSelect: false,
          options: [
            { label: '60 a minute (recommended)', description: 'Almost three times the busiest client today. Easy to raise later.' },
            { label: '120 a minute', description: 'Room for sync-heavy integrations, twice the load on a bad day.' },
            { label: 'No limit yet', description: 'Launch without one and add it when someone abuses it.' },
          ],
        },
        {
          id: 'scope', header: 'Scope', question: 'Where should it apply?', multiSelect: true,
          options: [
            { label: 'Personal tokens', description: 'Scripts and shortcuts people write for themselves.' },
            { label: 'Integrations', description: 'Third-party apps with their own keys.' },
            { label: 'The web app', description: 'Our own client. It rarely goes over 10 a minute.' },
          ],
        },
      ],
    },
    {
      id: 'req:demo-cmd-web', source: 'question', agent: 'web', rank: 0,
      title: 'Put the new pricing page live',
      detail: 'bun run deploy --prod --only pricing',
      at: at(26 * MIN), threadId: 'demo-thread-web-deploys', threadTitle: 'Website deploys', requestId: 'demo-cmd-web', requestKind: 'command', questions: [],
    },
    {
      id: 'note:alarm-crash', source: 'note', agent: 'releases', rank: 0, kind: 'alarm',
      title: 'Crash rate doubled on 2.4.0',
      detail: 'Crash-free sessions fell from **99.6%** to **98.1%** since yesterday 18:00. Almost every report is the sync queue on Macs signed in on two devices. The fix is built as 2.4.1.',
      link: 'https://example.com/crashes/2.4.0', key: 'crash-2.4.0', at: at(5.2 * HOUR), actions: DEFAULT_ACTIONS(),
    },
    {
      id: 'note:approve-ship', source: 'note', agent: 'releases', rank: 1, kind: 'approve',
      title: 'Ship 2.4.1 to everyone?',
      detail: 'One fix: the sync queue no longer crashes on a note deleted from another device. 40 beta testers ran it for 4 hours with no crash.',
      at: at(4.8 * HOUR), key: 'ship-2.4.1',
      fields: [
        { label: 'Version', value: '2.4.1 (412)' },
        { label: 'Reaches', value: '3,180 active installs' },
        { label: 'Download', value: '18.2 MB' },
      ],
      checks: [
        { label: 'Tests: 1,205 pass', state: 'pass' },
        { label: 'Signed and notarized', state: 'pass' },
        { label: 'Windows build', state: 'pending' },
        { label: 'Release notes translated', state: 'fail' },
      ],
      edit: { label: 'Release notes', text: 'Fixed a crash when a note was deleted on another device while this one was syncing.\nSync is a little faster on large libraries.' },
      actions: [
        { id: 'ship', label: 'Ship to everyone', kind: 'message', style: 'primary', faceId: true, message: 'Publish 2.4.1 to the stable channel with these release notes.' },
        { id: 'beta', label: 'Keep it in beta one more day', kind: 'message', style: 'plain', message: 'Leave 2.4.1 on the beta channel and ask again tomorrow.' },
        { id: 'cancel', label: 'Cancel this release', kind: 'message', style: 'destructive', message: 'Pull 2.4.1 and keep 2.4.0 as the current version.' },
        ...TAIL,
      ],
    },
    {
      id: 'note:approve-reply', source: 'note', agent: 'support', rank: 1, kind: 'approve',
      title: 'Send the refund reply to Mara L.?',
      detail: 'She was charged twice for the yearly plan on 3 Nov. Both charges are in the payments dashboard. I can refund the second one when you send this.',
      at: at(3.4 * HOUR), key: 'refund-mara',
      fields: [
        { label: 'Customer', value: 'Mara L., since March' },
        { label: 'Charged', value: '2 x $48.00 on 3 Nov' },
        { label: 'Refund', value: '$48.00 to the same card' },
      ],
      edit: { label: 'Reply', text: 'Hi Mara,\n\nYou are right, you were charged twice. That was a bug on our checkout, not something you did. I refunded the second $48 just now. It shows on your card in 3 to 5 days.\n\nSorry for the trouble, and thanks for telling me.\n\nSam' },
      actions: [
        { id: 'send', label: 'Send and refund', kind: 'message', style: 'primary', message: 'Send this reply and refund the second charge.' },
        { id: 'shorter', label: 'Make it shorter', kind: 'message', style: 'plain', message: 'Rewrite the reply in three lines and show it to me again.' },
        ...TAIL,
      ],
    },
    {
      id: 'desk:licence-seat', source: 'desk', agent: 'support', rank: 1, urgency: 'now', customer: true, minutes: 5,
      title: 'Reset the licence seat for Jonas K.',
      detail: 'He moved to a new Mac and the old one still holds his second seat. He wrote twice.',
      why: 'Seat resets change what a customer paid for, so they stay with you.',
      steps: '1. Open the licence admin\n2. Search for jonas.k@example.com\n3. Release the seat named "MacBook Air (old)"',
      desk: 'support', deskName: 'Support desk', link: 'https://example.com/admin/licences', at: at(7 * HOUR), actions: DEFAULT_ACTIONS(),
    },
    {
      id: 'note:draft-mail', source: 'note', agent: 'support', rank: 1, kind: 'draft',
      title: 'Mail to Priya S.: student discount',
      detail: 'She sent her student card. The code below gives 50% for a year.',
      at: at(2.2 * HOUR),
      draft: { via: 'mail', to: 'priya.s@example.com', subject: 'Your Paperkite student discount', text: 'Hi Priya,\n\nThanks for sending your student card. Here is your code: STUDENT-7Q4M. It takes 50% off the yearly plan for one year.\n\nGood luck with the thesis,\nSam' },
    },
    {
      id: 'note:draft-text', source: 'note', agent: 'api', rank: 1, kind: 'draft',
      title: 'Text to Dana: review tonight?',
      detail: 'Dana reviewed the last gateway change. The rate limit pull request is small, about 120 lines.',
      at: at(8 * MIN),
      draft: { via: 'message', to: '+1 555 0134', text: 'Hi Dana, could you look at the rate limit pull request tonight? It is small and it is the last thing before Thursday. Thanks!' },
    },
    {
      id: 'note:draft-event', source: 'note', agent: 'releases', rank: 1, kind: 'draft',
      title: 'Add to calendar: launch check, Thursday',
      detail: 'Thirty minutes before 2.5 goes out, to walk the checklist together.',
      at: at(110 * MIN),
      draft: { event: 'Paperkite 2.5 launch check', start: later(2 * 24 * HOUR + 3 * HOUR), end: later(2 * 24 * HOUR + 3.5 * HOUR), location: 'Video call' },
    },
    {
      id: 'note:do-launch-date', source: 'note', agent: 'chief', rank: 2, kind: 'do',
      title: 'Pick the launch day for 2.5',
      detail: 'Thursday works if Windows is green by Wednesday noon. Friday is safe but lands before a weekend with nobody watching.',
      at: at(20 * HOUR), key: 'launch-day', actions: DEFAULT_ACTIONS(),
    },
    {
      id: 'note:do-api-key', source: 'note', agent: 'finance', rank: 2, kind: 'do',
      title: 'Make a new read-only payments key',
      detail: 'The old one expired on 1 Nov and the October export fails without it. Restricted key, read access to charges and invoices only.',
      link: 'https://example.com/payments/api-keys', at: at(3.4 * HOUR), key: 'payments-key', actions: DEFAULT_ACTIONS(),
    },
    {
      id: 'desk:vat-return', source: 'desk', agent: 'finance', rank: 3, urgency: 'week', minutes: 20,
      title: 'File the Q3 VAT return',
      detail: 'Due on the 20th. The numbers are prepared in the shared sheet.',
      why: 'Filing needs your login and your signature.',
      steps: '1. Open the tax portal\n2. Copy the three totals from the sheet\n3. Submit and save the receipt',
      desk: 'admin', deskName: 'Admin', at: at(2 * 24 * HOUR), actions: DEFAULT_ACTIONS(),
    },
    {
      id: 'desk:domain', source: 'desk', agent: 'chief', rank: 4, urgency: 'later', minutes: 3,
      title: 'Renew the paperkite.example domain',
      detail: 'Expires in 41 days. Auto-renew is off because the card on file changed.',
      why: 'The registrar asks for your password and a code from your phone.',
      desk: 'admin', deskName: 'Admin', link: 'https://example.com/registrar', at: at(5 * 24 * HOUR), actions: DEFAULT_ACTIONS(),
    },
    {
      id: 'note:snoozed-price', source: 'note', agent: 'finance', rank: 2, kind: 'do',
      title: 'Decide on the yearly plan price',
      detail: 'Yearly at $48 converts 31% of trials. A test at $58 would need about three weeks to read.',
      at: at(30 * HOUR), key: 'yearly-price', actions: DEFAULT_ACTIONS(),
    },
  ]

  const note = (id: string, agent: string, msAgo: number, title: string, body: string | null): Note =>
    ({ id, agent, kind: 'know', title, body, created_at: at(msAgo), link: null, key: null })
  const notes: Note[] = [
    note('know-links', 'web', 7.4 * HOUR, 'Fixed 4 broken links on the docs', 'They pointed at the old changelog path.'),
    note('know-licence', 'support', 4.4 * HOUR, 'Answered 2 licence questions', 'Both with the saved reply. Nobody is waiting.'),
    note('know-nightly', 'releases', 12 * HOUR, 'Nightly build passed on Mac and Windows', 'Build 411, 2,391 tests.'),
    note('know-uptime', 'api', 2 * HOUR, 'Uptime 100% over the last 24 hours', 'Slowest endpoint: export, 380 ms at the 95th percentile.'),
    note('know-bill', 'finance', 4.5 * HOUR, 'Hosting bill arrived: $180', 'Same as last month, nothing to do.'),
  ]

  return {
    base,
    bots: [chief, web, api, rel, support, finance, crew, lab],
    cards,
    snoozed: new Map([['note:snoozed-price', base + 3 * HOUR]]),
    removed: new Map(),
    notes,
    settings: {
      quiet: { enabled: true, from: '23:00', to: '08:00', alarms: true },
      brief: { enabled: true, at: 'quiet-end', agent: CHIEF },
      quickReplies: ['Yes, go ahead', 'Show me first', 'Not now'],
    },
    phone: null,
    devices: new Map(),
    live: new Map(),
    uploads: new Map(),
    seq: 0,
  }
}
