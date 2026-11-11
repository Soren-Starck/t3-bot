import Foundation

// The bots the app last saw, mirrored where the notification extension and the widgets can read them without
// reading T3 Code's whole thread list: thread id -> bot id and name, and the Chief.

struct Roster: Codable, Equatable {
    struct Bot: Codable, Equatable { var id: String; var name: String; var skin: String; var kind: String }
    var bots: [String: Bot] = [:]   // by thread id
    var chief: String? = nil        // bot id
    var chiefName: String? = nil

    static let key = "roster"

    static func from(_ home: Home) -> Roster {
        var r = Roster()
        for a in home.agents { r.bots[a.threadId] = Bot(id: a.id, name: a.name, skin: a.face.skin, kind: a.kind) }
        r.chief = home.chief
        r.chiefName = home.agents.first { $0.id == home.chief }?.name
        return r
    }

    static func load(_ store: SmallStore = KeychainStore()) -> Roster {
        guard let d = store.data(key), let r = try? JSONDecoder().decode(Roster.self, from: d) else { return Roster() }
        return r
    }

    func save(_ store: SmallStore = KeychainStore()) {
        if let d = try? JSONEncoder().encode(self) { store.set(d, Roster.key) }
    }
}

/// What a push for a T3 Code pairing shows, read from the thread itself (the push only says which thread and why).
struct NotifyText: Equatable {
    var title: String
    var subtitle: String?
    var body: String
    var category: String
    var agent: String?
    var agentName: String?
    var threadId: String
    var requestId: String?
    var questionId: String?
    var options: [String] = []

    static func make(kind: String, threadId: String, projection p: T3Projection?, roster: Roster) -> NotifyText {
        // No thread id: a T3 Code that does not give its thread id to Claude's hooks (T3CODE_THREAD_ID, set by the
        // nightly builds from November 2026). Nobody to name and nowhere to send an answer, so the ring only says
        // that something waits; it carries no bot and no reply field, and a tap opens the app's home.
        if threadId.isEmpty {
            return NotifyText(title: "T3 Bot", subtitle: nil, body: kind == "request" ? "A Claude thread needs you" : "A Claude thread answered",
                              category: "", agent: nil, agentName: nil, threadId: "")
        }
        let title0 = p?.thread?.title ?? ""
        let own = roster.bots[threadId]
        let owner = own ?? roster.chief.flatMap { c in roster.bots.values.first { $0.id == c } }
        let botName = own?.name ?? owner?.name
        let threadName = BotBook.parse(title: title0)?.name ?? title0
        var t = NotifyText(title: botName ?? (threadName.isEmpty ? "T3 Bot" : threadName), subtitle: nil, body: "", category: "REPLY",
                           agent: owner?.id, agentName: botName, threadId: threadId)
        if kind == "request" {
            let pending = p?.runtimeRequests.filter { $0.status == "pending" }.max { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
            let item = pending.flatMap { r in p?.turnItems.last { $0.requestId == r.id } }
            if own == nil, !threadName.isEmpty { t.subtitle = "Asks in \(threadName)" }
            t.requestId = pending?.id
            if pending?.kind == "user_input", let q = item?.questions?.first {
                t.body = q.question ?? "A question"
                t.questionId = q.id ?? q.question
                t.options = (q.options ?? []).map(\.label)
                let many = (item?.questions?.count ?? 0) > 1 || (q.multiSelect ?? false)
                t.category = many || t.options.isEmpty ? (t.options.isEmpty ? "QUESTION" : "QUESTION_MULTI") : "T3OPTIONS"
                if many { t.body += "\n\((item?.questions?.count ?? 1) > 1 ? "\(item!.questions!.count) questions" : "Pick one or more") in the app" }
            } else if pending != nil {
                let cmd = item?.prompt ?? item?.command ?? item?.detail ?? item?.text ?? "a command"
                let why = [item?.reason, item?.title].compactMap { $0 }.first { !$0.isEmpty && $0 != cmd }
                t.body = why.map { "\($0)\n\(T3Text.oneLineCommand(cmd, 120))" } ?? "Wants to run: \(T3Text.oneLineCommand(cmd, 160))"
                t.category = "APPROVAL"
            } else {
                t.body = "Needs you"
                t.category = "REPLY"
            }
        } else {
            let last = p.map { Compose.visibleMessages($0).last { $0.role == "assistant" && $0.streaming != true } } ?? nil
            let text = last.map { T3Text.splitSuggestions($0.text ?? "").text } ?? ""
            t.body = text.isEmpty ? "Answered" : T3Text.preview(text, 400)
            t.category = "REPLY"
        }
        return t
    }
}
