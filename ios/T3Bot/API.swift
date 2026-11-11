import Foundation

// The calls the app makes, by path ("v1/home", "v1/agents/<id>/send"): to the T3 Bot server (server/t3bot.ts), or,
// when the phone is paired with T3 Code itself, to DirectBackend through DirectRouter (ios/Direct), which answers the
// same paths with the same models (ios/Direct/Sources/T3Direct/Models.swift). Which one, and with which token, comes
// from Connection (ios/Shared/Connection.swift), read at call time, so a new pairing works without a relaunch.

enum APIError: LocalizedError {
    case status(Int, String)
    case notPaired
    /// From T3 Code directly: already a sentence for the person.
    case message(String)
    var errorDescription: String? {
        switch self {
        case .status(401, _), .status(403, _): return "The server refused this token. Pair again in Settings."
        case let .status(code, body): return "Server answered \(code): \(body.prefix(200))"
        case .notPaired: return "Not connected to a server yet."
        case let .message(m): return m
        }
    }

    /// A direct-mode failure in the app's terms: a refused token still reads as 401, so the app asks to pair again.
    static func from(_ error: Error) -> Error {
        if let e = error as? T3Error {
            if e.isAuth { return APIError.status(401, e.localizedDescription) }
            if case let .http(code, body) = e { return APIError.status(code, body) }
            return APIError.message(e.localizedDescription)
        }
        if let u = error as? URLError { return APIError.message(T3Link.why(u, host: Connection.current?.label ?? "T3 Code")) }
        return error
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
    ///
    /// The sessions are replaced after a failure, when the app comes back on screen and when the network changes
    /// (`rebuildSessions`): a connection kept from before can be dead without the phone knowing (the server closed
    /// it while the app slept, the VPN tunnel went away), and every request sent on it only times out.
    static var session: URLSession { sessions.withLock { pair in Self.ready(&pair).quick } }

    /// For the two requests the server answers only once slow work is done (a new bot's thread and picture, an
    /// edit that draws a new picture): cut at 12 s, the app would say "failed" while the server carries on.
    static var patient: URLSession { sessions.withLock { pair in Self.ready(&pair).patient } }

    private static let sessions = Locked<(quick: URLSession, patient: URLSession)?>(nil)

    private static func ready(_ pair: inout (quick: URLSession, patient: URLSession)?) -> (quick: URLSession, patient: URLSession) {
        if let pair { return pair }
        let q = URLSessionConfiguration.default
        q.timeoutIntervalForRequest = 12
        q.timeoutIntervalForResource = 20
        q.waitsForConnectivity = false
        q.httpMaximumConnectionsPerHost = 6
        q.requestCachePolicy = .reloadIgnoringLocalCacheData
        let p = URLSessionConfiguration.default
        p.timeoutIntervalForRequest = 25
        p.timeoutIntervalForResource = 30
        p.waitsForConnectivity = false
        p.requestCachePolicy = .reloadIgnoringLocalCacheData
        let made = (quick: URLSession(configuration: q), patient: URLSession(configuration: p))
        pair = made
        return made
    }

    /// New sessions, so new connections, for every request from now on. Requests already on their way finish on
    /// the old ones (a message being sent is never cut).
    static func rebuildSessions() {
        let old = sessions.withLock { pair -> (quick: URLSession, patient: URLSession)? in
            let was = pair
            pair = nil
            return was
        }
        guard let old else { return }
        // Closed a minute later, not now: a caller that read `session` a moment ago may be about to start its
        // request on it, and a session already closed would refuse it (URLSession raises an exception). Every
        // request here ends within 30 s.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            old.quick.finishTasksAndInvalidate()
            old.patient.finishTasksAndInvalidate()
        }
    }

    /// Runs `op` and gives up after `seconds`, whatever it is waiting on: a call that hangs never holds its caller.
    /// The work is cancelled when the time is up, and when the caller is cancelled.
    static func within(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let done = Locked(false)
        let first: @Sendable () -> Bool = { done.withLock { was in defer { was = true }; return !was } }
        let work = Locked<Task<Void, Never>?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                let t = Task {
                    do {
                        let v = try await op()
                        if first() { c.resume(returning: v) }
                    } catch {
                        if first() { c.resume(throwing: error) }
                    }
                }
                work.withLock { $0 = t }
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    if first() {
                        t.cancel()
                        c.resume(throwing: URLError(.timedOut))
                    }
                }
                if Task.isCancelled, first() {
                    t.cancel()
                    c.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            work.withLock { $0 }?.cancel()
        }
    }

    /// True for a request that was stopped on purpose (the app left the screen, a newer try replaced it): not a
    /// sign that the server is away.
    static func wasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// Why a request failed, short enough for one line in Settings and with nothing secret in it (no token, no
    /// request, only the server's name): "mac:8809 did not answer in time (timed out)".
    static func reason(_ error: Error, _ c: Connection) -> String {
        let host = c.label
        if case let APIError.status(code, _) = error {
            return code == 401 || code == 403 ? "\(host) refused this phone's token (answer \(code))" : "\(host) answered with an error (\(code))"
        }
        if case let APIError.message(m) = error { return String(m.prefix(280)) }
        if error is DecodingError { return "\(host) answered with something this app version cannot read" }
        guard let u = error as? URLError else { return "\(host) did not answer: \(String(error.localizedDescription.prefix(120)))" }
        switch u.code {
        case .timedOut: return "\(host) did not answer in time (timed out)"
        case .notConnectedToInternet, .dataNotAllowed: return "This phone had no network"
        case .cannotFindHost, .dnsLookupFailed: return "The name \(host) was not found (is Tailscale connected on this phone?)"
        case .cannotConnectToHost: return "Nothing answered at \(host) (connection refused)"
        case .networkConnectionLost: return "The connection to \(host) dropped"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "The secure connection to \(host) failed (code \(u.code.rawValue))"
        case .appTransportSecurityRequiresSecureConnection: return "iOS blocked plain http to \(host)"
        default: return "\(host) did not answer (network error \(u.code.rawValue))"
        }
    }

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

    /// `timeout` caps the whole call, in both modes (Home's refresh uses it: a short first try, then a second one).
    static func get<T: Decodable>(_ path: String, as: T.Type = T.self, timeout: TimeInterval? = nil) async throws -> T {
        if let direct = DirectLink.current {
            do {
                let data: Data
                if let timeout {
                    data = try await within(timeout) { try await DirectRouter.get(direct, path) }
                } else {
                    data = try await DirectRouter.get(direct, path)
                }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                if wasCancelled(error) { throw CancellationError() }
                throw APIError.from(error)
            }
        }
        var req = request(path)
        let data: Data
        if let timeout {
            req.timeoutInterval = timeout
            let r = req
            let s = session
            data = try await within(timeout) {
                let (data, resp) = try await s.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw APIError.status(code, String(decoding: data, as: UTF8.self)) }
                return data
            }
        } else {
            let (d, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw APIError.status(code, String(decoding: d, as: UTF8.self)) }
            data = d
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any] = [:], patient: Bool = false) async throws -> Reply {
        if let direct = DirectLink.current {
            do { return try await DirectRouter.post(direct, path, body) } catch { throw APIError.from(error) }
        }
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
        guard !c.isDirect else { return }
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
