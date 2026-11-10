import Foundation

// The T3 Bot server (server/t3bot.ts): the models it answers with and the calls the app makes.
// Which server, and with which token, comes from Connection (ios/Shared/Connection.swift), read at call time,
// so a new pairing works without a relaunch.

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

enum APIError: LocalizedError {
    case status(Int, String)
    case notPaired
    var errorDescription: String? {
        switch self {
        case .status(401, _), .status(403, _): return "The server refused this token. Pair again in Settings."
        case let .status(code, body): return "Server answered \(code): \(body.prefix(200))"
        case .notPaired: return "Not connected to a server yet."
        }
    }
}

/// Why a URL and token did not pair, in words the connect screen can show as they are.
enum PairingError: LocalizedError, Equatable {
    case badAddress
    case unreachable(String)
    case wrongToken
    case notT3Bot

    var title: String {
        switch self {
        case .badAddress: return "That address does not look right"
        case .unreachable: return "Can't reach the server"
        case .wrongToken: return "Wrong token"
        case .notT3Bot: return "Not a T3 Bot server"
        }
    }

    var advice: String {
        switch self {
        case .badAddress: return "Use the address t3bot pair prints, like https://my-mac.example.ts.net:8809."
        case let .unreachable(why): return why
        case .wrongToken: return "The server is there but refused the token. Run t3bot pair on your Mac and use the link it prints."
        case .notT3Bot: return "Something answers at that address, but it is not T3 Bot. Check the address and the port."
        }
    }

    var errorDescription: String? { "\(title). \(advice)" }
}

enum API {
    /// Short timeouts: a tap must never hang. A VPN on the phone can take a few seconds to wake up,
    /// so callers retry once instead of waiting long.
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// For the two requests the server answers only once slow work is done (a new bot's thread and picture, an
    /// edit that draws a new picture): cut at 12 s, the app would say "failed" while the server carries on.
    static let patient: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// The paired server, read each time. With no pairing the address resolves nowhere, so a stray call
    /// fails at once instead of reaching someone else's server.
    static var base: URL { Connection.current?.url ?? nowhere }
    static var token: String { Connection.current?.token ?? "" }
    private static let nowhere = URL(string: "https://t3bot.invalid")!

    /// "sandbox" for a development build, "production" for one signed for TestFlight or the App Store.
    static let apnsEnv: String = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "T3BotAPNSEnv") as? String) ?? ""
        return s == "production" ? "production" : "sandbox"
    }()

    /// A path on the paired server ("v1/home", "/v1/avatars/x.png?v=3"), or a full URL left as it is.
    static func url(_ path: String) -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let u = URL(string: path) { return u }
        return Connection.current?.endpoint(path) ?? nowhere.appendingPathComponent(path)
    }

    static func skin(_ n: String) -> URL { url("v1/avatars/skins/\(n).png") }

    static func avatar(_ agent: String) -> URL {
        if let path = Store.cache.withLock({ $0[agent] })?.avatar, !path.isEmpty { return url(path) }
        return url("v1/avatars/\(agent).png")
    }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        // The path keeps its query string ("v1/search?q=...").
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.timeoutInterval = 12
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    static func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        let (data, resp) = try await session.data(for: request(path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.status(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], patient: Bool = false) async throws -> Reply {
        var req = request(path, method: "POST", body: body)
        if patient { req.timeoutInterval = 25 }
        let (data, resp) = try await (patient ? self.patient : session).data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply(ok: code == 200, error: nil, agent: nil)
        guard code == 200, reply.ok != false else {
            throw APIError.status(code, reply.error ?? String(decoding: data, as: UTF8.self))
        }
        return reply
    }

    /// Tells a server to stop pushing to this phone. Best effort, on the connection given, so it still reaches
    /// the old server while the app moves to another one. A server without the route answers 404, which is fine.
    static func forgetDevice(_ deviceToken: String, on c: Connection) {
        guard var r = c.request("v1/devices/remove", timeout: 6) else { return }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["token": deviceToken])
        let request = r
        Task { _ = try? await session.data(for: request) }
    }

    static func cardAction(_ card: Card, _ action: String, text: String? = nil) async throws -> Reply {
        var body: [String: Any] = ["id": card.id]
        if let text { body["text"] = text }
        return try await post("v1/cards/\(action)", body)
    }

    // MARK: - Pairing

    /// Checks a URL and token before they are saved: is a T3 Bot server there, and does it take this token.
    /// Throws a PairingError that says which of the three went wrong.
    static func hello(_ c: Connection) async throws -> Hello {
        guard var req = c.request("v1/hello", timeout: 8) else { throw PairingError.badAddress }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw PairingError.unreachable(why(error, c))
        }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            if let h = try? JSONDecoder().decode(Hello.self, from: data), h.ok == true, h.name != nil || h.version != nil { return h }
            throw PairingError.notT3Bot
        case 401, 403:
            // T3 Bot answers /health without a token; anything else at this address is another service.
            if await healthy(c) { throw PairingError.wrongToken }
            throw PairingError.notT3Bot
        case 404:
            // A T3 Bot server from before /v1/hello: its Home answers with this token.
            guard let home = c.request("v1/home", timeout: 8), let (d, r) = try? await session.data(for: home) else { throw PairingError.notT3Bot }
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw PairingError.wrongToken }
            guard code == 200, (try? JSONDecoder().decode(Home.self, from: d)) != nil else { throw PairingError.notT3Bot }
            return Hello(ok: true, name: "T3 Bot")
        default:
            throw PairingError.notT3Bot
        }
    }

    private static func healthy(_ c: Connection) async -> Bool {
        guard let u = c.endpoint("health") else { return false }
        var r = URLRequest(url: u)
        r.timeoutInterval = 6
        guard let (data, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["ok"] as? Bool == true
    }

    /// A network failure in plain words, with what to try.
    private static func why(_ error: Error, _ c: Connection) -> String {
        let host = c.label
        guard let code = (error as? URLError)?.code else { return "\(host) did not answer: \(error.localizedDescription)" }
        switch code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "This phone is offline. Turn on Wi-Fi or mobile data and try again."
        case .cannotFindHost, .dnsLookupFailed:
            return "No server is called \(host). If it is on your tailnet, check that Tailscale is connected on this phone."
        case .cannotConnectToHost, .networkConnectionLost:
            return "Nothing answers at \(host). Check that the T3 Bot server is running on your Mac and that the port is right."
        case .timedOut:
            return "\(host) did not answer in time. Check that the Mac is awake and that this phone is on the same network or tailnet."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS only allows plain http to a local address. Use the https address of your Mac (Tailscale Serve gives one)."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "The secure connection to \(host) failed. If the server speaks plain http, start the address with http://."
        default:
            return "\(host) did not answer: \(error.localizedDescription)"
        }
    }
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
