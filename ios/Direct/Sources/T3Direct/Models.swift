import Foundation

// What the app shows, as the T3 Bot server answers it (server/t3bot.ts) and as the direct link to T3 Code builds it
// (DirectBackend). Foundation only: compiled into the app, its extensions and the T3Direct package.

struct Home: Codable {
    let agents: [Agent]
    let phoneShared: Bool?
    let needs: [Card]
    let badge: Int
    let doneToday: Int
    /// The id of the bot that leads (the server's `chief` setting). Older servers do not send it.
    var chief: String? = nil
    /// Whether the server can reach T3 Code, and what stops it when it cannot. Older servers do not send it.
    var t3: T3State? = nil
}

/// The server's link to T3 Code, where the bots run: fine, or one plain sentence about what is wrong.
struct T3State: Codable, Equatable {
    var ok: Bool? = nil
    var error: String? = nil
}

/// `GET /v1/hello`: who answers at this address. The connect screen checks a pairing with it and Settings
/// shows the server's version.
struct Hello: Codable, Equatable {
    var ok: Bool? = nil
    var name: String? = nil
    var version: String? = nil
    var user: String? = nil
    var demo: Bool? = nil
    /// Whether the server holds an APNs key, so pushes can reach this phone.
    var push: Bool? = nil
    /// How many bots the server has.
    var bots: Int? = nil
    var t3: T3State? = nil
}

struct Face: Codable, Hashable {
    var skin: String
}

struct Skin: Codable, Hashable, Identifiable {
    var id: String { n }
    let n: String
    let title: String
    let series: String
}

struct SkinList: Codable { let skins: [Skin]; let used: [String?] }

struct Agent: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let avatar: String
    let kind: String
    let face: Face
    let hidden: Bool
    let members: [String]
    let threadId: String
    let threadTitle: String
    let t3Link: String?
    let status: String
    let mood: String?
    let activity: String?
    let lastReplyAt: String?
    let needs: Int
    let last: Last?
    let watching: [String]
    /// Its skin's main color (hex), for telling the bots apart in a group chat.
    let color: String?
    /// Its thread was deleted in T3 Code (the server says so; a T3 Code pairing simply has no such bot).
    var threadMissing: Bool? = nil
}

struct Last: Codable, Hashable {
    let text: String
    let at: String
    let from: String
}

struct Card: Codable, Identifiable, Hashable {
    let id: String
    let source: String
    let agent: String
    let rank: Int
    let title: String
    let detail: String?
    let why: String?
    let steps: String?
    let urgency: String?
    let customer: Bool?
    let minutes: Double?
    let desk: String?
    let deskName: String?
    let key: String?
    let at: String
    let threadId: String?
    let threadTitle: String?
    let requestId: String?
    let requestKind: String?
    let questions: [Question]?
    let kind: String?
    let link: String?
    let draft: Draft?
    let fields: [CardField]?
    let checks: [CardCheck]?
    let edit: CardEdit?
    let actions: [CardAction]?

    var isQuestion: Bool { source == "question" }
    var isApproval: Bool { isQuestion && requestKind == "command" }
}

/// The generic parts any card source can fill (see server/t3bot.ts, type Card).
struct CardField: Codable, Hashable { let label: String; let value: String }
struct CardCheck: Codable, Hashable { let label: String; let state: String }
struct CardEdit: Codable, Hashable { let label: String; let text: String }
struct CardAction: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let kind: String
    let style: String?
    let faceId: Bool?
}

struct AppSettings: Codable, Equatable {
    struct Quiet: Codable, Equatable { var enabled: Bool; var from: String; var to: String; var alarms: Bool }
    struct Brief: Codable, Equatable { var enabled: Bool; var at: String; var agent: String }
    var quiet: Quiet
    var brief: Brief
    var quickReplies: [String]
}

struct Draft: Codable, Hashable {
    let to: String?
    let text: String?
    let via: String?
    let subject: String?
    let event: String?
    let start: String?
    let end: String?
    let location: String?
}

struct Question: Codable, Hashable, Identifiable {
    let id: String
    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [Option]
}

struct Option: Codable, Hashable {
    let label: String
    let description: String?
}

struct Routine: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    var enabled: Bool
    let when: String
    let nextRunAt: String?
    let lastRunAt: String?
    let lastRunStatus: String?
    let own: Bool
}

struct Timeline: Codable {
    let agent: Agent
    let routines: [Routine]
    let entries: [Entry]
    let working: Bool
    let cards: [Card]
    let runs: [RunInfo]
    /// A group chat's members, live: who is answering right now.
    let members: [Agent]?
}

struct Entry: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let text: String
    let at: String
    let steps: [String]
    let working: Bool?
    var suggestions: [String]? = nil
    var auto: Bool? = nil
    var images: [EntryImage]? = nil

    /// Automated traffic (a lane's TODO notice, the morning brief dump, a schedule): folded in the chat.
    var isAutomatic: Bool { type == "auto" || auto == true }
}

struct RunInfo: Codable, Identifiable, Hashable {
    var id: String { threadId }
    let threadId: String
    let title: String
    let status: String
    let at: String
    let text: String
}

struct Note: Codable, Identifiable, Hashable {
    let id: String
    let agent: String
    let kind: String
    let title: String
    let body: String?
    let created_at: String
}

struct KnowList: Codable { let notes: [Note] }

struct Reply: Codable {
    let ok: Bool?
    let error: String?
    let agent: String?
    var id: String? = nil
    /// `v1/test-push`: how many devices the server sent to.
    var devices: Int? = nil
}

// MARK: - Time

enum Ago {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()

    static func date(_ s: String) -> Date? {
        iso.date(from: s) ?? isoPlain.date(from: s) ?? local.date(from: String(s.prefix(16)))
    }

    static func short(_ s: String) -> String {
        guard let d = date(s) else { return "" }
        let sec = Date().timeIntervalSince(d)
        if sec < 60 { return "now" }
        if sec < 3600 { return "\(Int(sec / 60))m" }
        if sec < 86400 { return "\(Int(sec / 3600))h" }
        return "\(Int(sec / 86400))d"
    }

    static func clock(_ s: String) -> String {
        guard let d = date(s) else { return "" }
        return d.formatted(Calendar.current.isDateInToday(d) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
    }
}

struct EntryImage: Codable, Hashable { let path: String; let alt: String }
