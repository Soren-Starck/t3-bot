/**
 * What the demo bots say. No model runs here: each bot has a few scripted answers, picked by keyword and then
 * in rotation, with the steps it "took" on the way. A reply may end with a line of quick replies ("» A · B").
 */
import { IMAGES, type Bot, type EntryImage, type Phase } from './demo-world'

export type Script = { phases: Phase[]; reply: string; images?: EntryImage[] }
type Line = { match?: RegExp; phases: [string, string][]; reply: string; images?: EntryImage[] }

const P = (list: [string, string][], secs = 2): Phase[] => list.map(([activity, step]) => ({ activity, step, secs }))

const LINES: Record<string, Line[]> = {
  chief: [
    {
      match: /crash|number/i,
      phases: [['delegating', 'Asked Releases for the crash board'], ['reading', 'Read the last 24 hours of reports'], ['writing', 'Summed it up']],
      reply: 'Crash-free sessions on 2.4.0 are at **98.1%**, down from 99.6%. 38 reports, one cause, all on Macs with two devices signed in.\n\nReleases has the fix built as 2.4.1. It is the second card on your list.\n\n» Open the 2.4.1 card · Who is affected? · Thanks',
    },
    {
      match: /wait|later|snooze/i,
      phases: [['reading', 'Read the needs list'], ['thinking', 'Sorted it by what blocks other work']],
      reply: 'These can wait until next week without hurting anything:\n\n- The Q3 VAT return (due on the 20th)\n- The domain renewal (41 days left)\n- The launch day decision, as long as you pick by Wednesday noon\n\n» Snooze them for me · Remind me Wednesday · Ok',
    },
    {
      match: /api|question|rate/i,
      phases: [['reading', 'Read the API thread'], ['thinking', 'Checked what the answer unblocks']],
      reply: 'API asks which rate limit to launch with. Its measurement: the busiest client makes 22 requests a minute, so 60 leaves room and is easy to raise.\n\nThe question is at the top of your list. One tap answers it.\n\n» Go with 60 · Why not 120? · Let API decide',
    },
    {
      match: /plan|today|first|brief/i,
      phases: [['reading', 'Read the needs list'], ['delegating', 'Asked each bot what it is on'], ['writing', 'Wrote the plan']],
      reply: '## Plan for today\n\n1. Answer the rate limit question (1 min)\n2. Approve 2.4.1 after reading the crash alarm (3 min)\n3. Send the refund reply (1 min)\n4. Make the new payments key so Finance can finish October (5 min)\n\nThat is about ten minutes of you. The bots carry the rest.\n\n» Start with number 1 · Move 4 to tomorrow · Looks good',
    },
    {
      phases: [['thinking', 'Worked out which bot this belongs to'], ['delegating', 'Passed it on with the context'], ['writing', 'Noted it on the list']],
      reply: 'On it. I passed this to the bot that owns it and I will tell you when there is something to look at.\n\n» Which bot? · Tell me when it is done · Cancel that',
    },
    {
      phases: [['reading', 'Read the last day of bot activity'], ['thinking', 'Looked for anything stuck']],
      reply: 'Nothing is stuck. Website and Releases are working, API waits on your answer, and Finance needs a new key before it can finish.\n\n» Show me what needs me · Ok',
    },
  ],
  web: [
    {
      match: /ship|live|deploy/i,
      phases: [['running', 'Ran bun run build'], ['running', 'Deployed the pricing page'], ['web', 'Checked the live page on phone and desktop']],
      reply: 'Live. The pricing page now opens with **"Notes that find themselves"**.\n\n- Build: 41 s, no warnings\n- Largest paint on a phone: 1.1 s\n- I will compare trial starts against last week on Monday\n\n[Open the page](https://example.com/pricing)\n\n» Thanks · Roll it back · Test a second headline',
      images: [{ path: IMAGES.preview, alt: 'The pricing page, live' }],
    },
    {
      match: /headline|another|copy/i,
      phases: [['thinking', 'Wrote five more headlines'], ['writing', 'Put the best two on the preview branch'], ['web', 'Took a screenshot of each']],
      reply: 'Two more to choose from:\n\n1. **"Write it once. Find it forever."**\n2. **"Your notes, already organized."**\n\nThe first reads better on a phone, the second matches what people type into search.\n\n» Use the first · Use the second · Keep the current one',
    },
    {
      match: /old|keep|roll/i,
      phases: [['running', 'Reverted the preview branch'], ['web', 'Checked the page']],
      reply: 'Kept the old headline. The preview branch is closed and nothing changed on the live site.\n\n» Ok · Try again next week',
    },
    {
      match: /speed|fast|slow|seo|search/i,
      phases: [['web', 'Ran a speed audit on the five busiest pages'], ['reading', 'Read the results'], ['writing', 'Wrote the summary']],
      reply: 'The five busiest pages, on a mid-range phone:\n\n| Page | Paint | Score |\n|---|---|---|\n| Home | 1.0 s | 98 |\n| Pricing | 1.2 s | 97 |\n| Download | 0.9 s | 99 |\n| Docs | 1.6 s | 91 |\n| Changelog | 2.3 s | 78 |\n\nThe changelog is the slow one: it loads every release at once. I can paginate it.\n\n» Paginate it · Leave it',
      images: [{ path: IMAGES.speed, alt: 'Speed audit' }],
    },
    {
      phases: [['reading', 'Read the page and its components'], ['writing', 'Made the change on a preview branch'], ['running', 'Ran the build and the link check']],
      reply: 'Done on a preview branch, nothing is live yet.\n\n```bash\nbun run build   # 41 s, no warnings\nbun run links   # 214 links, 0 broken\n```\n\n[Open the preview](https://example.com/preview)\n\n» Ship it · Show me a screenshot · Undo it',
    },
  ],
  api: [
    {
      match: /120|why/i,
      phases: [['reading', 'Read a week of gateway logs'], ['thinking', 'Modelled both limits against real traffic']],
      reply: 'At 120 a minute a single runaway script can use about a fifth of one server. At 60 it is a tenth, and nobody real gets close to either:\n\n| Client | Peak per minute |\n|---|---|\n| Busiest integration | 22 |\n| Median personal token | 3 |\n| The web app | 9 |\n\n» Go with 60 · Go with 120',
    },
    {
      match: /csv|format|export/i,
      phases: [['reading', 'Read src/routes/export.ts'], ['writing', 'Added the CSV writer and its tests'], ['running', 'Ran bun test api']],
      reply: 'CSV export is on staging.\n\n```bash\ncurl -s https://example.com/v2/export \\\n  -H "Authorization: Bearer $PAPERKITE_TOKEN" \\\n  -d \'{"format": "csv"}\'\n```\n\n221 tests pass. Tags go into one column, separated by semicolons.\n\n» Ship it to production · One column per tag instead',
    },
    {
      match: /ship|production|deploy/i,
      phases: [['running', 'Ran the full test suite'], ['running', 'Deployed to production behind the flag'], ['web', 'Watched error rates for a minute']],
      reply: 'Deployed behind the `public_api_v2` flag. Error rate is flat at 0.02%. I will turn the flag on for 10% of accounts and report back in an hour.\n\n» Turn it on for everyone · Hold at 10%',
    },
    {
      phases: [['reading', 'Read the code around it'], ['running', 'Ran bun test api'], ['writing', 'Wrote the change and a test']],
      reply: 'Done on the branch `api/next`. 221 tests pass and the slowest endpoint is still under 400 ms.\n\n- No schema change\n- No new dependency\n\n» Open a pull request · Show me the diff',
    },
  ],
  releases: [
    {
      match: /tester|send|beta/i,
      phases: [['running', 'Published build 420 to the beta channel'], ['web', 'Checked the update feed'], ['writing', 'Posted the notes to the testers']],
      reply: 'Build 420 is out to the 180 beta testers. The update feed answers with the new version and both downloads verify.\n\nI will watch crashes for the next two hours and tell you if anything moves.\n\n» Thanks · Pull it back',
    },
    {
      match: /ship|2\.4\.1|publish/i,
      phases: [['running', 'Promoted 2.4.1 to the stable channel'], ['web', 'Verified the update feed and both downloads'], ['writing', 'Published the release notes']],
      reply: '2.4.1 is live for everyone.\n\n| Check | Result |\n|---|---|\n| Update feed | 2.4.1 (412) |\n| Mac download | verified |\n| Windows download | verified |\n\nFirst installs are coming in. I will report the crash rate in an hour.\n\n» Thanks · Show me the adoption',
    },
    {
      match: /note|changelog/i,
      phases: [['reading', 'Read the merged pull requests since 2.4'], ['writing', 'Wrote the notes']],
      reply: '## Paperkite 2.5 beta\n\n- Shared folders: invite someone and edit the same notes\n- Search is twice as fast on large libraries\n- Fixed: a crash in sync when a note was deleted elsewhere\n- Fixed: the menu bar icon vanished after sleep on some Macs\n\n» Send it to testers · Shorter please',
    },
    {
      match: /crash|report/i,
      phases: [['web', 'Pulled the crash reports'], ['reading', 'Grouped them by stack'], ['thinking', 'Compared with last week']],
      reply: '38 reports since yesterday 18:00, one stack:\n\n```\nSyncQueue.apply(_:)        line 212\nSyncEngine.drain()         line 88\nAppDelegate.didBecomeActive\n```\n\nAll on 2.4.0, all with two devices signed in. 2.4.1 removes the crash.\n\n» Ship 2.4.1 · Who is affected?',
    },
    {
      phases: [['reading', 'Read the release board'], ['running', 'Ran the build'], ['running', 'Ran the tests on both platforms']],
      reply: 'Done. Both platforms build and pass.\n\n| Platform | Tests |\n|---|---|\n| macOS | 1,231 pass |\n| Windows | 1,209 pass |\n\nNothing is published until you say so.\n\n» Publish to beta · Keep it local',
    },
  ],
  support: [
    {
      match: /refund|mara|reply/i,
      phases: [['reading', 'Read the conversation with Mara'], ['writing', 'Put the draft on a card']],
      reply: 'The reply to Mara is on your list as a card. You can edit the text there, then **Send and refund** does both in one go.\n\n» Open the card · Make it shorter',
    },
    {
      match: /jonas|seat|licen[cs]e/i,
      phases: [['reading', 'Read both mails from Jonas'], ['web', 'Looked up his licence']],
      reply: 'Jonas has a 2-seat licence. Both seats are taken: his new Mac and a "MacBook Air (old)" last seen in August.\n\nReleasing the old seat fixes it. That is yours to do, the steps are on the card.\n\n» Show me the steps · Reply that it is fixed',
    },
    {
      match: /wait|who|open/i,
      phases: [['reading', 'Read the inbox'], ['thinking', 'Sorted by how long each person has waited']],
      reply: 'Waiting on you:\n\n- **Mara L.** 14 hours (refund reply drafted)\n- **Jonas K.** 9 hours (seat reset)\n\nWaiting on them:\n\n- **Priya S.** needs to pick a plan after her discount\n\n» Open the oldest · Ok',
    },
    {
      phases: [['reading', 'Read the inbox'], ['web', 'Looked up the purchases'], ['writing', 'Drafted the replies']],
      reply: 'Done. I drafted what I could and left the rest for you. Nothing went out: replies only leave when you send them.\n\n» Show me the drafts · Thanks',
    },
  ],
  finance: [
    {
      match: /key|how/i,
      phases: [['web', 'Read the payments dashboard docs'], ['writing', 'Wrote the steps']],
      reply: 'It takes a minute:\n\n1. Open the payments dashboard, then Developers, then API keys\n2. Create a **restricted** key\n3. Give it read access to Charges and Invoices, nothing else\n4. Paste it into the password manager entry "Payments read-only"\n\nI read it from there, so you never have to send it to me.\n\n» Done, try again · Remind me tonight',
    },
    {
      match: /done|again|retry|partial|export/i,
      phases: [['running', 'Ran the October export'], ['reading', 'Checked the totals against the dashboard'], ['writing', 'Wrote the summary']],
      reply: 'October is in: **$7,412**, up 8% on September.\n\n| Plan | Customers | Revenue |\n|---|---|---|\n| Monthly | 224 | $2,016 |\n| Yearly | 105 | $5,040 |\n| Team | 3 | $356 |\n\nThe totals match the dashboard to the cent.\n\n» Compare with last year · Send it to my accountant',
      images: [{ path: IMAGES.revenueOctober, alt: 'Monthly revenue, last six months' }],
    },
    {
      phases: [['reading', 'Read the latest invoices'], ['thinking', 'Compared with the last three months']],
      reply: 'Costs this month so far: **$398**.\n\n- Hosting: $180\n- Mail: $29\n- Tools: $189\n\nNothing unusual. The next bill is the domain, in 41 days.\n\n» Show revenue too · Thanks',
    },
  ],
  lab: [
    {
      phases: [['reading', 'Read the prototype branch'], ['running', 'Ran the benchmark'], ['writing', 'Wrote up the result']],
      reply: 'Tried it on the branch `lab/next`. It works, with one catch: memory goes up by about 40 MB on large libraries.\n\n» Show me the numbers · Drop it',
    },
  ],
}

const GENERIC: Line[] = [
  {
    phases: [['thinking', 'Read your message'], ['reading', 'Looked at what I already have on this'], ['writing', 'Wrote the answer']],
    reply: 'Got it. I looked into this and have a first version ready.\n\n- What I did: the smallest change that answers what you asked\n- What I did not touch: anything public or irreversible\n\nTell me if you want me to go further.\n\n» Go further · Show me · That is enough',
  },
  {
    phases: [['reading', 'Read the context'], ['running', 'Ran a quick check'], ['writing', 'Summed it up']],
    reply: 'Done. The check passes and nothing else changed.\n\n» Thanks · What changed?',
  },
]

/**
 * Short messages every bot answers the same way, and without a line of quick replies: the first asks nothing,
 * so no reply buttons follow it; the second asks a question, so the person's saved replies do.
 */
const SMALL_TALK: Line[] = [
  {
    match: /^\s*(?:thanks|thank you|thx|great|perfect|nice|looks good|that is enough)\b[\s.!]*$/i,
    phases: [['thinking', 'Read your message']],
    reply: 'You are welcome. I will tell you when there is something new.',
  },
  {
    match: /^\s*(?:not now|later|leave it|cancel that|keep it local)\b[\s.!]*$/i,
    phases: [['thinking', 'Read your message'], ['writing', 'Put it aside']],
    reply: 'Understood, I left it as it is and nothing went out.\n\nShould I bring it up again tomorrow morning?',
  },
]

/** The reply to a message Sam sent to one bot. */
export function scriptFor(bot: Bot, text: string, memberNames: string[] = []): Script {
  if (bot.kind === 'group') return groupScript(memberNames, text)
  const small = SMALL_TALK.find((l) => l.match!.test(text))
  if (small) return { phases: P(small.phases), reply: small.reply }
  const lines = LINES[bot.id] ?? GENERIC
  const hit = lines.find((l) => l.match?.test(text))
  const rest = lines.filter((l) => !l.match)
  const line = hit ?? rest[bot.sent % rest.length] ?? GENERIC[0]
  return { phases: P(line.phases), reply: line.reply, images: line.images }
}

const GROUP_SAYS: Record<string, string[]> = {
  Website: ['The page and the changelog are ready on a preview branch. One deploy and it is live.', 'I can have the launch page updated within the hour once the build number is final.'],
  API: ['Rate limiting is the last open item on my side. Everything else is live behind the flag.', 'The backend can take launch traffic: I load tested at five times a normal day.'],
  Releases: ['Mac is green. Windows needs one more run after the long path fix, then both are ready.', 'I need a day of beta before stable, so the build has to be final by Wednesday.'],
  Support: ['I prepared saved replies for the three questions a launch always brings.', 'The inbox is at zero waiting, so launch mail will get fast answers.'],
  Finance: ['Launch week pricing is set up as a coupon, off by default until you say so.', 'I will send a revenue snapshot each evening of launch week.'],
  Chief: ['I will keep one list of what is open and tell you the moment something slips.', 'Nothing here needs you before Wednesday noon.'],
}

/** A group answers with one paragraph per member, each starting with the member's name in bold. */
function groupScript(names: string[], text: string): Script {
  const members = names.length ? names : ['Website', 'API', 'Releases']
  const turn = text.length % 2
  const paras = members.map((name) => `**${name}:** ${(GROUP_SAYS[name] ?? ['Nothing blocking on my side.', 'I am ready when the others are.'])[turn]}`)
  return {
    phases: members.slice(0, 3).map((name, i) => ({ activity: ['reading', 'thinking', 'writing'][i % 3], step: `${name} checked its part`, secs: 2 })),
    reply: `${paras.join('\n\n')}\n\n» What could slip? · Plan the day · Thanks`,
  }
}

/** What a bot says after a question was answered on the phone. */
export function answerScript(bot: Bot, picked: string): Script {
  if (bot.id === 'api') {
    return {
      phases: P([['writing', 'Wrote the limiter and its tests'], ['running', 'Ran bun test api (219 pass)']], 2.5),
      reply: `Thanks. Going with **${picked || 'your choice'}**.\n\nThe limiter is on the launch branch, with a clear error for clients that go over:\n\n\`\`\`json\n{ "error": "rate_limited", "retry_after": 12 }\n\`\`\`\n\n219 tests pass. It goes out with the next deploy.\n\n» Deploy it now · Show me the diff · Thanks`,
    }
  }
  return {
    phases: P([['thinking', 'Read your answer'], ['writing', 'Carried on with it']], 2.5),
    reply: `Thanks, noted: **${picked || 'your answer'}**. I carried on with that and will report when it is done.\n\n» Ok · Change my answer`,
  }
}

/** What a bot says after a command approval was accepted or declined. */
export function decisionScript(accepted: boolean, command: string): Script {
  return accepted
    ? { phases: P([['running', `Ran ${command}`], ['web', 'Checked the result']], 2.5), reply: `Approved and done: \`${command}\` finished without errors. The pricing page is live with the new headline.\n\n» Thanks · Roll it back` }
    : { phases: P([['thinking', 'Stopped before running it']], 2), reply: `Understood, I did not run \`${command}\`. The change stays on the preview branch.\n\n» Ok · Ask me again tomorrow` }
}

/** What a bot says after a card was handed to it (Handle it, or a custom button). */
export function cardScript(bot: Bot, title: string, label: string, edited?: string): Script {
  const withText = edited ? '\n\nI used the text as you left it.' : ''
  if (label === 'Handle it') {
    return {
      phases: P([['reading', `Read the card "${title}"`], ['thinking', 'Checked what I can do without you'], ['writing', 'Did the part that is safe']]),
      reply: `Handled: "${title}". I did it, checked the result and took the card off your list.\n\n» What did you do? · Thanks`,
    }
  }
  return {
    phases: P([['reading', `Read the card "${title}"`], ['running', `Did it: ${label}`], ['web', 'Checked the result']]),
    reply: `Done: **${label}** for "${title}".${withText}\n\n» Thanks · Undo that`,
  }
}
