import ActivityKit
import SwiftUI
import UserNotifications
import WidgetKit

@main
struct T3BotApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { store.open(url: $0) }
                .task {
                    store.start()
                    #if DEBUG
                    // Simulator screen checks: `-open t3bot://...` opens a screen at launch (no confirmation dialog).
                    // `-t3botURL <url> -t3botToken <token>` point the app at a test or demo server (Connection.swift).
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-open"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
                        try? await Task.sleep(for: .seconds(1)); store.open(url: url)
                    }
                    // `-debugInbox`: links written one per line to the file `t3bot-debug-open` in the app's tmp folder
                    // are opened as they arrive. `simctl openurl` asks "Open in T3 Bot?" and nothing can tap the answer,
                    // so POLISH/capture.sh sends every link after launch through this file.
                    if args.contains("-debugInbox") {
                        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("t3bot-debug-open")
                        try? FileManager.default.removeItem(at: inbox)
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(150))
                            guard let text = try? String(contentsOf: inbox, encoding: .utf8) else { continue }
                            try? FileManager.default.removeItem(at: inbox)
                            for line in text.split(separator: "\n") {
                                if let url = URL(string: line.trimmingCharacters(in: .whitespaces)) { store.open(url: url) }
                            }
                        }
                    }
                    #endif
                }
        }
        .onChange(of: phase) { _, p in
            if p == .active { store.start(); Task { await store.refreshAll() } }
            if p == .background { store.flushPending(); store.stop(); store.saveCache() }
        }
    }
}

/// Home once the app knows its server; the connect screen before that, and while pairing with another one.
struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack {
            if store.paired && !store.showConnect {
                HomeView().transition(.opacity)
            } else {
                ConnectView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.paired)
        .animation(.easeInOut(duration: 0.25), value: store.showConnect)
    }
}

enum Route: Hashable {
    case agent(String)
    case allNeeds
    case know
}

/// Everything the screens show. Rules that keep the app instant:
/// - screens draw from what is already here (memory, then the disk cache from last time), never wait for the network;
/// - every bot's chat is fetched in the background, so opening one shows it at once;
/// - a tap acts on the screen first (the card leaves, the sheet closes) and the request runs behind it, with a retry.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var home: Home?
    @Published var timelines: [String: Timeline] = [:]
    @Published var error: String?
    @Published var path = NavigationPath()
    @Published var selectedCard: Card?
    /// The swiping view over everything (Review button, t3bot://review from a widget or a link).
    @Published var showReview = false
    /// Debug only: the chat that should open with its keyboard up.
    @Published var focusComposer: String?
    /// Debug only: a sheet or search to show for a screen check.
    @Published var debugSheet: String?
    /// Bots whose answer just landed: their face smiles once.
    @Published var justAnswered: Set<String> = []
    /// Cards already acted on, hidden until the server agrees or the action fails.
    @Published var doneLocally: Set<String> = []
    /// The small bar at the bottom: "Sending", "Done", or a failure.
    @Published var toast: Toast?
    /// Bumped when a card is handed to a bot: any sheet over the chat closes so the chat is visible.
    @Published var sheetReset = 0
    /// Messages sent but not yet in the bot's thread, shown at once as the last bubble.
    @Published var outgoing: [String: String] = [:]
    /// When each bot's chat was last seen: a reply newer than that is unread on home (saved across launches).
    @Published private(set) var seen: [String: Date] = (UserDefaults.standard.dictionary(forKey: "seen") as? [String: Date]) ?? [:]

    /// A reply not seen yet (automated traffic never counts: `last` only holds the conversation itself).
    func unread(_ a: Agent) -> Bool {
        guard let last = a.last, last.from == "agent", let at = Ago.date(last.at) else { return false }
        guard let s = seen[a.id] else { return false }
        return at > s && currentAgent != a.id
    }

    func markSeen(_ id: String) {
        seen[id] = Date()
        UserDefaults.standard.set(seen, forKey: "seen")
    }

    /// What was typed to each bot and not sent, kept like Messages keeps drafts.
    @Published var drafts: [String: String] = (UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String]) ?? [:]

    func saveDraft(_ text: String, for id: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { drafts[id] = nil } else { drafts[id] = text }
        #if DEBUG
        // Screen captures start every screen from a clean app: a draft typed by a debug link is not kept.
        if ProcessInfo.processInfo.arguments.contains("-debugInbox") { return }
        #endif
        UserDefaults.standard.set(drafts, forKey: "drafts")
    }

    /// A message that could not be sent stays in its chat, marked, until a tap tries again.
    @Published var failed: [String: FailedSend] = [:]

    struct FailedSend: Equatable { let text: String; let images: [Data] }
    /// The chat on screen (or opening), so its own replies do not also ring, and so the bar at the bottom is drawn
    /// by that chat, above its composer, instead of over its last lines.
    @Published var currentAgent: String?
    private var lastPrefetch = Date.distantPast
    /// False while the server cannot be reached; the screens say so and keep showing the last data.
    @Published var online = true
    @Published var lastSync: Date?
    /// True when the server answered but refused the token: waiting will not fix it, pairing again will.
    @Published var refused = false

    // MARK: - Connection

    /// Whether the app knows a server (paired here, or carried by the build). False shows the connect screen.
    @Published private(set) var paired = Connection.current != nil
    /// The connect screen over everything: "Pair another server" in Settings, or a pairing link opened while paired.
    @Published var showConnect = false
    /// A pairing that arrived as a link (t3bot://connect?...). The connect screen checks it before anything is saved.
    @Published var pendingPairing: Connection?
    /// What the server said about itself (`/v1/hello`): name, version, demo or not, push configured or not.
    @Published var hello: Hello?
    /// Why this phone gets no pushes, when iOS refused to register it. Shown in Settings, kept across refreshes.
    @Published var pushError: String?
    /// True once the server holds this phone's push token.
    @Published private(set) var pushRegistered = false
    private var deviceToken: String?
    #if DEBUG
    /// Screen checks: a connect screen state to draw (t3bot://debug/connect/<state>).
    @Published var debugConnect: String?
    /// Screen checks: home is held on a made-up state (t3bot://debug/home/<state>) and not refreshed.
    private var frozen = false
    #endif

    /// The bot that leads: the one the server names, else the bot with id "chief", else the first bot.
    /// Home puts it on top with the ask field, and it is the default wherever a bot is needed and none is given.
    var chiefId: String {
        let agents = home?.agents ?? []
        if let id = home?.chief, agents.contains(where: { $0.id == id }) { return id }
        if agents.contains(where: { $0.id == "chief" }) { return "chief" }
        return agents.first { $0.kind != "group" && !$0.hidden }?.id ?? agents.first?.id ?? "chief"
    }

    /// A checked pairing: saved, and the app starts over on that server.
    func connect(_ c: Connection, hello: Hello? = nil) {
        let old = Connection.current
        stop()
        if let old, old.url != c.url {
            if let deviceToken { API.forgetDevice(deviceToken, on: old) }
            reset()
        }
        Connection.save(c)
        self.hello = hello
        refused = false
        online = true
        pushRegistered = false
        pendingPairing = nil
        showConnect = false
        paired = Connection.current != nil
        start()
        Task { await loadSettings() }
        WidgetCenter.shared.reloadAllTimelines()
        // Asks for notifications the first time, and gives the new server this phone's push token.
        AppDelegate.askForPush()
    }

    /// Forgets the server: the connect screen comes back and nothing of the old server stays on the phone.
    func disconnect() {
        stop()
        if let old = Connection.current, let deviceToken { API.forgetDevice(deviceToken, on: old) }
        Connection.clear()
        reset()
        hello = nil
        pushRegistered = false
        showConnect = false
        // Debug launch arguments stay in force, so the app can still be paired after this.
        paired = Connection.current != nil
        if paired { start() }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Everything that belonged to one server: what is on screen, what is saved, what is waiting to be sent.
    private func reset() {
        pending = [:]
        home = nil
        timelines = [:]
        settings = nil
        error = nil
        toast = nil
        path = NavigationPath()
        selectedCard = nil
        showReview = false
        outgoing = [:]
        failed = [:]
        doneLocally = []
        justAnswered = []
        seen = [:]
        drafts = [:]
        UserDefaults.standard.removeObject(forKey: "seen")
        UserDefaults.standard.removeObject(forKey: "drafts")
        refused = false
        online = true
        lastSync = nil
        lastPrefetch = .distantPast
        currentAgent = nil
        Store.cache.withLock { $0 = [:] }
        try? FileManager.default.removeItem(at: Self.cacheURL)
        ImageStore.shared.clear()
        FaceShare.forget()
        for act in Activity<BotWorkAttributes>.activities { Task { await act.end(nil, dismissalPolicy: .immediate) } }
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    /// iOS gave this phone its push token: the server gets it now, and again later if this try fails.
    func registered(deviceToken hex: String) {
        deviceToken = hex
        pushError = nil
        pushRegistered = false
        registerDevice()
    }

    private func registerDevice() {
        guard paired, !pushRegistered, let deviceToken, let server = Connection.current else { return }
        Task {
            let ok = (try? await API.post("v1/devices", ["token": deviceToken, "env": API.apnsEnv])) != nil
            if ok, server == Connection.current { pushRegistered = true }
        }
    }

    func loadHello() async {
        guard let server = Connection.current else { return }
        if let h: Hello = try? await API.get("v1/hello"), server == Connection.current { hello = h }
    }

    /// A short message in the bar at the bottom that leaves by itself.
    func flash(_ text: String, failed: Bool = false) {
        let t = Toast(text: text, failed: failed)
        toast = t
        Task { try? await Task.sleep(for: .seconds(failed ? 4 : 1.8)); if toast == t { toast = nil } }
    }
    private var homeLoop: Task<Void, Never>?
    private var chatLoop: Task<Void, Never>?
    /// Done and Not now wait a few seconds before they reach the server, so Undo can take them back.
    private var pending: [UUID: (commit: () -> Void, cancel: () -> Void)] = [:]

    struct Toast: Equatable {
        let text: String
        var failed = false
        var busy = false
        /// Set when Undo is offered for this action.
        var undo: UUID? = nil
    }

    init() { if Connection.current != nil { loadCache() } }

    var needs: [Card] { (home?.needs ?? []).filter { !doneLocally.contains($0.id) } }

    // MARK: - One loop for the whole app

    /// Keeps everything fresh whatever screen is open: home every 6 s while a bot works (15 s otherwise, 4 s while the
    /// server is unreachable), and the open chat every 2 s while its bot works (5 s otherwise). Stops in the background.
    /// Does nothing until the app is paired.
    func start() {
        guard paired else { return }
        if homeLoop == nil {
            homeLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    let busy = self.home?.agents.contains { $0.mood == "working" || $0.mood == "watching" } ?? false
                    try? await Task.sleep(for: .seconds(!self.online ? 4 : busy ? 6 : 15))
                }
            }
        }
        if chatLoop == nil {
            chatLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let id = self.currentAgent
                    if let id { await self.loadTimeline(id) }
                    let working = id.map { self.timelines[$0]?.working == true || self.outgoing[$0] != nil } ?? false
                    try? await Task.sleep(for: .seconds(id == nil ? 1 : working ? 2 : 5))
                }
            }
        }
    }

    func stop() {
        homeLoop?.cancel(); homeLoop = nil
        chatLoop?.cancel(); chatLoop = nil
    }

    func refresh() async {
        guard paired, let server = Connection.current else { return }
        #if DEBUG
        if frozen { return }
        #endif
        do {
            let h: Home = try await API.get("v1/home")
            // Paired with another server while this was on its way: its answer is not ours any more.
            guard server == Connection.current else { return }
            online = true
            refused = false
            lastSync = Date()
            // Two bots with the same id (a hand-edited bot list) must not crash the app: the first one counts.
            let before = Dictionary((home?.agents ?? []).map { ($0.id, $0.lastReplyAt) }, uniquingKeysWith: { a, _ in a })
            let stateBefore = Dictionary((home?.agents ?? []).map { ($0.id, "\($0.mood ?? "")|\($0.activity ?? "")|\($0.status)|\($0.lastReplyAt ?? "")") }, uniquingKeysWith: { a, _ in a })
            justAnswered = Set(h.agents.filter { a in
                guard let was = before[a.id], let now = a.lastReplyAt else { return false }
                return was != now
            }.map(\.id))
            // The widgets follow the app at once instead of their own 15-minute refresh.
            if home?.needs.map(\.id) != h.needs.map(\.id) { WidgetCenter.shared.reloadTimelines(ofKind: "needs") }
            home = h
            // First launch with this feature: everything already there counts as seen.
            for a in h.agents where seen[a.id] == nil { seen[a.id] = Date() }
            UserDefaults.standard.set(seen, forKey: "seen")
            // A card the server no longer lists is really gone; forget it was hidden.
            doneLocally = doneLocally.filter { id in h.needs.contains { $0.id == id } }
            Store.cache.withLock { c in for a in h.agents { c[a.id] = a } }
            // The extensions (widgets, Live Activity, notifications, share sheet) read the faces from here.
            FaceShare.sync(h.agents)
            error = nil
            registerDevice()
            if hello == nil { Task { await loadHello() } }
            try? await UNUserNotificationCenter.current().setBadgeCount(h.badge)
            if UserDefaults.standard.bool(forKey: "sharephone") { Task { await PhoneSync.push() } }
            // A bot whose state moved (started, finished, asked, answered): its chat is fetched now, not at the next round.
            let moved = Set(h.agents.filter { a in stateBefore[a.id] != "\(a.mood ?? "")|\(a.activity ?? "")|\(a.status)|\(a.lastReplyAt ?? "")" }.map(\.id))
            prefetch(changed: justAnswered.union(moved))
        } catch {
            guard server == Connection.current else { return }
            online = false
            if case let APIError.status(code, _) = error, code == 401 || code == 403 {
                refused = true
                self.error = "\(server.label) refused this phone's token. Pair again to carry on."
            } else {
                refused = false
                if home == nil { self.error = "Can't reach \(server.label) yet." }
            }
        }
    }

    /// Back in the foreground: everything fresh at once (home and every bot's chat), never the state saved on disk.
    func refreshAll() async {
        lastPrefetch = .distantPast
        await refresh()
        if online, hello == nil { await loadHello() }
    }

    /// Every visible bot's chat, in the background: at most every 45 s, sooner for a bot whose state moved.
    private func prefetch(changed: Set<String>) {
        let due = Date().timeIntervalSince(lastPrefetch) > 45
        let ids = (home?.agents ?? []).filter { !$0.hidden && (due || changed.contains($0.id) || timelines[$0.id] == nil) }.map(\.id)
        guard !ids.isEmpty else { return }
        if due { lastPrefetch = Date() }
        for id in ids { Task { await loadTimeline(id) } }
    }

    func loadTimeline(_ id: String) async {
        guard let server = Connection.current else { return }
        if let t: Timeline = try? await API.get("v1/agents/\(id)"), server == Connection.current {
            timelines[id] = t
            if let out = outgoing[id], let last = t.entries.last(where: { $0.type == "me" }),
               last.text == out || (out.contains(" photo") && Ago.date(last.at).map { Date().timeIntervalSince($0) < 120 } == true) {
                outgoing[id] = nil
            }
        }
    }

    func agent(_ id: String) -> Agent? { home?.agents.first { $0.id == id } }
    func faceState(_ a: Agent) -> FaceState { justAnswered.contains(a.id) ? .success : a.faceState }
    /// Same lookup for code that is not on the main actor (avatar URLs).
    nonisolated func agentNow(_ id: String) -> Agent? { Store.cache.withLock { $0[id] } }
    nonisolated static let cache = Locked<[String: Agent]>([:])

    func open(agent id: String) {
        path = NavigationPath()
        path.append(Route.agent(id))
        // Known at once, not when the chat's first read starts: a "Sending" bar shown with this call goes straight
        // to the chat's own place for it.
        currentAgent = id
    }

    func open(url: URL) {
        // t3bot://agent/<id>, t3bot://card/<id> (widgets), t3bot://review, t3bot://home,
        // t3bot://connect?url=<base URL>&token=<token> (the pairing link `t3bot pair` prints)
        let rest = url.pathComponents.dropFirst().joined(separator: "/")
        switch url.host {
        case "connect":
            guard let c = Connection.parse(link: url.absoluteString) else {
                flash("That pairing link is not complete", failed: true)
                return
            }
            if paired, c == Connection.current { flash("Already connected to \(c.label)"); return }
            // Nothing is saved here: the connect screen checks the server first, and asks before it replaces one.
            pendingPairing = c
            if paired { showConnect = true }
        // Nothing to open before the app knows a server: a link from an old widget or notification is dropped.
        case "agent": if paired, !rest.isEmpty { open(agent: rest) }
        case "review": if paired { path = NavigationPath(); showReview = true }
        #if DEBUG
        // Screen checks on a simulator (no taps there): t3bot://debug/undo shows the Undo toast,
        // t3bot://debug/type/<agent> opens that chat with the keyboard up.
        case "debug":
            let parts = url.pathComponents.dropFirst()
            if parts.first == "undo" { toast = Toast(text: "Marked done", undo: UUID()) }
            if parts.first == "type", let id = parts.dropFirst().first {
                // t3bot://debug/type/<agent>/<text> also puts that text in the composer, so the send button shows.
                let typed = parts.dropFirst(2).joined(separator: "/")
                if !typed.isEmpty { drafts[id] = typed }
                open(agent: id); focusComposer = id
            }
            // t3bot://debug/sheet/settings|new|connect|edit-<agent>|needs-<agent>|search-<query>,
            // t3bot://debug/route/know|needs
            if parts.first == "sheet", let what = parts.dropFirst().first {
                if what.hasPrefix("edit-") { open(agent: String(what.dropFirst(5))) }
                if what == "connect" { debugConnect = nil; showConnect = true } else { debugSheet = what }
            }
            // t3bot://debug/connect/first|scan|manual|demo|checking|unreachable|token|notserver|address|confirm:
            // the connect screen in that state ("first" is what a new install shows).
            if parts.first == "connect", let what = parts.dropFirst().first { debugConnect = what; showConnect = true }
            // t3bot://debug/home/empty|solo|many|loading|offline|refused|live: home on a made-up state, held until "live".
            if parts.first == "home", let what = parts.dropFirst().first { debugHome(what) }
            // t3bot://debug/pusherror: Settings with a push registration failure.
            if parts.first == "pusherror" { pushError = "Push not available: no valid aps-environment entitlement found."; debugSheet = "settings" }
            if parts.first == "route", let what = parts.dropFirst().first {
                path = NavigationPath(); path.append(what == "know" ? Route.know : Route.allNeeds)
            }
            if parts.first == "card", let id = parts.dropFirst().first, let c = home?.needs.first(where: { $0.id.hasSuffix(id) }) { selectedCard = c }
            // Everything else under t3bot://debug/ (scroll, detent, tap, menu, toast, and the action links that call
            // the functions the buttons call) is listed above `debugMore` at the end of this file.
            debugMore(Array(parts))
        #endif
        case "card": Task { await open(card: rest) }
        default: path = NavigationPath()
        }
    }

    #if DEBUG
    /// Home as it looks with no bots, one bot and no chief, twenty bots, before the first answer, or with the
    /// server away. The real state comes back with "live".
    private func debugHome(_ what: String) {
        path = NavigationPath()
        showConnect = false
        if what == "live" { frozen = false; Task { await refresh() }; return }
        frozen = true
        refused = false
        online = true
        error = nil
        let real = home?.agents ?? []
        func made(_ agents: [Agent], needs: [Card] = []) -> Home {
            Home(agents: agents, phoneShared: home?.phoneShared, needs: needs, badge: needs.count, doneToday: 0, chief: home?.chief)
        }
        switch what {
        case "empty": home = made([])
        case "solo": home = made(Array(real.filter { $0.id != chiefId && $0.kind != "group" && !$0.hidden }.prefix(1)))
        case "many":
            guard let data = try? JSONEncoder().encode(real), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty else { return }
            let others = list.filter { ($0["id"] as? String) != chiefId }
            var out = list
            var i = 0
            while out.count < 20, !others.isEmpty {
                var copy = others[i % others.count]
                copy["id"] = "\(copy["id"] as? String ?? "bot")-\(i)"
                copy["name"] = "\(copy["name"] as? String ?? "Bot") \(i / others.count + 2)"
                out.append(copy)
                i += 1
            }
            if let back = try? JSONSerialization.data(withJSONObject: out), let agents = try? JSONDecoder().decode([Agent].self, from: back) {
                home = made(agents, needs: home?.needs ?? [])
            }
        case "loading": home = nil
        case "offline": home = nil; online = false; error = "Can't reach \(Connection.current?.label ?? "the server") yet."
        case "refused": home = nil; online = false; refused = true; error = "\(Connection.current?.label ?? "The server") refused this phone's token. Pair again to carry on."
        default: break
        }
    }
    #endif

    func open(card id: String) async {
        if home == nil { await refresh() }
        if let c = home?.needs.first(where: { $0.id == id }) { selectedCard = c }
    }

    // MARK: - Acting at once

    /// Any button on a card. The card leaves (or the bot's chat opens) at once; the request runs behind with a retry,
    /// and the card comes back if it really failed. Face ID first when the button asks for it.
    func act(_ card: Card, _ actionId: String, text: String? = nil, until: Date? = nil, label: String? = nil) {
        let action = card.actions?.first { $0.id == actionId }
        let kind = action?.kind ?? actionId
        let run = {
            let goesToBot = kind == "handle" || kind == "message"
            if goesToBot { self.sheetReset += 1; self.open(agent: card.agent) }
            self.doneLocally.insert(card.id)
            let who = self.agent(card.agent)?.name ?? "the bot"
            let done = label ?? (kind == "done" ? "Marked done" : kind == "snooze" ? "Snoozed" : goesToBot ? "Sent to \(who)" : "Done")
            var body: [String: Any] = ["id": card.id, "action": actionId]
            if let text { body["text"] = text }
            if let until { body["until"] = ISO8601DateFormatter().string(from: until) }
            if kind == "done" || kind == "snooze" {
                kind == "done" ? Haptics.success() : Haptics.soft()
                self.performUndoable(done, undo: { self.doneLocally.remove(card.id) }) { try await API.post("v1/cards/act", body) }
            } else {
                Haptics.tap()
                self.perform(done, undo: { self.doneLocally.remove(card.id) }) { try await API.post("v1/cards/act", body) }
            }
        }
        if action?.faceId == true {
            Task { if await FaceID.confirm("\(action?.label ?? "Confirm"): \(card.title)") { run() } }
        } else {
            run()
        }
    }

    // MARK: - Settings

    @Published var settings: AppSettings?

    func loadSettings() async {
        guard let server = Connection.current else { return }
        if let s: AppSettings = try? await API.get("v1/settings"), server == Connection.current { settings = s }
    }

    func save(_ s: AppSettings) {
        let was = settings
        settings = s
        guard let data = try? JSONEncoder().encode(s), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // A save that never reached the server: Settings shows what the server still has, not what was typed.
        perform("Saved", quiet: true, undo: { if self.settings == s { self.settings = was } }) { try await API.post("v1/settings", body) }
    }

    /// An answer to an agent's question or approval: the card leaves at once.
    func answer(_ card: Card, body: [String: Any]) {
        Haptics.success()
        doneLocally.insert(card.id)
        let who = agent(card.agent)?.name ?? "the bot"
        // A bot's own thread is titled "%BOT <name>" on the server: say the name, as a person would.
        perform("Answer sent to \(CardHeader.threadName(card.threadTitle ?? who))", undo: { self.doneLocally.remove(card.id) }) {
            try await API.post("v1/answer", body)
        }
    }

    /// The bot's Live Activity while it works on what was just sent (lock screen and Dynamic Island).
    func startLive(_ agentId: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let a = agent(agentId) else { return }
        for act in Activity<BotWorkAttributes>.activities where act.attributes.agentId == agentId {
            Task { await act.end(nil, dismissalPolicy: .immediate) }
        }
        let state = BotWorkAttributes.ContentState(status: "working", text: "", startedAt: Date().timeIntervalSince1970)
        guard let act = try? Activity.request(attributes: BotWorkAttributes(agentId: agentId, agentName: a.name, agentColor: a.color),
                                              content: .init(state: state, staleDate: Date().addingTimeInterval(3600)), pushType: .token) else { return }
        Task {
            for await token in act.pushTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                // Lowercase hex, and which APNs the token belongs to, as the device registration sends it.
                _ = try? await API.post("v1/live", ["agent": agentId, "token": hex, "startedAt": state.startedAt, "env": API.apnsEnv])
            }
        }
    }

    /// The answer landed: show its first line, then let the activity go.
    func endLive(_ agentId: String, text: String) {
        for act in Activity<BotWorkAttributes>.activities where act.attributes.agentId == agentId {
            let state = BotWorkAttributes.ContentState(status: "answered", text: String(text.prefix(140)), startedAt: act.content.state.startedAt)
            Task { await act.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(240))) }
        }
    }

    /// Shows the message at once in the bot's chat, sends it behind.
    func send(_ text: String, to agentId: String, images: [Data] = [], onFail: @escaping () -> Void = {}) {
        Haptics.tap()
        startLive(agentId)
        failed[agentId] = nil
        outgoing[agentId] = images.isEmpty ? text : [text, "[\(images.count) photo\(images.count == 1 ? "" : "s")]"].filter { !$0.isEmpty }.joined(separator: "\n")
        perform("Sent", quiet: true, undo: { self.outgoing[agentId] = nil; self.failed[agentId] = FailedSend(text: text, images: images); onFail() }) {
            var body: [String: Any] = ["text": text]
            if !images.isEmpty { body["images"] = images.map { $0.base64EncodedString() } }
            try await API.post("v1/agents/\(agentId)/send", body)
            await self.loadTimeline(agentId)
        }
    }

    /// Requests of `perform` still on their way: leaving the app waits for them (`flushPending`).
    private var inFlight = 0

    func perform(_ done: String, quiet: Bool = false, undo: @escaping () -> Void, _ op: @escaping () async throws -> Void) {
        if !quiet { toast = Toast(text: "Sending", busy: true) }
        // The server this action belongs to. Once the app is paired with another one, nothing of it may land there:
        // no second try (it would go to the new server), no rollback into the new server's state, no bar.
        let server = Connection.current?.url
        inFlight += 1
        Task {
            var lastError: Error?
            for attempt in 0..<2 where server == Connection.current?.url {
                do {
                    try await op()
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt == 0 { try? await Task.sleep(for: .seconds(1.5)) }
                }
            }
            inFlight -= 1
            guard server == Connection.current?.url else { return }
            // Only the bar this call put up is taken down later: a quiet success shows none, and whatever is on
            // screen then (another card's Undo) belongs to someone else.
            var mine: Toast?
            if let lastError {
                undo()
                Haptics.error()
                mine = Toast(text: "Not sent: \(lastError.localizedDescription)", failed: true)
                toast = mine
            } else {
                if !quiet { mine = Toast(text: done); toast = mine }
                await refresh()
            }
            guard let mine else { return }
            try? await Task.sleep(for: .seconds(lastError == nil ? 1.6 : 5))
            if toast == mine { toast = nil }
        }
    }

    /// Done or Not now: the card is gone at once, Undo is offered for 4 s, then the action goes to the server.
    func performUndoable(_ done: String, undo: @escaping () -> Void, _ op: @escaping () async throws -> Void) {
        let id = UUID()
        var committed = false
        let commit = { [weak self] in
            // Undo takes the entry out of `pending`: the timer below then finds nothing to send.
            guard let self, !committed, self.pending[id] != nil else { return }
            committed = true
            self.pending[id] = nil
            if self.toast?.undo == id { self.toast = nil }
            self.perform(done, quiet: true, undo: undo, op)
        }
        pending[id] = (commit, { undo() })
        toast = Toast(text: done, undo: id)
        Task {
            try? await Task.sleep(for: .seconds(4))
            commit()
        }
    }

    func undoAction(_ id: UUID) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.cancel()
        Haptics.soft()
        toast = Toast(text: "Undone")
        Task { try? await Task.sleep(for: .seconds(1.2)); if toast?.text == "Undone" { toast = nil } }
    }

    /// Leaving the app: whatever is still waiting for Undo goes now.
    func flushPending() {
        guard !pending.isEmpty else { return }
        // iOS suspends the app a few seconds after it leaves the screen: it is asked to wait until the requests
        // (and their one retry) are through, so a Done swiped just before leaving is not lost.
        endFlush()
        flushTask = UIApplication.shared.beginBackgroundTask(withName: "t3bot.flush") {
            MainActor.assumeIsolated { Store.shared.endFlush() }
        }
        for p in pending.values { p.commit() }
        Task {
            let limit = Date().addingTimeInterval(25)
            while inFlight > 0, Date() < limit { try? await Task.sleep(for: .milliseconds(300)) }
            endFlush()
        }
    }

    private var flushTask = UIBackgroundTaskIdentifier.invalid

    private func endFlush() {
        guard flushTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(flushTask)
        flushTask = .invalid
    }

    // MARK: - Disk cache, so the app opens on the last data at once

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("t3bot-cache.json")
    }

    private struct Snapshot: Codable {
        let home: Home?
        let timelines: [String: Timeline]
    }

    func saveCache() {
        let snap = Snapshot(home: home, timelines: timelines)
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        home = snap.home
        timelines = snap.timelines
        if let h = snap.home { Store.cache.withLock { c in for a in h.agents { c[a.id] = a } } }
    }
}

/// Short taps of feedback under the finger, so every action feels received.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let note = UINotificationFeedbackGenerator()
    private static let pick = UISelectionFeedbackGenerator()

    static func tap() { light.impactOccurred() }
    static func soft() { softGen.impactOccurred() }
    static func success() { note.notificationOccurred(.success) }
    static func error() { note.notificationOccurred(.error) }
    static func select() { pick.selectionChanged() }
}

/// A tiny lock for values read off the main actor.
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

import LocalAuthentication

/// Face ID (or the passcode) before an action that sends, pays or releases.
enum FaceID {
    static func confirm(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// "Not now" choices. Morning means when quiet hours end.
enum Snooze {
    struct Option: Identifiable { let id: String; let label: String; let until: Date }

    @MainActor
    static func options(_ settings: AppSettings?) -> [Option] {
        let cal = Calendar.current
        let now = Date()
        func at(_ hhmm: String, dayOffset: Int = 0) -> Date {
            let p = hhmm.split(separator: ":").compactMap { Int($0) }
            // An hour the server sent out of range is clamped, so the menu always has its choices.
            let hour = min(max(p.first ?? 8, 0), 23)
            let minute = min(max(p.count > 1 ? p[1] : 0, 0), 59)
            let d = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            return cal.date(byAdding: .day, value: dayOffset, to: d) ?? d
        }
        let morningH = settings?.quiet.to ?? "08:00"
        var morning = at(morningH)
        if morning <= now { morning = at(morningH, dayOffset: 1) }
        var list = [Option(id: "3h", label: "In 3 hours", until: now.addingTimeInterval(3 * 3600))]
        let evening = at("18:00")
        if evening > now.addingTimeInterval(3600) { list.append(Option(id: "evening", label: "This evening", until: evening)) }
        // After midnight and before the morning hour, the next morning is today's.
        list.append(Option(id: "morning", label: cal.isDateInToday(morning) ? "This morning" : "Tomorrow morning", until: morning))
        let weekday = cal.component(.weekday, from: now)
        let toSaturday = (7 - weekday + 7) % 7
        if toSaturday > 1 { list.append(Option(id: "weekend", label: "This weekend", until: at("10:00", dayOffset: toSaturday))) }
        list.append(Option(id: "week", label: "Next week", until: at(morningH, dayOffset: (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)))
        return list
    }
}

#if DEBUG
// MARK: - Debug links for screen checks and workflows without taps

extension Store {
    /// The rest of the t3bot://debug/ links. A simulator driven over ssh has no taps, so POLISH/capture.sh reaches
    /// every screen and runs every workflow through these. `<card>` is the end of a card id (`demo-q-api`,
    /// `approve-reply`) or `first` for the card on top of the needs list.
    ///
    /// Screens:
    /// - t3bot://debug/scroll/<points>|bottom|top: scrolls the largest list on the front screen or sheet.
    /// - t3bot://debug/detent/large|medium: the front sheet at that height (a card sheet opens at half height).
    /// - t3bot://debug/tap/<label>: activates the control with that accessibility label, as VoiceOver would
    ///   (simulator only). Opens what has no link of its own: "Hidden bots" on home, "That's wrong" in the digest.
    /// - t3bot://debug/menu/<label>: opens the menu of the button with that accessibility label ("More" in a chat,
    ///   "Not now" on a card). With no label, the first menu button on the front screen.
    /// - t3bot://debug/toast/busy|failed|<text>: the bar at the bottom while sending, after a failure, or with a text.
    /// - t3bot://debug/dismiss: closes the front sheet.
    /// - t3bot://debug/unpaired: the app as a new install shows it, with no server known (until the next launch).
    ///   A t3bot://debug/connect/<state> link after it shows that state of the first-run screen.
    ///
    /// Actions, each through the function its button calls:
    /// - t3bot://debug/send/<agent>/<text>: `send`, what the composer's send button does.
    /// - t3bot://debug/answer/<card>/<option number from 0, or its label>: `answer`, as "Send answer" on a question.
    /// - t3bot://debug/decide/<card>/accept|decline: `answer`, as Approve and Decline on a command approval.
    /// - t3bot://debug/act/<card>/primary|secondary|done|<action id>: `act`, as the card's buttons (with the card's
    ///   editable text when it has one).
    /// - t3bot://debug/snooze/<card>/3h|evening|morning|weekend|week: `act` with the time, as the "Not now" menu.
    /// - t3bot://debug/undo-last: `undoAction` on the Undo that is on screen.
    /// - t3bot://debug/create/<name>/<what it does>: the request and messages of "Create" in the new bot sheet
    ///   (that code lives in the sheet, so it is repeated here, not called).
    /// - t3bot://debug/hide/<agent> and t3bot://debug/unhide/<agent>: the request "Save" sends from the edit sheet
    ///   with "Hide from the home screen" switched (repeated here for the same reason).
    func debugMore(_ parts: [String]) {
        let a = parts.count > 1 ? parts[1] : ""
        let b = parts.count > 2 ? parts[2] : ""
        func card() -> Card? { a == "first" ? needs.first : needs.first { $0.id.hasSuffix(a) } }
        switch parts.first {
        case "scroll": DebugUI.scroll(a)
        case "detent": DebugUI.detent(a)
        case "tap": DebugUI.tap(a)
        case "menu": DebugUI.menu(a)
        case "dismiss": DebugUI.top?.dismiss(animated: false)
        case "unpaired":
            path = NavigationPath()
            debugSheet = nil
            selectedCard = nil
            paired = false
        case "toast":
            switch a {
            case "busy": toast = Toast(text: "Sending", busy: true)
            case "failed": toast = Toast(text: "Not sent: The request timed out.", failed: true)
            default: toast = Toast(text: a.isEmpty ? "Done" : a)
            }
        case "send":
            if !a.isEmpty, !b.isEmpty { send(b, to: a) }
        case "answer":
            guard let c = card(), let threadId = c.threadId, let requestId = c.requestId else { return }
            var answers: [String: Any] = [:]
            for q in c.questions ?? [] {
                let labels = q.options.map(\.label)
                let pick = Int(b).flatMap { labels.indices.contains($0) ? labels[$0] : nil } ?? labels.first { $0 == b } ?? labels.first ?? b
                answers[q.id] = q.multiSelect ? [pick] : pick
            }
            selectedCard = nil
            answer(c, body: ["threadId": threadId, "requestId": requestId, "answers": answers])
        case "decide":
            guard let c = card(), let threadId = c.threadId, let requestId = c.requestId else { return }
            selectedCard = nil
            answer(c, body: ["threadId": threadId, "requestId": requestId, "decision": b == "decline" ? "decline" : "accept"])
        case "act":
            guard let c = card() else { return }
            let all = CardButtons.actions(for: c)
            let main = all.filter { $0.kind != "done" && $0.kind != "snooze" }
            let id: String?
            switch b {
            case "", "primary": id = main.first?.id
            case "secondary": id = main.dropFirst().first?.id
            case "done": id = all.first { $0.kind == "done" }?.id ?? "done"
            default: id = all.first { $0.id == b }?.id
            }
            guard let id else { return }
            selectedCard = nil
            act(c, id, text: c.edit?.text)
        case "snooze":
            guard let c = card() else { return }
            let options = Snooze.options(settings)
            guard let o = options.first(where: { $0.id == b }) ?? options.first(where: { $0.id == "morning" }) ?? options.first else { return }
            selectedCard = nil
            act(c, "snooze", until: o.until, label: "Snoozed: \(o.label.lowercased())")
        case "undo-last":
            if let id = toast?.undo { undoAction(id) }
        case "create":
            guard !a.isEmpty else { return }
            toast = Toast(text: "Creating \(a)", busy: true)
            Task {
                var failed = false
                do {
                    let r = try await API.post("v1/agents", ["kind": "bot", "name": a, "job": b])
                    await refresh()
                    toast = Toast(text: "\(a) is ready")
                    if let id = r.id { open(agent: id) }
                } catch {
                    failed = true
                    toast = Toast(text: "Not created: \(error.localizedDescription)", failed: true)
                }
                let shown = toast
                try? await Task.sleep(for: .seconds(failed ? 5 : 2))
                if toast == shown { toast = nil }
            }
        case "hide", "unhide":
            guard let bot = agent(a) else { return }
            let body: [String: Any] = ["name": bot.name, "role": bot.role, "hidden": parts.first == "hide", "face": ["skin": bot.face.skin]]
            perform("Saved \(bot.name)", undo: {}) {
                try await API.post("v1/agents/\(bot.id)/edit", body)
                await self.refresh()
            }
        default: break
        }
    }
}

/// What the debug links do to the screen itself: UIKit under SwiftUI, found by walking the front screen.
@MainActor
enum DebugUI {
    static var window: UIWindow? {
        let all = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return all.first { $0.isKeyWindow } ?? all.first
    }

    /// The screen in front: the last sheet or cover presented, else the root.
    static var top: UIViewController? {
        var c = window?.rootViewController
        while let p = c?.presentedViewController, !p.isBeingDismissed { c = p }
        return c
    }

    static func views(in v: UIView) -> [UIView] { [v] + v.subviews.flatMap { views(in: $0) } }

    /// One line per call in tmp/t3bot-debug.log, so a link that found nothing says so.
    static func log(_ line: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t3bot-debug.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func scroll(_ to: String) {
        guard let root = top?.view else { return }
        let lists = views(in: root).compactMap { $0 as? UIScrollView }.filter {
            // Taller than what shows between the bars, not than the frame: Home's list runs under both.
            $0.window != nil && !$0.isHidden && $0.bounds.width > 200
                && $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom > $0.bounds.height + 1
        }
        guard let s = lists.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            log("scroll \(to): no list taller than its visible area")
            return
        }
        let first = -s.adjustedContentInset.top
        var last = first, y = first
        // A lazy list only learns its full height as it scrolls, so "bottom" is asked a few times.
        for _ in 0..<(to == "bottom" ? 6 : 1) {
            let end = max(first, s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom)
            if end == last, y == end { break }
            last = end
            y = to == "bottom" ? last : to == "top" ? first : min(last, first + CGFloat(Double(to) ?? 0))
            s.setContentOffset(CGPoint(x: s.contentOffset.x, y: y), animated: false)
            s.layoutIfNeeded()
        }
        log("scroll \(to): \(type(of: s)) to \(Int(y)) of \(Int(last))")
    }

    static func detent(_ what: String) {
        guard let sheet = top?.sheetPresentationController else { log("detent \(what): no sheet"); return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = what == "medium" ? .medium : .large }
        log("detent \(what): \(sheet.detents.count) detents")
    }

    static func menu(_ label: String) {
        guard let root = top?.view else { return }
        let buttons = views(in: root).compactMap { $0 as? UIButton }.filter { $0.window != nil && ($0.menu != nil || $0.showsMenuAsPrimaryAction) }
        let named = buttons.first { !label.isEmpty && ($0.accessibilityLabel ?? "").hasPrefix(label) }
        if let b = named ?? (label.isEmpty ? buttons.first : nil) {
            b.performPrimaryAction()
            log("menu \(label): opened \(type(of: b))")
        } else {
            // No UIKit menu button under SwiftUI: go through accessibility like any other control.
            log("menu \(label): \(buttons.count) menu buttons, none by that name; trying accessibility")
            tap(label)
        }
    }

    /// Activates the control with that accessibility label (or whose label starts with it).
    static func tap(_ label: String) {
        guard !label.isEmpty else { return }
        enableAccessibility()
        Task {
            // SwiftUI builds its accessibility elements once something asks for them; give it a moment.
            for attempt in 0..<6 {
                if let root = top?.view, let found = find(label, in: root, depth: 0) {
                    let ok = found.accessibilityActivate()
                    log("tap \(label): \(type(of: found)) activated \(ok)")
                    return
                }
                _ = attempt
                try? await Task.sleep(for: .milliseconds(250))
            }
            log("tap \(label): not found")
        }
    }

    private static func find(_ label: String, in o: NSObject, depth: Int) -> NSObject? {
        guard depth < 80 else { return nil }
        if let v = o as? UIView, v.isHidden || v.window == nil { return nil }
        if o.isAccessibilityElement, let l = o.accessibilityLabel, l == label || l.hasPrefix(label) { return o }
        if let list = o.accessibilityElements {
            for case let e as NSObject in list { if let f = find(label, in: e, depth: depth + 1) { return f } }
        } else {
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 {
                for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject, let f = find(label, in: e, depth: depth + 1) { return f } }
            }
        }
        if let v = o as? UIView {
            for s in v.subviews.reversed() { if let f = find(label, in: s, depth: depth + 1) { return f } }
        }
        return nil
    }

    private static var accessibilityOn = false

    /// SwiftUI only describes its controls to accessibility once a client is there. On the simulator the
    /// automation switch stands in for one; a device build never touches it.
    private static func enableAccessibility() {
        #if targetEnvironment(simulator)
        guard !accessibilityOn else { return }
        accessibilityOn = true
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let sym = dlsym(lib, "_AXSSetAutomationEnabled") else {
            log("accessibility: switch not found")
            return
        }
        typealias Switch = @convention(c) (Int32) -> Void
        unsafeBitCast(sym, to: Switch.self)(1)
        #endif
    }
}
#endif
