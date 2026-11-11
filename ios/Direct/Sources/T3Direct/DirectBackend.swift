import Foundation

// The app's backend when it is paired with T3 Code itself: it answers the same paths the T3 Bot server answers
// ("v1/home", "v1/agents/<id>", "v1/answer", ...) with the same models, built from T3 Code (Compose).
//
// State: the shell (every thread's summary) and the chats it has read, kept current by T3 Code's own streams
// (subscribeShell, subscribeThread) while the app is open. Snapshots come over HTTP, where gzip makes them a tenth
// of their size; the socket then carries only what changes. With `live: false` (the extensions) it reads over HTTP
// and opens a socket only to send a command.

struct DirectConfig: Equatable {
    var base: URL
    var token: String
    var environmentId: String
    var label: String
}

/// What T3 Bot keeps on this phone for a T3 Code pairing: quick replies, quiet hours, snoozes, the Chief.
struct DirectLocal: Codable, Equatable {
    var settings: AppSettings = AppSettings(quiet: .init(enabled: true, from: "23:00", to: "08:00", alarms: true),
                                            brief: .init(enabled: false, at: "quiet-end", agent: ""), quickReplies: [])
    var snoozed: [String: Date] = [:]
    var chief: String? = nil
    /// The project new bots are made in (a T3 Code project id), when the person chose one.
    var botProject: String? = nil
    var userName: String? = nil
}

/// When the socket may be tried again after it failed: 1 s, then double each time up to 30 s, back to 1 s once it
/// opens.
struct Backoff: Equatable {
    static let cap: TimeInterval = 30
    private(set) var delay: TimeInterval = 1
    private(set) var retryAt: Date = .distantPast

    func mayTry(now: Date = Date()) -> Bool { now >= retryAt }
    mutating func failed(now: Date = Date()) {
        retryAt = now.addingTimeInterval(delay)
        delay = min(delay * 2, Backoff.cap)
    }
    mutating func succeeded() { delay = 1; retryAt = .distantPast }
}

/// Which stream task owns each place (the shell, a chat). A task that ends asks whether the place is still its own.
struct StreamSlots {
    private var next = 0
    private var owner: [String: Int] = [:]

    mutating func start(_ key: String) -> Int { next += 1; owner[key] = next; return next }
    /// True when `token` still owns `key` (which is then free); false when a newer stream took it.
    mutating func end(_ key: String, _ token: Int) -> Bool {
        guard owner[key] == token else { return false }
        owner[key] = nil
        return true
    }
}

actor DirectBackend {
    let config: DirectConfig
    private var session: URLSession
    /// False when the session was given from outside (tests): `reconnect` then keeps it.
    private let ownsSession: Bool
    /// Makes the socket; nil for the real one. The tests give one made of a fake websocket.
    private let socketMaker: (@Sendable (URLSession) -> T3Socket)?
    private let live: Bool
    private let bots: BotStore
    private let localStore: SmallStore

    private var shell: [String: T3ThreadSummary] = [:]
    private var projects: [String: T3Project] = [:]
    private var shellSeq = 0
    private var shellAt: Date = .distantPast
    private var shellLoading: Task<Void, Error>?

    private struct Chat { var projection: T3Projection; var seq: Int; var at: Date; var live: Bool; var used: Date }
    private var chats: [String: Chat] = [:]
    private var chatLoading: [String: Task<T3Projection, Error>] = [:]

    private var socket: T3Socket?
    private var socketOpening: Task<T3Socket, Error>?
    private var shellStream: Task<Void, Never>?
    private var chatStreams: [String: Task<Void, Never>] = [:]
    private var backoff = Backoff()
    private var slots = StreamSlots()

    private var tasks: [JSON] = []
    private var tasksAt: Date = .distantPast
    private var descriptor: T3Descriptor?

    /// Called whenever something T3 Code sent changed what the app shows (on the actor; hop to the main actor yourself).
    var onChange: (@Sendable () -> Void)?

    static let maxLiveChats = 4

    init(config: DirectConfig, live: Bool, session: URLSession? = nil, bots: BotStore = .shared, local: SmallStore = KeychainStore(),
         socket: (@Sendable (URLSession) -> T3Socket)? = nil) {
        self.config = config
        self.live = live
        self.bots = bots
        self.localStore = local
        self.socketMaker = socket
        self.ownsSession = session == nil
        self.session = session ?? DirectBackend.newSession()
    }

    private static func newSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    private func newSocket() -> T3Socket {
        socketMaker?(session) ?? T3Socket(base: config.base, token: config.token, session: session)
    }

    func setOnChange(_ f: (@Sendable () -> Void)?) { onChange = f }

    // MARK: Local settings

    private let localKey = "local"

    func local() -> DirectLocal {
        guard let d = localStore.data(localKey), let l = try? JSONDecoder().decode(DirectLocal.self, from: d) else { return DirectLocal() }
        return l
    }

    func updateLocal(_ f: (inout DirectLocal) -> Void) {
        var l = local()
        f(&l)
        if let d = try? JSONEncoder().encode(l) { localStore.set(d, localKey) }
    }

    // MARK: Reading T3 Code

    private func http(_ path: String, timeout: TimeInterval = 20) async throws -> Data {
        try await T3Link.get(config.base, path, token: config.token, session: session, timeout: timeout)
    }

    /// The shell, fresh: from the stream while it runs, else read again when older than `maxAge`.
    func ensureShell(maxAge: TimeInterval = 20) async throws {
        if live { ensureSocket() }
        let streaming = shellStream != nil && socket?.isOpen == true
        if !shell.isEmpty && (streaming || Date().timeIntervalSince(shellAt) < maxAge) { return }
        if let t = shellLoading { try await t.value; return }
        let t = Task { try await self.loadShell() }
        shellLoading = t
        defer { shellLoading = nil }
        try await t.value
    }

    private func loadShell() async throws {
        let data = try await http("/api/orchestration/shell?omitIdleSubagents=true&omitOlderSettled=true", timeout: 30)
        let s = try JSONDecoder().decode(T3Shell.self, from: data)
        applyShellSnapshot(s)
        if live { startShellStream() }
    }

    private func applyShellSnapshot(_ s: T3Shell) {
        shell = Dictionary(s.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        projects = Dictionary(s.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        shellSeq = s.snapshotSequence ?? 0
        shellAt = Date()
    }

    /// One chat: the stream's copy while it runs, else read again when older than `maxAge`.
    func projection(_ threadId: String, maxAge: TimeInterval = 15) async throws -> T3Projection {
        if var c = chats[threadId], c.live || Date().timeIntervalSince(c.at) < maxAge {
            c.used = Date()
            chats[threadId] = c
            return c.projection
        }
        if let t = chatLoading[threadId] { return try await t.value }
        let t = Task { () throws -> T3Projection in
            let data = try await self.http("/api/orchestration/threads/\(T3Link.segment(threadId))/bounded", timeout: 30)
            let snap = try JSONDecoder().decode(T3ThreadSnapshot.self, from: data)
            await self.storeChat(threadId, snap.projection, seq: snap.snapshotSequence ?? 0)
            return snap.projection
        }
        chatLoading[threadId] = t
        defer { chatLoading[threadId] = nil }
        return try await t.value
    }

    private func storeChat(_ id: String, _ p: T3Projection, seq: Int) {
        let wasLive = chats[id]?.live ?? false
        chats[id] = Chat(projection: p, seq: seq, at: Date(), live: wasLive, used: Date())
        learnMarker(id, p)
        if live { startChatStream(id) }
    }

    /// A bot made on another phone: its face and job from the marker in its first message.
    private func learnMarker(_ id: String, _ p: T3Projection) {
        guard bots.get(id)?.skin == nil else { return }
        if let first = p.messages.filter({ $0.role == "user" }).min(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") }),
           let m = BotBook.readMarker(first.text ?? "") {
            bots.learn(id, from: m)
        }
    }

    /// Chats of threads that wait on an answer, so their questions can be shown.
    private func loadWaiting() async {
        let cutoff = Date().addingTimeInterval(-Compose.maxRequestAgeDays * 86400)
        let waiting = shell.values.filter { t in
            guard !t.isGone, let p = t.pendingRuntimeRequest else { return false }
            if let at = p.createdAt.flatMap(Ago.date), at < cutoff { return false }
            return !(chats[t.id]?.projection.runtimeRequests.contains { $0.id == p.id } ?? false)
        }
        await withTaskGroup(of: Void.self) { g in
            for t in waiting.prefix(8) { g.addTask { _ = try? await self.projection(t.id, maxAge: 0) } }
        }
    }

    private func input() -> ComposeInput {
        let l = local()
        return ComposeInput(shell: shell, projections: chats.mapValues(\.projection), meta: bots.all(), snoozed: l.snoozed,
                            quickReplies: l.settings.quickReplies, environmentId: config.environmentId, userName: l.userName, chief: l.chief)
    }

    func home() async throws -> Home {
        try await ensureShell()
        await loadWaiting()
        return Compose.home(input())
    }

    func timeline(_ agentId: String) async throws -> Timeline {
        try await ensureShell()
        guard let bot = Compose.bots(input()).first(where: { BotBook.botId($0.thread.id) == agentId }) else { throw T3Error.rpc("That bot is not in T3 Code any more.") }
        _ = try await projection(bot.thread.id)
        await loadWaiting()
        let routines = (try? await routines(for: bot, in: Compose.bots(input()))) ?? []
        guard let t = Compose.timeline(agentId: agentId, input(), routines: routines) else { throw T3Error.rpc("That bot is not in T3 Code any more.") }
        return t
    }

    private func threadId(ofAgent id: String) async throws -> String {
        try await ensureShell()
        if let b = Compose.bots(input()).first(where: { BotBook.botId($0.thread.id) == id }) { return b.thread.id }
        throw T3Error.rpc("That bot is not in T3 Code any more.")
    }

    // MARK: Streams

    private func ensureSocket() {
        guard live, socket?.isOpen != true, socketOpening == nil, backoff.mayTry() else { return }
        socketOpening = Task { try await self.openSocket() }
    }

    private func openSocket() async throws -> T3Socket {
        defer { socketOpening = nil }
        let s = newSocket()
        s.onClose = { [weak self, weak s] why in
            guard let s else { return }
            let which = ObjectIdentifier(s)
            Task { await self?.socketClosed(which, why) }
        }
        do {
            try await s.connect()
            socket = s
            backoff.succeeded()
            if !shell.isEmpty { startShellStream() }
            for id in chats.keys where chats[id]?.live == true { chats[id]?.live = false; startChatStream(id) }
            return s
        } catch {
            backoff.failed()
            // A socket T3 Code refused at the upgrade only says "dropped". When what answers speaks another protocol
            // than this T3 Bot, say that, and which side to update. Not asked when nothing answers at all.
            let away: [URLError.Code] = [.notConnectedToInternet, .dataNotAllowed, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut, .cancelled]
            if !(error is CancellationError), !((error as? URLError).map { away.contains($0.code) } ?? false),
               let why = await T3Link.protocolProblem(config.base, session: session) { throw T3Error.rpc(why) }
            throw error
        }
    }

    /// A socket closed. Only the current one counts: one that failed to open (counted there already), one closed on
    /// purpose, or an old one whose end arrives after its replacement opened must not take the live streams down.
    private func socketClosed(_ which: ObjectIdentifier, _ why: String) {
        guard let current = socket, ObjectIdentifier(current) == which else { return }
        socket = nil
        shellStream?.cancel(); shellStream = nil
        for t in chatStreams.values { t.cancel() }
        chatStreams = [:]
        for id in chats.keys { chats[id]?.live = false }
        backoff.failed()
    }

    /// The socket, open: the live one, or a new one for this call (extensions, or after a drop).
    private func openSocketNow() async throws -> T3Socket {
        if let s = socket, s.isOpen { return s }
        if let t = socketOpening { return try await t.value }
        if live {
            let t = Task { try await self.openSocket() }
            socketOpening = t
            return try await t.value
        }
        let s = newSocket()
        try await s.connect()
        return s
    }

    private func startShellStream() {
        guard live, shellStream == nil, let s = socket, s.isOpen else { return }
        let (_, values) = s.stream("orchestration.subscribeShell", ["afterSequence": shellSeq, "requestCompletionMarker": true])
        let token = slots.start("shell")
        shellStream = Task {
            do { for try await v in values { self.applyShell(v) } } catch {}
            // A stream that was cancelled and replaced ends late: it must not clear its replacement.
            if self.slots.end("shell", token) { self.shellStream = nil }
        }
    }

    private func applyShell(_ v: Any) {
        guard let d = v as? JSON, let kind = d["kind"] as? String else { return }
        let seq = (d["sequence"] as? Int) ?? 0
        switch kind {
        case "snapshot":
            if d["resolvedRepositoryIdentityRoots"] != nil { return }
            if let snap = d["snapshot"], let data = T3JSON.data(snap),
               let s = try? JSONDecoder().decode(T3Shell.self, from: data) { applyShellSnapshot(s); changed() }
        case "thread.updated":
            guard seq > shellSeq || seq == 0, let raw = d["thread"], let data = T3JSON.data(raw),
                  let t = try? JSONDecoder().decode(T3ThreadSummary.self, from: data) else { return }
            if (d["location"] as? String) == "archive" { shell[t.id] = nil } else { shell[t.id] = t }
            shellSeq = max(shellSeq, seq); shellAt = Date(); changed()
        case "thread.removed":
            if let id = d["threadId"] as? String { shell[id] = nil; chats[id] = nil }
            shellSeq = max(shellSeq, seq); changed()
        case "project.updated":
            if let raw = d["project"], let data = T3JSON.data(raw), let p = try? JSONDecoder().decode(T3Project.self, from: data) { projects[p.id] = p }
            shellSeq = max(shellSeq, seq)
        case "project.removed":
            if let id = d["projectId"] as? String { projects[id] = nil }
            shellSeq = max(shellSeq, seq)
        default: break
        }
    }

    private func startChatStream(_ id: String) {
        guard live, chatStreams[id] == nil, let s = socket, s.isOpen, let c = chats[id] else { return }
        // Only the few chats looked at last stay live; the others are read again when opened.
        let liveIds = chats.filter { $0.value.live }.sorted { $0.value.used < $1.value.used }.map(\.key)
        if liveIds.count >= Self.maxLiveChats, let oldest = liveIds.first {
            chatStreams[oldest]?.cancel(); chatStreams[oldest] = nil; chats[oldest]?.live = false
        }
        chats[id]?.live = true
        let (_, values) = s.stream("orchestration.subscribeThread", ["threadId": id, "afterSequence": c.seq, "requestCompletionMarker": true])
        let token = slots.start(id)
        chatStreams[id] = Task {
            do { for try await v in values { self.applyChat(id, v) } } catch {}
            if self.slots.end(id, token) {
                self.chatStreams[id] = nil
                self.chats[id]?.live = false
            }
        }
    }

    private func applyChat(_ id: String, _ v: Any) {
        guard let d = v as? JSON, let kind = d["kind"] as? String, var c = chats[id] else { return }
        switch kind {
        case "snapshot":
            if let raw = d["projection"], let data = T3JSON.data(raw),
               let p = try? JSONDecoder().decode(T3Projection.self, from: data) {
                c.projection = p
                c.seq = (d["snapshotSequence"] as? Int) ?? c.seq
            }
        case "event":
            let seq = (d["sequence"] as? Int) ?? 0
            guard seq > c.seq, let ev = d["event"] as? JSON, let type = ev["type"] as? String, let payload = ev["payload"] else { return }
            c.seq = seq
            Self.apply(type: type, payload: payload, to: &c.projection)
        default: return
        }
        c.at = Date()
        chats[id] = c
        changed()
    }

    /// One thread event into a projection: each kind replaces its record by id.
    static func apply(type: String, payload: Any, to p: inout T3Projection) {
        guard let data = T3JSON.data(payload) else { return }
        let dec = JSONDecoder()
        func upsert<T: Decodable & Identifiable>(_ list: inout [T], _ x: T) where T.ID == String {
            if let i = list.firstIndex(where: { $0.id == x.id }) { list[i] = x } else { list.append(x) }
        }
        switch type {
        case "message.updated": if let m = try? dec.decode(T3Message.self, from: data) { upsert(&p.messages, m) }
        case "turn-item.updated": if let t = try? dec.decode(T3TurnItem.self, from: data) { upsert(&p.turnItems, t) }
        case "run.created", "run.updated": if let r = try? dec.decode(T3Run.self, from: data) { upsert(&p.runs, r) }
        case "runtime-request.updated": if let r = try? dec.decode(T3RuntimeRequest.self, from: data) { upsert(&p.runtimeRequests, r) }
        default:
            if type.hasPrefix("thread."), let t = try? dec.decode(T3ThreadSummary.self, from: data) { p.thread = t }
        }
    }

    private func changed() { onChange?() }

    /// The app went to the background: streams stop, what was read stays for the next open.
    func pause() {
        shellStream?.cancel(); shellStream = nil
        for t in chatStreams.values { t.cancel() }
        chatStreams = [:]
        for id in chats.keys { chats[id]?.live = false }
        // Cleared first, so the close is not taken for a drop: the next open connects at once, with no wait.
        let s = socket
        socket = nil
        s?.close("app in background")
        backoff.succeeded()
    }

    /// Makes sure the next thing asked of T3 Code goes out on a line that works: after a failure, when the app is
    /// back on screen, when the network changed. The wait before the next try starts over. An open socket is pinged:
    /// one that answers is kept, with whatever is being sent on it; one that does not (half open: the phone slept,
    /// the network changed under it) is closed and replaced, on a new URLSession so no dead connection is reused.
    /// What was read stays. Returns true when the socket in place answered and nothing was replaced.
    @discardableResult
    func reconnect(pingTimeout: TimeInterval = 3) async -> Bool {
        backoff = Backoff()
        if let s = socket, s.isOpen, await s.ping(timeout: pingTimeout) { return true }
        // An open already on its way is the new line.
        if socketOpening != nil { return false }
        shellStream?.cancel(); shellStream = nil
        for t in chatStreams.values { t.cancel() }
        chatStreams = [:]
        for id in chats.keys { chats[id]?.live = false }
        // Cleared first, so the close is not counted as a drop (which would start a wait).
        let old = socket
        socket = nil
        old?.close("reconnecting")
        backoff = Backoff()
        if ownsSession {
            let was = session
            session = DirectBackend.newSession()
            // Closed later, not now: a request that took this session a moment ago may be about to start on it,
            // and a session already closed refuses it. Every request here ends within 60 s.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90) { was.finishTasksAndInvalidate() }
        }
        // Nothing streams any more: what is shown is read again when next asked for.
        shellAt = .distantPast
        ensureSocket()
        return false
    }

    /// True when the socket may be tried now (no wait left from an earlier failure).
    var mayTrySocket: Bool { backoff.mayTry() }

    // MARK: Commands

    func call(_ tag: String, _ payload: JSON, timeout: TimeInterval = 25) async throws -> Any? {
        let s = try await openSocketNow()
        defer { if !live { s.close() } }
        return try await s.call(tag, payload, timeout: timeout)
    }

    func dispatch(_ command: JSON) async throws {
        _ = try await call("orchestration.dispatchCommand", command)
    }

    static func commandId() -> String { UUID().uuidString.lowercased() }

    /// A message to a thread. `clientId` is the app's own id for this send: a retry reuses it, so T3 Code never
    /// gets the same message twice.
    func send(threadId: String, text: String, images: [Data], clientId: String?) async throws {
        let id = (clientId?.isEmpty == false ? clientId! : Self.commandId()).lowercased()
        let messageId = "t3bot-msg-\(id)"
        var attachments: [Any] = []
        if !images.isEmpty {
            let items: [JSON] = images.enumerated().map { i, data in
                let mime = data.first == 0x89 ? "image/png" : "image/jpeg"
                return ["type": "image", "name": "photo-\(i + 1).\(mime == "image/png" ? "png" : "jpg")", "mimeType": mime,
                        "sizeBytes": data.count, "dataUrl": "data:\(mime);base64,\(data.base64EncodedString())"]
            }
            let r = try await call("assets.persistChatAttachments", ["threadId": threadId, "messageId": messageId, "attachments": items], timeout: 60)
            attachments = ((r as? JSON)?["attachments"] as? [Any]) ?? []
        }
        let busy = Compose.isActive(Compose.latestRun(chats[threadId]?.projection)?.status) || Compose.isActive(shell[threadId]?.status)
        var cmd: JSON = ["type": "message.dispatch", "commandId": "t3bot-send-\(id)", "createdBy": "user", "creationSource": "mobile",
                         "threadId": threadId, "messageId": messageId, "text": text, "attachments": attachments,
                         "dispatchMode": ["type": busy ? "queue_after_active" : "start_immediately"]]
        if !busy { cmd["deliveryIntent"] = "auto" }
        do {
            try await dispatch(cmd)
        } catch let e as T3Error {
            // The first try did reach T3 Code: the same message id is already there, which is what was wanted.
            if case let .rpc(why) = e, why.lowercased().contains("already") || why.lowercased().contains("duplicate") { return }
            throw e
        }
    }

    /// A message from T3 Bot itself (a setup or a notice): its run never shows in the chat.
    func sendSystem(threadId: String, text: String) async throws {
        let id = Self.commandId()
        let busy = Compose.isActive(shell[threadId]?.status)
        var cmd: JSON = ["type": "message.dispatch", "commandId": id, "createdBy": "agent", "creationSource": "mobile",
                         "threadId": threadId, "messageId": "t3bot:sys:\(id)", "text": text, "attachments": [] as [Any],
                         "dispatchMode": ["type": busy ? "queue_after_active" : "start_immediately"]]
        if !busy { cmd["deliveryIntent"] = "auto" }
        try await dispatch(cmd)
    }

    // MARK: Answers

    enum AnswerOutcome: Equatable { case answered, sentAsMessage }

    /// An answer to a question or an approval. A question T3 Code can no longer pass to the agent (its session
    /// ended, or it was answered elsewhere) is not a dead end: the answer goes to the thread as a message.
    func answer(threadId: String, requestId: String, decision: String?, answers: JSON) async throws -> AnswerOutcome {
        let p = try? await projection(threadId, maxAge: 5)
        let request = p?.runtimeRequests.first { $0.id == requestId }
        let item = p?.turnItems.last { $0.requestId == requestId }
        let questions = item?.questions ?? []
        // Labels as the app shows them -> the values the agent asked for.
        var mapped: JSON = [:]
        for (qid, v) in answers {
            let opts = questions.first { ($0.id ?? $0.question) == qid }?.options ?? []
            func value(_ label: String) -> String { opts.first { $0.label == label }?.value ?? label }
            if let one = v as? String { mapped[qid] = value(one) } else if let many = v as? [String] { mapped[qid] = many.map(value) } else { mapped[qid] = v }
        }
        let live = request == nil || (request?.status == "pending" && (request?.responseCapability?.type ?? "live") == "live")
        if live {
            var cmd: JSON = ["type": "runtime-request.respond", "commandId": Self.commandId(), "threadId": threadId, "requestId": requestId]
            if let decision { cmd["decision"] = decision } else { cmd["answers"] = mapped }
            do {
                try await dispatch(cmd)
                return .answered
            } catch {
                if decision != nil { throw error }
            }
        }
        // Said as a message instead, in the words the person picked.
        let lines: [String] = questions.compactMap { q in
            let key = q.id ?? q.question ?? ""
            guard let v = answers[key] else { return nil }
            let said = (v as? [String])?.joined(separator: ", ") ?? (v as? String) ?? "\(v)"
            return "\(q.question ?? "Your question"): \(said)"
        }
        let text = lines.isEmpty ? (answers.values.compactMap { $0 as? String }.joined(separator: "\n")) : lines.joined(separator: "\n")
        guard !text.isEmpty else { throw T3Error.rpc("That question is no longer waiting for an answer.") }
        try await send(threadId: threadId, text: "My answer to your earlier question:\n\(text)", images: [], clientId: nil)
        return .sentAsMessage
    }

    // MARK: Bots

    /// Makes a bot (or a group): a new thread titled `%BOT <Name>` in the bots' project, with the rules in a first
    /// message that never shows in the chat.
    func newBot(name rawName: String, job: String, kind: String, skin: String?, members: [String], model: JSON? = nil) async throws -> String {
        try await ensureShell(maxAge: 0)
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { throw T3Error.rpc("A bot needs a name.") }
        let current = Compose.bots(input())
        if current.contains(where: { $0.name.lowercased() == name.lowercased() && $0.kind == kind }) { throw T3Error.rpc("There is already a bot called \(name).") }
        let memberBots = members.compactMap { m in current.first { BotBook.botId($0.thread.id) == m && $0.kind == "bot" } }
        if kind == "group" && memberBots.count < 2 { throw T3Error.rpc("A group needs at least two bots.") }
        let chief = Compose.chiefId(current, override: local().chief).flatMap { id in current.first { $0.thread.id == id } }
        let projectId = local().botProject.flatMap { projects[$0] != nil ? $0 : nil } ?? chief?.thread.projectId ?? current.first?.thread.projectId
            ?? projects.values.filter { $0.archivedAt == nil }.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }.first?.id
        guard let projectId else { throw T3Error.rpc("T3 Code has no project yet. Create one in T3 Code first.") }
        let chosen: JSON
        if let model { chosen = model } else { chosen = try await modelForNewBot(like: chief?.thread, project: projects[projectId]) }
        let usedSkins = current.compactMap(\.meta.skin)
        let face = (skin.flatMap { Skins.isSkin($0) ? $0 : nil }) ?? BotBook.freeSkin(used: usedSkins)
        let threadId = UUID().uuidString.lowercased()
        let first = Rules.firstMessage(name: name, job: job, user: local().userName, skin: face,
                                       members: memberBots.map { ($0.name, $0.thread.id) })
        var payload: JSON = ["commandId": Self.commandId(), "creationSource": "mobile", "threadId": threadId, "projectId": projectId,
                             "title": BotBook.title(name: name, kind: kind), "modelSelection": chosen,
                             "runtimeMode": chief?.thread.runtimeMode ?? "full-access", "interactionMode": "default",
                             "workspaceStrategy": ["type": "root"],
                             "initialMessage": ["messageId": "t3bot:rule:\(Self.commandId())", "text": first, "attachments": [] as [Any]]]
        payload["generateTitle"] = false
        bots.update(threadId) { m in
            m.skin = face
            m.role = job.isEmpty ? (kind == "group" ? "Group: " + memberBots.map(\.name).joined(separator: ", ") : nil) : String(job.prefix(140))
            if kind == "group" { m.members = memberBots.map(\.thread.id) }
        }
        let result = try await call("orchestration.launchThread", payload, timeout: 40) as? JSON
        // The new thread is known at once from T3 Code's answer, before its update reaches the shell stream.
        let made = (result?["threadId"] as? String) ?? threadId
        if let proj = result?["projection"], let data = T3JSON.data(proj),
           let p = try? JSONDecoder().decode(T3Projection.self, from: data) {
            if var t = p.thread { if t.title == nil { t.title = BotBook.title(name: name, kind: kind) }; shell[made] = t }
            chats[made] = Chat(projection: p, seq: 0, at: Date(), live: false, used: Date())
        }
        if shell[made] == nil {
            shell[made] = T3ThreadSummary(id: made, projectId: projectId, title: BotBook.title(name: name, kind: kind), status: "queued",
                                          createdAt: ISO8601DateFormatter().string(from: Date()))
        }
        if made != threadId, let meta = bots.get(threadId) { bots.update(made) { $0 = meta } }
        changed()
        return BotBook.botId(made)
    }

    /// The model a new bot runs: the Chief's, else the project's default, else T3 Code's first ready provider.
    private func modelForNewBot(like t: T3ThreadSummary?, project: T3Project?) async throws -> JSON {
        func json(_ m: ModelSelection) -> JSON {
            var d: JSON = ["instanceId": m.instanceId ?? "claudeAgent", "model": m.model ?? ""]
            if let o = m.options, !o.isEmpty { d["options"] = o.map { ["id": $0.id, "value": $0.value?.string ?? ""] as JSON } }
            return d
        }
        if let m = t?.modelSelection, m.model?.isEmpty == false { return json(m) }
        if let m = project?.defaultModelSelection, m.model?.isEmpty == false { return json(m) }
        if let any = shell.values.sorted(by: { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }).first(where: { $0.modelSelection?.model?.isEmpty == false })?.modelSelection {
            return json(any)
        }
        throw T3Error.rpc("T3 Code has no model to start a bot with yet. Start one thread in T3 Code first.")
    }

    func editBot(_ agentId: String, _ b: JSON) async throws -> Bool {
        let threadId = try await threadId(ofAgent: agentId)
        let list = Compose.bots(input())
        guard let bot = list.first(where: { $0.thread.id == threadId }) else { throw T3Error.rpc("That bot is not in T3 Code any more.") }
        if b["hidden"] as? Bool == true, Compose.chiefId(list, override: local().chief) == threadId { throw T3Error.rpc("The Chief stays visible.") }
        var members: [String]? = nil
        if bot.kind == "group", let ms = b["members"] as? [String] {
            let ids = ms.compactMap { m in list.first { BotBook.botId($0.thread.id) == m && $0.kind == "bot" }?.thread.id }
            if ids.count < 2 { throw T3Error.rpc("A group needs at least two bots.") }
            members = ids
        }
        if let name = (b["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != bot.name {
            try await dispatch(["type": "thread.metadata.update", "commandId": Self.commandId(), "threadId": threadId,
                                "title": BotBook.title(name: String(name.prefix(40)), kind: bot.kind)])
        }
        bots.update(threadId) { m in
            if let r = (b["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { m.role = String(r.prefix(140)) }
            if let h = b["hidden"] as? Bool { m.hidden = h }
            if let f = (b["face"] as? JSON)?["skin"] as? String, Skins.isSkin(f) { m.skin = f }
            if let members { m.members = members }
            if let w = b["watch"] as? [String] { m.watch = w.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        var told = false
        if let job = (b["job"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !job.isEmpty {
            let who = local().userName ?? "The user"
            try await sendSystem(threadId: threadId, text: "From T3 Bot: \(who) changed what you do. Your job from now on: \"\(job)\". Update your own instructions (your notes file) so it lasts after compaction, then confirm in one line.")
            told = true
        }
        shellAt = .distantPast
        return told
    }

    /// T3 Code's projects, for choosing where new bots live.
    func projectList() async throws -> [T3Project] {
        try await ensureShell()
        return projects.values.filter { $0.archivedAt == nil }.sorted { ($0.title ?? "") < ($1.title ?? "") }
    }

    /// The models T3 Code can run, by provider instance: [(instanceId, model id, model name)].
    func models() async throws -> [(instance: String, id: String, name: String)] {
        let v = try await call("server.getConfig", [:])
        let providers = ((v as? JSON)?["providers"] as? [JSON]) ?? []
        return providers.flatMap { p -> [(instance: String, id: String, name: String)] in
            guard (p["enabled"] as? Bool) != false, let inst = (p["instanceId"] as? String) ?? (p["id"] as? String) else { return [] }
            return ((p["models"] as? [JSON]) ?? []).compactMap { m in
                guard let id = (m["slug"] as? String) ?? (m["id"] as? String) ?? (m["model"] as? String) else { return nil }
                return (inst, id, (m["name"] as? String) ?? (m["displayName"] as? String) ?? id)
            }
        }
    }

    /// Archives a thread (a bot that is removed, or a test's thread).
    func archive(threadId: String) async throws {
        try await dispatch(["type": "thread.archive", "commandId": Self.commandId(), "threadId": threadId])
        shell[threadId] = nil
        chats[threadId] = nil
    }

    func threadIdOf(agent id: String) async throws -> String { try await threadId(ofAgent: id) }

    // MARK: Routines (T3 Code's scheduled tasks)

    private func loadTasks() async throws -> [JSON] {
        if Date().timeIntervalSince(tasksAt) < 60 { return tasks }
        let v = try await call("scheduledTasks.subscribe", [:])
        tasks = ((v as? JSON)?["tasks"] as? [JSON]) ?? []
        tasksAt = Date()
        return tasks
    }

    private func routines(for bot: Compose.Bot, in list: [Compose.Bot]) async throws -> [Routine] {
        let watched = shell.values.filter { w in (bot.meta.watch ?? []).contains { !$0.isEmpty && (w.title ?? "").hasPrefix($0) } }.map(\.id)
        let ids = Set([bot.thread.id] + watched)
        return try await loadTasks().compactMap { t in
            guard let id = t["id"] as? String, let thread = t["threadId"] as? String, ids.contains(thread) else { return nil }
            return Routine(id: id, title: (t["title"] as? String) ?? "Routine", enabled: (t["enabled"] as? Bool) ?? false,
                           when: Self.describe(schedule: t["schedule"] as? JSON), nextRunAt: t["nextRunAt"] as? String,
                           lastRunAt: t["lastRunAt"] as? String, lastRunStatus: t["lastRunStatus"] as? String, own: thread == bot.thread.id)
        }.sorted { $0.title < $1.title }
    }

    /// "Every day at 07:30", "Every 2 h", "Mon, Wed at 09:00", "Once, 12 Nov at 10:00", "On a webhook".
    static func describe(schedule s: JSON?) -> String {
        guard let s, let type = s["type"] as? String else { return "" }
        switch type {
        case "interval":
            let ms = (s["everyMs"] as? Double) ?? Double((s["everyMs"] as? Int) ?? 0)
            let min = Int(ms / 60000)
            if min <= 0 { return "" }
            if min % 1440 == 0 { return min == 1440 ? "Every day" : "Every \(min / 1440) days" }
            if min % 60 == 0 { return min == 60 ? "Every hour" : "Every \(min / 60) h" }
            return "Every \(min) min"
        case "fixed_time":
            let at = (s["timeOfDay"] as? String) ?? ""
            let days = (s["weekdays"] as? [Int]) ?? []
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            if days.isEmpty || days.count == 7 { return "Every day at \(at)" }
            if Set(days) == Set([1, 2, 3, 4, 5]) { return "Weekdays at \(at)" }
            return days.sorted().compactMap { $0 >= 0 && $0 < 7 ? names[$0] : nil }.joined(separator: ", ") + " at \(at)"
        case "once":
            guard let at = (s["runAt"] as? String).flatMap(Ago.date) else { return "Once" }
            return "Once, " + at.formatted(.dateTime.day().month().hour().minute())
        default: return "On a webhook"
        }
    }

    func setRoutine(_ id: String, enabled: Bool) async throws {
        _ = try await call("scheduledTasks.setEnabled", ["id": id, "enabled": enabled])
        tasksAt = .distantPast
    }

    // MARK: Search

    func search(_ q: String) async throws -> (messages: [Compose.SearchHit], cards: [Card]) {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return ([], []) }
        try await ensureShell()
        let list = Compose.bots(input())
        let byThread = Dictionary(list.map { ($0.thread.id, BotBook.botId($0.thread.id)) }, uniquingKeysWith: { a, _ in a })
        let v = try await call("orchestration.searchThreads", ["query": String(text.prefix(200)), "limit": 50])
        let matches = ((v as? JSON)?["matches"] as? [JSON]) ?? []
        let hits: [Compose.SearchHit] = matches.compactMap { m in
            guard let tid = m["threadId"] as? String, let agent = byThread[tid] else { return nil }
            let role = (m["source"] as? String) == "assistant" ? "assistant" : "user"
            let snippet = T3Text.oneLine((m["snippet"] as? String) ?? "")
            return Compose.SearchHit(agent: agent, role: role, at: (m["messageCreatedAt"] as? String) ?? "", id: (m["messageId"] as? String) ?? UUID().uuidString, snippet: snippet)
        }
        let lower = text.lowercased()
        let needs = Compose.needs(input(), bots: list, chief: Compose.chiefId(list, override: local().chief))
        let cards = needs.filter { c in [c.title, c.detail ?? ""].contains { $0.lowercased().contains(lower) } }
        return (hits, Array(cards.prefix(20)))
    }

    // MARK: Images

    /// A picture in a chat, as a URL the phone can load: a bot's screenshot on the Mac or a photo sent with a message.
    func imageURL(_ path: String) async throws -> URL {
        var resource: JSON
        if path.hasPrefix("t3attachment:") {
            resource = ["_tag": "attachment", "attachmentId": String(path.dropFirst("t3attachment:".count)), "disposition": "inline"]
        } else if path.hasPrefix("t3media:"), let bar = path.firstIndex(of: "|") {
            let thread = String(path[path.index(path.startIndex, offsetBy: "t3media:".count)..<bar])
            resource = ["_tag": "media-file", "threadId": thread, "path": String(path[path.index(after: bar)...])]
        } else {
            throw T3Error.rpc("not a picture T3 Code keeps")
        }
        let v = try await call("assets.createUrl", ["resource": resource])
        guard let rel = (v as? JSON)?["relativeUrl"] as? String else { throw T3Error.decode("a picture link") }
        if rel.hasPrefix("http://") || rel.hasPrefix("https://"), let u = URL(string: rel) { return u }
        return T3Link.url(config.base, rel)
    }

    // MARK: Who answers

    func hello() async throws -> Hello {
        let d = try await T3Link.descriptor(config.base, session: session)
        descriptor = d
        // A T3 Code updated or replaced since pairing: the same sentence as at pairing, not a raw answer later.
        do { try T3Link.check(d) } catch { throw T3Error.rpc((error as? T3PairingError)?.errorDescription ?? error.localizedDescription) }
        try await ensureShell()
        return Hello(ok: true, name: d.label ?? config.label, version: d.serverVersion, user: local().userName, demo: false, push: nil,
                     bots: Compose.bots(input()).count, t3: T3State(ok: true, error: nil))
    }

    // MARK: Cards

    func cardAction(_ cardId: String, action: String, text: String?, until: Date?) async throws -> String? {
        let h = try await home()
        guard let card = h.needs.first(where: { $0.id == cardId }) ?? Compose.questionCards(input(), bots: Compose.bots(input()), chief: nil).first(where: { $0.id == cardId }) else {
            throw T3Error.rpc("That card is gone.")
        }
        switch action {
        case "snooze":
            let next = until.flatMap { $0 > Date().addingTimeInterval(60) ? $0 : nil } ?? Self.nextMorning(local().settings.quiet.to)
            updateLocal { $0.snoozed[cardId] = next; $0.snoozed = $0.snoozed.filter { $0.value > Date() } }
            changed()
            return nil
        case "done":
            guard let t = card.threadId, let r = card.requestId else { throw T3Error.rpc("Answer the question instead.") }
            try await dispatch(["type": "thread.user-input.dismiss", "commandId": Self.commandId(), "threadId": t, "requestId": r])
            return nil
        case "handle":
            let agentThread = try await threadId(ofAgent: card.agent.isEmpty ? (h.chief ?? "") : card.agent)
            let who = local().userName ?? "The user"
            let where_ = "thread \"\(card.threadTitle ?? "")\""
            let body = (text.map { "\($0)\n\n" } ?? "") + "From T3 Bot: \(who) picked this card on the phone and wants to deal with it now: \"\(card.title)\" (\(where_)).\nDo it if nothing more is needed from them; otherwise ask in one short question with the options."
            try await send(threadId: agentThread, text: body, images: [], clientId: nil)
            return card.agent
        default:
            throw T3Error.rpc("That button does nothing here.")
        }
    }

    static func nextMorning(_ hhmm: String, from now: Date = Date()) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        c.hour = parts.first ?? 8
        c.minute = parts.count > 1 ? parts[1] : 0
        var d = Calendar.current.date(from: c) ?? now.addingTimeInterval(8 * 3600)
        if d <= now { d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }
}
