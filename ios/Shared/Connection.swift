import Foundation
import Security

/// Where this phone's bots are, and the token that opens it: a T3 Bot server (`kind == .server`), or T3 Code
/// itself (`.t3code`, paired with one of its codes; ios/Direct talks to it).
///
/// The app saves a pairing to its UserDefaults and mirrors it to a Keychain access group it shares with its
/// extensions (notifications, widgets, share sheet), which cannot read the app's defaults. A build can also
/// carry a connection in its Info.plist (`T3BotURL`, `T3BotToken`); it is used when nothing was paired, so a
/// personal build works with no pairing step.
///
/// Compiled into all four targets. Foundation and Security only.
struct Connection: Equatable {
    enum Kind: String { case server, t3code }

    let url: URL
    let token: String
    var kind: Kind = .server
    /// T3 Code's environment id and name (`My Mac`), for a `.t3code` pairing.
    var environmentId: String? = nil
    var name: String? = nil

    init(url: URL, token: String, kind: Kind = .server, environmentId: String? = nil, name: String? = nil) {
        self.url = url
        self.token = token
        self.kind = kind
        self.environmentId = environmentId
        self.name = name
    }

    /// True when the app talks to T3 Code directly, with no T3 Bot server.
    var isDirect: Bool { kind == .t3code }

    /// What the screens call this server: its host, with the port when it is not the default one.
    var label: String {
        if isDirect, let name, !name.isEmpty { return name }
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// `<server>/<path>`. The path may carry a query string ("v1/search?q=...") and must already be encoded.
    func endpoint(_ path: String) -> URL? {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let rest = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: base + "/" + rest)
    }

    /// A request to this server with its token.
    func request(_ path: String, timeout: TimeInterval = 12) -> URLRequest? {
        guard let u = endpoint(path) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    // MARK: - Where it comes from

    enum Source { case arguments, paired, builtIn }

    private enum Keys {
        static let url = "t3bot.connection.url"
        static let token = "t3bot.connection.token"
        static let kind = "t3bot.connection.kind"
        static let environment = "t3bot.connection.environment"
        static let name = "t3bot.connection.name"
        /// Set by Disconnect, so a build that carries a connection does not reconnect by itself.
        static let off = "t3bot.connection.off"
    }

    /// The connection in use and where it came from, read fresh: launch arguments (debug builds), what the
    /// app saved, the shared Keychain, then the build's own values.
    static func resolve() -> (connection: Connection, source: Source)? {
        #if DEBUG
        if let c = fromArguments { return (c, .arguments) }
        #endif
        let d = UserDefaults.standard
        if var c = make(d.string(forKey: Keys.url), d.string(forKey: Keys.token)) {
            c.kind = Kind(rawValue: d.string(forKey: Keys.kind) ?? "") ?? .server
            c.environmentId = d.string(forKey: Keys.environment)
            c.name = d.string(forKey: Keys.name)
            return (c, .paired)
        }
        if d.bool(forKey: Keys.off) { return nil }
        switch Keychain.read() {
        case let .paired(c): return (c, .paired)
        case .off: return nil
        case .nothing: break
        }
        if let c = builtIn { return (c, .builtIn) }
        return nil
    }

    /// Read fresh every time. The extensions use this: they live long and must follow a new pairing.
    static func load() -> Connection? { resolve()?.connection }

    /// The connection the app uses, kept in memory and refreshed by `save`, `clear` and `reload`.
    static var current: Connection? { box.get()?.connection }
    static var source: Source? { box.get()?.source }

    static func reload() { box.reset() }

    /// The connection this build carries in its Info.plist, if any.
    static var builtIn: Connection? {
        make(Bundle.main.object(forInfoDictionaryKey: "T3BotURL") as? String,
             Bundle.main.object(forInfoDictionaryKey: "T3BotToken") as? String)
    }

    #if DEBUG
    /// `-t3botURL <url> -t3botToken <token>` at launch: screen checks against a test or demo server.
    /// Never saved, so the stored pairing is back at the next normal launch.
    static var fromArguments: Connection? {
        let args = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard var c = make(value("-t3botURL"), value("-t3botToken")) else { return nil }
        // `-t3botKind t3code -t3botEnv <environment id>`: a T3 Code environment, for screen checks of the direct mode.
        if value("-t3botKind") == "t3code" { c.kind = .t3code; c.environmentId = value("-t3botEnv"); c.name = value("-t3botName") }
        return c
    }
    #endif

    static func save(_ c: Connection) {
        let d = UserDefaults.standard
        d.set(c.url.absoluteString, forKey: Keys.url)
        d.set(c.token, forKey: Keys.token)
        d.set(c.kind.rawValue, forKey: Keys.kind)
        d.set(c.environmentId, forKey: Keys.environment)
        d.set(c.name, forKey: Keys.name)
        d.removeObject(forKey: Keys.off)
        Keychain.write(.paired(c))
        reload()
    }

    /// Forgets the pairing here and in the extensions. A connection the build carries stays off until the
    /// person pairs again.
    static func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.url)
        d.removeObject(forKey: Keys.token)
        d.removeObject(forKey: Keys.kind)
        d.removeObject(forKey: Keys.environment)
        d.removeObject(forKey: Keys.name)
        d.set(true, forKey: Keys.off)
        Keychain.write(.off)
        reload()
    }

    // MARK: - Reading what a person gives

    /// A URL and a token as typed or scanned. Nil when either is missing or the URL makes no sense.
    static func make(_ url: String?, _ token: String?) -> Connection? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let url, let u = normalized(url) else { return nil }
        return Connection(url: u, token: token)
    }

    /// "mac.tailnet.ts.net:8809" or "http://192.168.1.20:8809/" as a clean base URL. With no scheme, an IP
    /// address, localhost or a .local name gets http (a plain server on the same network); any other name
    /// gets https.
    static func normalized(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") {
            let host = s.split(separator: "/").first.map(String.init) ?? s
            let name = host.split(separator: ":").first.map(String.init) ?? host
            let isAddress = !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
            let local = isAddress || name == "localhost" || name.hasSuffix(".local")
            s = (local ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, let u = c.url else { return nil }
        return u
    }

    /// A pairing link, `t3bot://connect?url=<base URL>&token=<token>`, alone or inside other text (what
    /// `t3bot pair` prints, a QR code, the clipboard).
    static func parse(link text: String) -> Connection? {
        guard let start = text.range(of: "t3bot://connect", options: .caseInsensitive) else { return nil }
        let tail = text[start.lowerBound...]
        let link = String(tail.prefix(while: { !$0.isWhitespace && $0 != "\"" && $0 != "'" && $0 != "<" && $0 != ">" }))
        guard let c = URLComponents(string: link) else { return nil }
        let items = c.queryItems ?? []
        return make(items.first(where: { $0.name == "url" })?.value, items.first(where: { $0.name == "token" })?.value)
    }

    /// The link that pairs another device with this connection.
    var pairingLink: String {
        var c = URLComponents()
        c.scheme = "t3bot"
        c.host = "connect"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "token", value: token)]
        return c.string ?? "t3bot://connect"
    }

    // MARK: - In-memory copy for the app

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded = false
        private var value: (connection: Connection, source: Source)?

        func get() -> (connection: Connection, source: Source)? {
            lock.lock(); defer { lock.unlock() }
            if !loaded { value = Connection.resolve(); loaded = true }
            return value
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            loaded = false
            value = nil
        }
    }

    private static let box = Box()

    // MARK: - Shared Keychain

    /// The Keychain access group the app shares with its extensions: `<team prefix>.<bundle id>.shared`,
    /// written into each target's Info.plist at build time. Nil in a build that has none.
    static var keychainGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "T3BotKeychainGroup") as? String,
              !g.isEmpty, !g.hasPrefix("."), !g.hasPrefix("$") else { return nil }
        return g
    }

    /// One generic password in the access group the app and its extensions share. Every failure is silent:
    /// a simulator build without signing has no access group, and the app still works from its defaults.
    private enum Keychain {
        enum Stored { case paired(Connection), off, nothing }

        private static let service = "t3bot.connection"
        private static let account = "pairing"

        private static var group: String? { Connection.keychainGroup }

        private static var query: [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            if let group { q[kSecAttrAccessGroup as String] = group }
            return q
        }

        static func read() -> Stored {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .nothing }
            if json["off"] as? Bool == true { return .off }
            if var c = Connection.make(json["url"] as? String, json["token"] as? String) {
                c.kind = Kind(rawValue: json["kind"] as? String ?? "") ?? .server
                c.environmentId = json["environmentId"] as? String
                c.name = json["name"] as? String
                return .paired(c)
            }
            return .nothing
        }

        static func write(_ stored: Stored) {
            SecItemDelete(query as CFDictionary)
            let json: [String: Any]
            switch stored {
            case let .paired(c):
                var j: [String: Any] = ["url": c.url.absoluteString, "token": c.token, "kind": c.kind.rawValue]
                if let e = c.environmentId { j["environmentId"] = e }
                if let n = c.name { j["name"] = n }
                json = j
            case .off: json = ["off": true]
            case .nothing: return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
            var add = query
            add[kSecValueData as String] = data
            // The notification extension runs while the phone is locked.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
