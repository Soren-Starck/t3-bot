import Foundation

// Home, a bot's chat and the needs list, built from T3 Code's data. A port of server/t3bot.ts (agentSummary, home,
// timeline, questionCards), so the app shows the same thing in both modes. Pure functions: tested on the Mac with
// the samples (ios/Direct/Tests).

struct ComposeInput {
    var shell: [String: T3ThreadSummary]
    var projections: [String: T3Projection]
    var meta: [String: BotMeta]
    var snoozed: [String: Date]
    var quickReplies: [String]
    var environmentId: String
    var userName: String?
    var now: Date = Date()
    /// Chief override: the bot the person chose to lead; else the bot named Chief; else the oldest.
    var chief: String? = nil
}

enum Compose {
    static let activeRun: Set<String> = ["running", "starting", "preparing", "queued"]
    static let maxRequestAgeDays = 14.0

    static func isActive(_ status: String?) -> Bool { activeRun.contains(status ?? "") }

    /// Messages that T3 Bot itself sent to set up or tell a bot something: their runs never show.
    static func isSystemMessageId(_ id: String) -> Bool {
        ["t3bot:rule:", "t3bot:sys:", "crew:rule:", "crew:sys:"].contains { id.hasPrefix($0) }
    }

    // MARK: Bots

    struct Bot {
        var thread: T3ThreadSummary
        var name: String
        var kind: String
        var meta: BotMeta
    }

    static func bots(_ input: ComposeInput) -> [Bot] {
        var out: [Bot] = []
        for t in input.shell.values where !t.isGone && !t.isSubagent {
            guard let title = t.title, let parsed = BotBook.parse(title: title) else { continue }
            var meta = input.meta[t.id] ?? BotMeta()
            if meta.skin == nil { meta.skin = BotBook.defaultSkin(for: parsed.name) }
            out.append(Bot(thread: t, name: parsed.name, kind: parsed.kind, meta: meta))
        }
        let chief = chiefId(out, override: input.chief)
        return out.sorted { a, b in
            if a.thread.id == chief { return true }
            if b.thread.id == chief { return false }
            if a.kind != b.kind { return a.kind == "bot" }
            return (a.thread.createdAt ?? "") < (b.thread.createdAt ?? "")
        }
    }

    static func chiefId(_ bots: [Bot], override: String?) -> String? {
        if let o = override, bots.contains(where: { $0.thread.id == o && $0.kind == "bot" }) { return o }
        if let c = bots.first(where: { $0.kind == "bot" && $0.name.lowercased() == "chief" }) { return c.thread.id }
        return bots.filter { $0.kind == "bot" }.min { ($0.thread.createdAt ?? "") < ($1.thread.createdAt ?? "") }?.thread.id
    }

    /// The bot a thread's questions belong to: its own bot, a bot that watches its title, else the Chief.
    static func agent(forThread id: String, title: String, bots: [Bot], chief: String?) -> String {
        if bots.contains(where: { $0.thread.id == id }) { return BotBook.botId(id) }
        for b in bots { if (b.meta.watch ?? []).contains(where: { !$0.isEmpty && title.hasPrefix($0) }) { return BotBook.botId(b.thread.id) } }
        return chief.map(BotBook.botId) ?? ""
    }

    // MARK: The needs list

    /// Every question or approval that can still be answered, from any thread. A request T3 Code can no longer pass
    /// to the agent (the session ended) is left out: answering it would fail.
    static func questionCards(_ input: ComposeInput, bots: [Bot], chief: String?) -> [Card] {
        var cards: [Card] = []
        for t in input.shell.values where !t.isGone {
            guard let pending = t.pendingRuntimeRequest else { continue }
            if let at = pending.createdAt.flatMap(Ago.date), input.now.timeIntervalSince(at) > maxRequestAgeDays * 86400 { continue }
            let p = input.projections[t.id]
            let request = p?.runtimeRequests.first { $0.id == pending.id }
            if let cap = request?.responseCapability?.type, cap == "not_resumable" { continue }
            if let s = request?.status, s != "pending" { continue }
            let item = p?.turnItems.last { $0.requestId == pending.id && ($0.type ?? "").contains("request") }
            let questions: [Question] = (item?.questions ?? []).enumerated().map { i, q in
                Question(id: q.id ?? q.question ?? "q\(i)", question: q.question ?? "", header: q.header, multiSelect: q.multiSelect ?? false,
                         options: (q.options ?? []).map { Option(label: $0.label, description: $0.description) })
            }
            let kind = (pending.kind ?? "") == "user_input" ? "user_input" : "command"
            // A question whose text is not known yet (the thread is still loading) waits for the next round.
            if kind == "user_input" && questions.isEmpty { continue }
            let command = item?.prompt ?? item?.command ?? item?.detail ?? item?.text
            // An approval reads as what the agent wants to do, in its words; the command itself comes under it.
            let why = [item?.reason, item?.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty && $0 != command }
            let title: String = kind == "command" ? (why.map { T3Text.clip($0, 140) } ?? "Run a command") : (questions.first?.question ?? "A question")
            let threadTitle = t.title ?? ""
            cards.append(Card(id: "req:\(pending.id)", source: "question",
                              agent: agent(forThread: t.id, title: threadTitle, bots: bots, chief: chief), rank: 0, title: title,
                              detail: kind == "command" ? command.map { T3Text.clip($0, 600) } : (questions.count > 1 ? "\(questions.count) questions" : nil),
                              why: nil, steps: nil, urgency: nil,
                              customer: nil, minutes: nil, desk: nil, deskName: nil, key: nil, at: pending.createdAt ?? t.updatedAt ?? "",
                              threadId: t.id, threadTitle: threadTitle, requestId: pending.id, requestKind: kind,
                              questions: kind == "user_input" ? questions : (questions.isEmpty ? nil : questions),
                              kind: nil, link: nil, draft: nil, fields: nil, checks: nil, edit: nil, actions: nil))
        }
        return cards
    }

    static func needs(_ input: ComposeInput, bots: [Bot], chief: String?) -> [Card] {
        questionCards(input, bots: bots, chief: chief)
            .filter { c in (input.snoozed[c.id].map { $0 <= input.now }) ?? true }
            .sorted { a, b in a.rank != b.rank ? a.rank < b.rank : a.at < b.at }
    }

    // MARK: A bot's line on Home

    /// What a working thread is doing right now, from its newest step (port of t3.ts `activity`).
    static func activity(_ p: T3Projection?) -> String? {
        guard let p else { return nil }
        let recent = p.turnItems.sorted { ($0.updatedAt ?? $0.startedAt ?? "") > ($1.updatedAt ?? $1.startedAt ?? "") }.prefix(6)
        guard let step = recent.first(where: { $0.status == "running" || $0.status == "waiting" || $0.status == "inProgress" }) ?? recent.first else { return nil }
        switch step.type ?? "" {
        case "reasoning", "assistant_message": return "thinking"
        case "file_change": return "writing"
        case "web_search": return "web"
        case "subagent": return "delegating"
        case "user_input_request", "approval_request": return "asking"
        case "command_execution":
            let cmd = (step.input ?? "").trimmingCharacters(in: .whitespaces)
            if T3Text.matches(cmd, "^(curl|wget)\\b") { return "web" }
            if T3Text.matches(cmd, "^(cat|head|tail|grep|rg|ls|find|sed -n|wc|jq|less|stat|du|df|tree|git (log|show|diff|status)|sqlite3 -readonly|python3 -I -c)\\b") { return "reading" }
            return "running"
        case "dynamic_tool":
            let t = step.toolName ?? ""
            if T3Text.matches(t, "^(Read|Grep|Glob|NotebookRead|LS)$") || T3Text.matches(t, "thread_read|thread_list|thread_search|read_file|list_") { return "reading" }
            if T3Text.matches(t, "^(Edit|Write|MultiEdit|NotebookEdit)$") { return "writing" }
            if T3Text.matches(t, "^(WebSearch|WebFetch)$") || T3Text.matches(t, "preview|chrome|browser|html_render") { return "web" }
            if T3Text.matches(t, "^(Agent|Task)$") || T3Text.matches(t, "thread_send|thread_wait|delegate|thread_launch") { return "delegating" }
            if T3Text.matches(t, "AskUserQuestion") { return "asking" }
            if t == "Bash" { return "running" }
            return "thinking"
        default: return "thinking"
        }
    }

    /// Runs started by T3 Bot's own notices (never shown, never rung).
    static func systemRuns(_ p: T3Projection) -> Set<String> {
        Set(p.messages.filter { isSystemMessageId($0.id) }.compactMap(\.runId))
    }

    static func visibleMessages(_ p: T3Projection, limit: Int = 160) -> [T3Message] {
        let hidden = systemRuns(p)
        let msgs = p.messages
            .filter { ($0.role == "user" || $0.role == "assistant") && !hidden.contains($0.runId ?? "\u{0}") }
            .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        return Array(msgs.suffix(limit))
    }

    static func latestRun(_ p: T3Projection?) -> T3Run? {
        p?.runs.max { ($0.ordinal ?? 0, $0.requestedAt ?? "") < ($1.ordinal ?? 0, $1.requestedAt ?? "") }
    }

    static func summary(_ bot: Bot, _ input: ComposeInput, bots: [Bot], needs: [Card]) -> Agent {
        let t = bot.thread
        let p = input.projections[t.id]
        let watched = input.shell.values.filter { w in !w.isGone && w.id != t.id && (bot.meta.watch ?? []).contains { !$0.isEmpty && (w.title ?? "").hasPrefix($0) } }
        let mine = needs.filter { $0.agent == BotBook.botId(t.id) }
        let runStatus = latestRun(p)?.status ?? t.status ?? "idle"
        let ownWorking = isActive(runStatus) || isActive(t.status) || (t.activityRunStatus != nil && t.activityRunStatus != "waiting")
        let watchingNow = watched.filter { isActive($0.status) || $0.activityRunStatus != nil }
        let working = ownWorking || !watchingNow.isEmpty
        let waiting = mine.contains { $0.source == "question" || $0.rank <= 1 }
        let askingNow = ownWorking && mine.contains { $0.source == "question" && $0.threadId == t.id }
        let mood: String = askingNow ? "waiting" : ownWorking ? "working" : waiting ? "waiting" : !watchingNow.isEmpty ? "watching" : (runStatus == "failed" ? "failed" : "asleep")
        let doing: String? = ownWorking ? (activity(p) ?? "thinking") : (watchingNow.isEmpty ? nil : (activity(input.projections[watchingNow[0].id]) ?? "thinking"))

        var last: Last? = nil
        var lastReplyAt: String? = nil
        if let p {
            let recent = visibleMessages(p, limit: 60).filter { !T3Text.isSlash($0.role ?? "", $0.text ?? "") }
            let userRuns = Set(recent.filter { $0.role == "user" && $0.createdBy == "user" }.compactMap(\.runId))
            lastReplyAt = p.messages.filter { $0.role == "assistant" && $0.streaming != true }.map { $0.createdAt ?? "" }.max()
            if let m = recent.last(where: { ($0.role == "user" && $0.createdBy == "user") || ($0.role == "assistant" && userRuns.contains($0.runId ?? "\u{0}")) }) {
                let raw = m.role == "assistant" ? T3Text.splitSuggestions(m.text ?? "").text : (m.text ?? "")
                last = Last(text: T3Text.preview(raw, 160, pictures: m.attachments?.count ?? 0), at: m.createdAt ?? "", from: m.role == "assistant" ? "agent" : "me")
            }
        } else if let v = t.latestVisibleMessage, let text = v.text {
            let raw = v.role == "assistant" ? T3Text.splitSuggestions(text).text : text
            last = Last(text: T3Text.preview(raw, 160), at: v.updatedAt ?? v.createdAt ?? t.updatedAt ?? "", from: v.role == "assistant" ? "agent" : "me")
            if v.role == "assistant" { lastReplyAt = v.updatedAt ?? v.createdAt }
        }
        let skin = bot.meta.skin ?? BotBook.defaultSkin(for: bot.name)
        let role = bot.meta.role ?? (bot.kind == "group" ? "Group" : "")
        return Agent(id: BotBook.botId(t.id), name: bot.name, role: role, avatar: "skin:\(skin)", kind: bot.kind, face: Face(skin: skin), hidden: bot.meta.hidden ?? false,
                     members: (bot.meta.members ?? []).map(BotBook.botId), threadId: t.id, threadTitle: t.title ?? "", t3Link: link(env: input.environmentId, thread: t.id),
                     status: waiting ? "waiting" : working ? "working" : "idle", mood: mood, activity: doing, lastReplyAt: lastReplyAt,
                     needs: mine.count, last: last, watching: watchingNow.compactMap(\.title), color: Skins.color(skin))
    }

    static func link(env: String, thread: String) -> String? {
        guard !env.isEmpty else { return nil }
        return "t3code://threads/\(T3Link.segment(env))/\(T3Link.segment(thread))"
    }

    static func home(_ input: ComposeInput) -> Home {
        let list = bots(input)
        let chief = chiefId(list, override: input.chief)
        let needs = needs(input, bots: list, chief: chief)
        let agents = list.map { summary($0, input, bots: list, needs: needs) }
        return Home(agents: agents, phoneShared: false, needs: needs, badge: needs.filter { $0.rank <= 1 }.count, doneToday: 0,
                    chief: chief.map(BotBook.botId), t3: T3State(ok: true, error: nil))
    }

    // MARK: A bot's chat

    static func entries(_ p: T3Projection, quickReplies: [String]) -> (entries: [Entry], working: Bool) {
        let run = latestRun(p)
        let working = isActive(run?.status)
        let msgs = visibleMessages(p)
        let userRuns = Set(msgs.filter { $0.role == "user" && $0.createdBy == "user" }.compactMap(\.runId))
        var entries: [Entry] = []
        var pending: [T3Message] = []
        var currentRun: String? = nil
        func flush(_ runId: String?, isLast: Bool) {
            guard let last = pending.last else { return }
            let stillWorking = isLast && working
            let split = T3Text.splitSuggestions(last.text ?? "")
            let pics = T3Text.splitImages(split.text)
            let steps = (stillWorking ? pending : Array(pending.dropLast())).map { T3Text.plain($0.text ?? "", 240) }.filter { !$0.isEmpty }
            entries.append(Entry(id: last.id, type: "agent", text: stillWorking ? "" : pics.text, at: last.createdAt ?? "", steps: steps,
                                 working: stillWorking, suggestions: stillWorking ? nil : split.suggestions,
                                 auto: runId.map { !userRuns.contains($0) } ?? false,
                                 images: stillWorking ? nil : pics.images.map { $0.map { EntryImage(path: mediaPath(thread: p.thread?.id ?? last.id, path: $0.path), alt: $0.alt) } }))
            pending = []
        }
        for m in msgs {
            if T3Text.isSlash(m.role ?? "", m.text ?? "") { continue }
            if m.runId != currentRun { flush(currentRun, isLast: false); currentRun = m.runId }
            if m.role == "user" {
                if m.createdBy == "user" {
                    let mine = T3Text.splitImages(m.text ?? "", photosOnly: true)
                    var images = mine.images ?? []
                    for a in m.attachments ?? [] where (a.type ?? "image") == "image" { if let id = a.id { images.append(EntryImage(path: attachmentPath(id), alt: a.name ?? "")) } }
                    entries.append(Entry(id: m.id, type: "me", text: mine.text, at: m.createdAt ?? "", steps: [], working: nil, suggestions: nil, auto: nil, images: images.isEmpty ? nil : images))
                } else {
                    entries.append(Entry(id: m.id, type: "auto", text: T3Text.plain(m.text ?? "", 300), at: m.createdAt ?? "", steps: [], working: nil, suggestions: nil, auto: nil, images: nil))
                }
            } else {
                pending.append(m)
            }
        }
        flush(currentRun, isLast: true)
        if let i = entries.indices.last, entries[i].type == "agent", entries[i].working != true {
            entries[i].suggestions = T3Text.quickReplies(entries[i].text, own: entries[i].suggestions, saved: quickReplies)
        }
        return (Array(entries.suffix(60)), working)
    }

    /// A bot's screenshot (`![x](/abs/path.png)`): T3 Code serves it through a short-lived link for that thread.
    static func mediaPath(thread: String, path: String) -> String { "t3media:\(thread)|\(path)" }
    /// A photo sent with a message: an attachment T3 Code keeps.
    static func attachmentPath(_ id: String) -> String { "t3attachment:\(id)" }

    static func timeline(agentId: String, _ input: ComposeInput, routines: [Routine]) -> Timeline? {
        let list = bots(input)
        guard let bot = list.first(where: { BotBook.botId($0.thread.id) == agentId }) else { return nil }
        let threadId = bot.thread.id
        let chief = chiefId(list, override: input.chief)
        let needs = needs(input, bots: list, chief: chief)
        let agent = summary(bot, input, bots: list, needs: needs)
        var entries: [Entry] = []
        var working = Compose.isActive(bot.thread.status)
        if let p = input.projections[threadId] {
            let e = Compose.entries(p, quickReplies: input.quickReplies)
            entries = e.entries
            working = e.working
        }
        let watched = input.shell.values.filter { w in !w.isGone && w.id != threadId && (bot.meta.watch ?? []).contains { !$0.isEmpty && (w.title ?? "").hasPrefix($0) } }
        let runs: [RunInfo] = watched.compactMap { w in
            guard let v = w.latestVisibleMessage, v.role == "assistant", let text = v.text, let at = v.updatedAt ?? v.createdAt,
                  let d = Ago.date(at), input.now.timeIntervalSince(d) < 36 * 3600 else { return nil }
            return RunInfo(threadId: w.id, title: w.title ?? "", status: w.status ?? "idle", at: at, text: T3Text.plain(text, 400))
        }.sorted { $0.at > $1.at }.prefix(8).map { $0 }
        let members: [Agent] = bot.kind == "group"
            ? (bot.meta.members ?? []).compactMap { m in list.first { $0.thread.id == m }.map { summary($0, input, bots: list, needs: needs) } }
            : []
        return Timeline(agent: agent, routines: routines, entries: entries, working: working,
                        cards: needs.filter { $0.agent == agentId }, runs: runs, members: members)
    }

    // MARK: Search

    struct SearchHit: Codable { let agent: String?; let role: String; let at: String; let id: String; let snippet: String }
}
