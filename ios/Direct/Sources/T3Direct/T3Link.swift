import Foundation

// Pairing with a T3 Code environment, and the plain HTTP calls to it.
//
// T3 Code pairs any client with a one-time code (`t3 pair`, or Settings > Sharing & access > Create link): the
// client trades the code at POST /oauth/token for a bearer token that lasts 30 days. Nothing checks which app
// asks. The same works through the T3 Connect address (https://<name>.t3coderelay.com), which reaches the Mac
// from anywhere. Every snapshot call carries the protocol header; thread ids (`mcp:<uuid>`) are percent-encoded.

/// What a person gave to pair: a T3 Code address and a one-time code.
struct T3PairingInput: Equatable {
    var base: URL
    var code: String
}

enum T3PairingError: LocalizedError, Equatable {
    case badAddress
    case noCode
    case unreachable(String)
    case notT3Code
    case tooNew(Int)
    /// The protocol version it speaks and its own version ("" when it gives none).
    case tooOld(Int, String)
    case codeRefused
    case refused(Int, String)

    var title: String {
        switch self {
        case .badAddress: return "That address does not look right"
        case .noCode: return "The pairing code is missing"
        case .unreachable: return "Can't reach T3 Code"
        case .notT3Code: return "Not a T3 Code address"
        case .tooNew: return "This T3 Code is too new"
        case .tooOld: return "This T3 Code is too old"
        case .codeRefused: return "That code did not work"
        case .refused: return "T3 Code said no"
        }
    }

    var advice: String {
        switch self {
        case .badAddress: return "Use the address T3 Code shows, like https://my-mac.tailnet.ts.net or your T3 Connect address."
        case .noCode: return "In T3 Code, open Settings > Sharing & access and create a link, then scan its QR code or copy its code."
        case let .unreachable(why): return why
        case .notT3Code: return "Something answers at that address, but it is not T3 Code. Check the address."
        case let .tooNew(v): return "It speaks version \(v) of T3 Code's protocol, which this T3 Bot does not know yet. Update T3 Bot."
        case let .tooOld(v, version):
            return "It is T3 Code\(version.isEmpty ? "" : " \(version)") and speaks version \(v) of T3 Code's protocol. T3 Bot needs version \(T3Link.protocolVersion), which came with T3 Code \(T3Link.minimumT3Code). Update T3 Code on your Mac, then pair again."
        case .codeRefused: return "Codes work once and only for a few minutes. Create a new link in T3 Code and try again."
        case let .refused(code, body): return "It answered \(code)\(body.isEmpty ? "" : ": \(body.prefix(160))")."
        }
    }

    var errorDescription: String? { "\(title). \(advice)" }
}

/// `GET /.well-known/t3/environment`: who answers, open to anyone.
struct T3Descriptor: Codable, Equatable {
    var environmentId: String
    @Soft var label: String? = nil
    @Soft var platform: T3Platform? = nil
    @Soft var serverVersion: String? = nil
    @Soft var orchestrationProtocolVersion: Int? = nil

    struct T3Platform: Codable, Equatable { var os: String? }
}

enum T3Link {
    static let protocolVersion = 2
    static let protocolHeader = "x-t3-orchestration-protocol"
    /// The first T3 Code that speaks protocol 2: nightly 0.0.46-nightly.20261003, first stable release 0.1.0.
    static let minimumT3Code = "0.1.0"

    /// Whether this T3 Bot can talk to what answered. T3 Code itself only accepts a client that speaks exactly
    /// its protocol version (HTTP 426 otherwise), so an older or a newer one is refused here, in plain words,
    /// before a code is spent. A descriptor with no version is a host from before the versions (protocol 1).
    static func check(_ d: T3Descriptor) throws {
        let v = d.orchestrationProtocolVersion ?? 1
        if v > protocolVersion { throw T3PairingError.tooNew(v) }
        if v < protocolVersion { throw T3PairingError.tooOld(v, d.serverVersion ?? "") }
    }

    /// T3 Code's refusal of a client whose protocol it does not speak (426 with
    /// `{"code":"orchestration_protocol_incompatible","orchestrationProtocolVersion":N}`), in plain words; nil for any other body.
    static func protocolRefusal(_ body: String) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        guard json?["code"] as? String == "orchestration_protocol_incompatible" || body.contains("orchestration_protocol_incompatible") else { return nil }
        guard let v = (json?["orchestrationProtocolVersion"] as? NSNumber)?.intValue else {
            return "This T3 Code speaks another version of its protocol than this T3 Bot (version \(protocolVersion)). Update T3 Bot and T3 Code."
        }
        if v > protocolVersion { return "This T3 Code speaks version \(v) of its protocol, which this T3 Bot (version \(protocolVersion)) does not know yet. Update T3 Bot." }
        return "This T3 Code speaks version \(v) of its protocol; T3 Bot needs version \(protocolVersion), which came with T3 Code \(minimumT3Code). Update T3 Code on your Mac."
    }

    // MARK: Reading what a person gives

    /// A pairing link as T3 Code makes it, alone or inside other text:
    /// `https://host/pair#token=X`, `t3code://pair?pairingUrl=<that>`, `https://app.t3.codes/pair?host=H#token=X`.
    static func parse(link text: String) -> T3PairingInput? {
        for word in text.components(separatedBy: .whitespacesAndNewlines) {
            var w = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[],"))
            // A link at the end of a sentence: the full stop is not part of the code.
            while let last = w.last, ".,;!".contains(last) { w.removeLast() }
            if let p = parseOne(w) { return p }
        }
        return nil
    }

    private static func parseOne(_ s: String) -> T3PairingInput? {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        // t3code://pair?pairingUrl=... (also t3code-dev:, t3code-preview:)
        if scheme.hasPrefix("t3code"), url.host == "pair" {
            let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pairingUrl" }?.value
            return inner.flatMap(parseOne)
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        let token = token(in: url)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // The hosted form: the real address is in ?host=
        if let host = comps?.queryItems?.first(where: { $0.name == "host" })?.value?.trimmingCharacters(in: .whitespaces), !host.isEmpty {
            guard let token, let base = baseURL(host) else { return nil }
            return T3PairingInput(base: base, code: token)
        }
        guard let token, let base = baseURL(url.absoluteString) else { return nil }
        return T3PairingInput(base: base, code: token)
    }

    /// The code in `#token=` (or `?token=`).
    private static func token(in url: URL) -> String? {
        if let f = url.fragment {
            for pair in f.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "token" {
                    let v = (kv[1].removingPercentEncoding ?? kv[1]).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { return v }
                }
            }
        }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value?.trimmingCharacters(in: .whitespaces)
        return q?.isEmpty == false ? q : nil
    }

    /// An address as typed, pasted or found in a link, as the base of the environment: scheme, host and port
    /// only. "Copy MCP URL" in T3 Code gives `https://<address>/mcp`, which works too. With no scheme, an IP
    /// address, localhost or a .local name gets http (the same network); any other name gets https.
    static func baseURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if s.lowercased().hasPrefix("ws://") { s = "http://" + s.dropFirst(5) }
        if s.lowercased().hasPrefix("wss://") { s = "https://" + s.dropFirst(6) }
        if !s.contains("://") {
            let host = s.split(separator: "/").first.map(String.init) ?? s
            // "[fe80::1]:3773" is an IPv6 address; a name with no dot ("my-mac", a tailnet short name) is on this network.
            let name = host.hasPrefix("[") ? host : (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
            let isAddress = host.hasPrefix("[") || (!name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." })
            let local = isAddress || !name.contains(".") || name.hasSuffix(".local")
            s = (local ? "http://" : "https://") + s
        }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.path = ""
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.url
    }

    // MARK: Calls

    static func url(_ base: URL, _ path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        let rest = path.hasPrefix("/") ? path : "/" + path
        // A path T3 Code sent that is not a URL as it stands (a space, an odd character) is encoded, never a crash.
        return URL(string: s + rest)
            ?? rest.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: s + $0) }
            ?? base
    }

    /// A thread id as one path segment (`mcp:abc` -> `mcp%3Aabc`).
    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? id
    }

    static func descriptor(_ base: URL, session: URLSession) async throws -> T3Descriptor {
        var r = URLRequest(url: url(base, "/.well-known/t3/environment"))
        r.timeoutInterval = 10
        let (data, resp) = try await session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let d = try? JSONDecoder().decode(T3Descriptor.self, from: data), !d.environmentId.isEmpty else {
            throw T3PairingError.notT3Code
        }
        return d
    }

    /// Trades a one-time code for a bearer token. `label` is what T3 Code lists under Sharing & access.
    static func exchange(_ input: T3PairingInput, label: String, os: String, session: URLSession) async throws -> (token: String, expiresIn: TimeInterval, scope: String) {
        var r = URLRequest(url: url(input.base, "/oauth/token"))
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", input.code),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("client_label", label),
            ("client_device_type", "mobile"),
            ("client_os", os),
        ]
        r.httpBody = form(fields).data(using: .utf8)
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 200, let token = json["access_token"] as? String, !token.isEmpty {
            return (token, (json["expires_in"] as? Double) ?? 30 * 86400, json["scope"] as? String ?? "")
        }
        if code == 400 || code == 401 || code == 403 { throw T3PairingError.codeRefused }
        throw T3PairingError.refused(code, (json["error_description"] as? String) ?? (json["error"] as? String) ?? "")
    }

    private static func form(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }

    /// A ticket for one websocket connection (5 minutes).
    static func ticket(_ base: URL, token: String, session: URLSession) async throws -> String {
        var r = URLRequest(url: url(base, "/api/auth/websocket-ticket/rpc"))
        r.httpMethod = "POST"
        r.timeoutInterval = 10
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw T3Error.http(code, String(decoding: data.prefix(300), as: UTF8.self)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = json["ticket"] as? String, !t.isEmpty else {
            throw T3Error.decode("websocket ticket")
        }
        return t
    }

    static func socketURL(_ base: URL, ticket: String) -> URL {
        var c = URLComponents(url: url(base, "/ws"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        c.percentEncodedQuery = "orchestrationProtocol=\(protocolVersion)&wsTicket=\(ticket.addingPercentEncoding(withAllowedCharacters: allowed) ?? ticket)"
        return c.url!
    }

    /// A GET on the environment's HTTP API with the token and the protocol header.
    static func get(_ base: URL, _ path: String, token: String, session: URLSession, timeout: TimeInterval = 20) async throws -> Data {
        var r = URLRequest(url: url(base, path))
        r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(String(protocolVersion), forHTTPHeaderField: protocolHeader)
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // T3 Code checks the protocol header against its own version and answers a bare 400 when they differ
            // (404 when the path is from another version). Ask it who it is, to say that in plain words.
            if code == 400 || code == 404 || code == 426, let why = await protocolProblem(base, session: session) { throw T3Error.rpc(why) }
            throw T3Error.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }

    /// "This T3 Code is too old ..." or "... too new ..." when what answers at `base` speaks another protocol
    /// than this T3 Bot (it was updated, or replaced, after pairing); nil when it speaks ours or does not answer.
    static func protocolProblem(_ base: URL, session: URLSession) async -> String? {
        guard let d = try? await descriptor(base, session: session) else { return nil }
        do { try check(d); return nil } catch { return (error as? T3PairingError)?.errorDescription }
    }

    /// A network failure in plain words, with what to try.
    static func why(_ error: Error, host: String) -> String {
        guard let code = (error as? URLError)?.code else { return "\(host) did not answer: \(error.localizedDescription)" }
        switch code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "This phone is offline. Turn on Wi-Fi or mobile data and try again."
        case .cannotFindHost, .dnsLookupFailed:
            return "No server is called \(host). For a tailnet address, check that Tailscale is connected on this phone."
        case .cannotConnectToHost, .networkConnectionLost:
            return "Nothing answers at \(host). Check that T3 Code is running on your Mac, and for a home address that network access is on in its settings."
        case .timedOut:
            return "\(host) did not answer in time. Check that the Mac is awake."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS only allows plain http to a local address. Use your T3 Connect or Tailscale address."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "The secure connection to \(host) failed. If T3 Code speaks plain http there, start the address with http://."
        default:
            return "\(host) did not answer: \(error.localizedDescription)"
        }
    }

    /// The whole pairing: who answers, then the code for a token.
    static func pair(_ input: T3PairingInput, label: String, os: String, session: URLSession) async throws -> (token: String, descriptor: T3Descriptor) {
        let host = input.base.host ?? input.base.absoluteString
        let d: T3Descriptor
        do { d = try await descriptor(input.base, session: session) } catch let e as T3PairingError { throw e } catch { throw T3PairingError.unreachable(why(error, host: host)) }
        try check(d)
        do {
            let t = try await exchange(input, label: label, os: os, session: session)
            return (t.token, d)
        } catch let e as T3PairingError { throw e } catch { throw T3PairingError.unreachable(why(error, host: host)) }
    }
}

enum T3Error: LocalizedError, Equatable {
    case http(Int, String)
    case decode(String)
    case rpc(String)
    case closed
    case timeout
    case notConnected

    var errorDescription: String? {
        switch self {
        case .http(401, _), .http(403, _): return "T3 Code refused this phone's token. Pair again in Settings."
        case let .http(426, body): return T3Link.protocolRefusal(body) ?? "T3 Code answered 426: \(body.prefix(160))"
        case let .http(code, body): return "T3 Code answered \(code): \(body.prefix(160))"
        case let .decode(what): return "T3 Code sent \(what) in a form this T3 Bot does not read. Update T3 Bot."
        case let .rpc(why): return why
        case .closed: return "The connection to T3 Code closed before it answered."
        case .timeout: return "T3 Code did not answer in time."
        case .notConnected: return "Not connected to T3 Code."
        }
    }

    var isAuth: Bool {
        if case let .http(code, _) = self { return code == 401 || code == 403 }
        return false
    }
}
