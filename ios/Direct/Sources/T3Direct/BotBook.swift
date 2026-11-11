import Foundation
import Security

// The bots, with no T3 Bot server: a bot is a T3 Code thread titled `%BOT <Name>` (a group `%BOT Group: <Name>`),
// in any project. What T3 Code cannot hold (the face, the one-line job, hidden, the members of a group, title
// prefixes it watches) lives in the app group's defaults, so the extensions read it too. A bot made on this phone
// also writes it into a marker line of its first message, so another phone reads the same face and job.

struct BotMeta: Codable, Equatable {
    var skin: String?
    var role: String?
    var hidden: Bool?
    var members: [String]?
    var watch: [String]?
}

enum BotBook {
    static let prefix = "%BOT "
    static let groupPrefix = "%BOT Group: "

    /// "%BOT Chief", "%BOT Website (36)" (a desk with its count), "%BOT Group: Launch crew".
    static func parse(title: String) -> (name: String, kind: String)? {
        guard title.hasPrefix(prefix) else { return nil }
        if title.hasPrefix(groupPrefix) {
            let n = clean(String(title.dropFirst(groupPrefix.count)))
            return n.isEmpty ? nil : (n, "group")
        }
        let n = clean(String(title.dropFirst(prefix.count)))
        return n.isEmpty ? nil : (n, "bot")
    }

    /// The name without a trailing count, "(36)".
    private static func clean(_ s: String) -> String {
        T3Text.replace(s, "\\s*\\(\\d+\\)\\s*$", "").trimmingCharacters(in: .whitespaces)
    }

    /// The id the app uses for a bot: its thread id with only lowercase letters, digits and dashes
    /// (`mcp:A4f8...` -> `mcp-a4f8...`), the characters links and the shared Keychain accept.
    static func botId(_ threadId: String) -> String {
        let mapped = threadId.lowercased().unicodeScalars.map { s -> Character in
            ((s.value >= 97 && s.value <= 122) || (s.value >= 48 && s.value <= 57) || s.value == 45) ? Character(s) : "-"
        }
        return String(String(mapped).prefix(64))
    }

    static func title(name: String, kind: String) -> String {
        kind == "group" ? groupPrefix + name : prefix + name
    }

    // MARK: Faces

    /// A face picked from the name, so a bot keeps the same face on every phone until someone chooses one.
    /// From a short list of faces that read well small, never the gold one (it reads as a warning).
    static let pleasant = ["101", "102", "103", "104", "105", "106", "401", "402", "403", "404", "405", "406", "206", "301", "302", "303"]
        .filter { Skins.isSkin($0) }

    static func defaultSkin(for name: String) -> String {
        // The one that leads wears gold everywhere: in the app, the demo, notifications and widgets.
        if name.lowercased() == "chief", Skins.all.contains(where: { $0.n == "902" }) { return "902" }
        let list = pleasant.isEmpty ? ["101"] : pleasant
        // FNV-1a: stable across launches and devices (Swift's hashValue is not).
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.lowercased().utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return list[Int(h % UInt64(list.count))]
    }

    /// The face farthest in color from the ones already used, like the server's `freeSkin`.
    static func freeSkin(used: [String]) -> String {
        let usedInfo = used.compactMap { u in Skins.all.first { $0.n == u } }
        var best = Skins.all.first?.n ?? "101"
        var score = -1.0
        for c in Skins.all where !used.contains(c.n) {
            let (h, s, l) = hsl(c.color)
            let far: Double = usedInfo.isEmpty ? 1 : usedInfo.map { u in
                let (uh, us, ul) = hsl(u.color)
                let dh = Swift.min(abs(h - uh), 360 - abs(h - uh)) / 180
                return dh * Swift.min(s, us) + abs(l - ul) * 0.8
            }.min() ?? 1
            let sc = far + s * 0.25
            if sc > score { score = sc; best = c.n }
        }
        return best
    }

    static func hsl(_ hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0.5) }
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255
        let mx = Swift.max(r, g, b), mn = Swift.min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s2 = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s2, l)
    }

    // MARK: The marker in a bot's first message

    static let markerStart = "[T3 Bot: "

    /// The last line of a bot's first message: what another phone needs to show it the same way.
    static func marker(skin: String, role: String, kind: String, members: [String]) -> String {
        var d: [String: Any] = ["face": skin, "kind": kind]
        if !role.isEmpty { d["role"] = String(role.prefix(140)) }
        if !members.isEmpty { d["members"] = members }
        let json = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "\(markerStart)\(json)]"
    }

    static func readMarker(_ text: String) -> BotMeta? {
        guard let start = text.range(of: markerStart, options: .backwards) else { return nil }
        let rest = text[start.upperBound...]
        guard let open = rest.firstIndex(of: "{"), let close = rest.lastIndex(of: "}") , open < close,
              let obj = try? JSONSerialization.jsonObject(with: Data(rest[open...close].utf8)) as? [String: Any] else { return nil }
        var m = BotMeta()
        if let f = obj["face"] as? String, Skins.isSkin(f) { m.skin = f }
        if let r = obj["role"] as? String, !r.isEmpty { m.role = r }
        if let ms = obj["members"] as? [String], !ms.isEmpty { m.members = ms }
        return m
    }

    /// The first message's text without the marker line.
    static func withoutMarker(_ text: String) -> String {
        guard let start = text.range(of: markerStart, options: .backwards) else { return text }
        return String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where small shared state is kept: the Keychain access group the app shares with its extensions (the same as
/// the pairing, see Shared/Connection.swift), or plain defaults where there is none (the package's tests).
protocol SmallStore: AnyObject {
    func data(_ key: String) -> Data?
    func set(_ data: Data?, _ key: String)
}

final class DefaultsStore: SmallStore {
    private let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }
    func data(_ key: String) -> Data? { d.data(forKey: key) }
    func set(_ data: Data?, _ key: String) { if let data { d.set(data, forKey: key) } else { d.removeObject(forKey: key) } }
}

final class KeychainStore: SmallStore {
    private let service: String
    private let group: String?
    init(service: String = "t3bot.direct", group: String? = KeychainStore.sharedGroup) { self.service = service; self.group = group }

    /// `T3BotKeychainGroup` from Info.plist, as Connection reads it.
    static var sharedGroup: String? {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "T3BotKeychainGroup") as? String, !g.isEmpty, !g.hasPrefix("."), !g.hasPrefix("$") else { return nil }
        return g
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    func data(_ key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func set(_ data: Data?, _ key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let data else { return }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func clearAll() {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let group { q[kSecAttrAccessGroup as String] = group }
        SecItemDelete(q as CFDictionary)
    }
}

/// The bots' extra details, by thread id.
final class BotStore: @unchecked Sendable {
    static let shared = BotStore(store: KeychainStore())

    private let lock = NSLock()
    private let store: SmallStore
    private let key = "bots"

    init(store: SmallStore) { self.store = store }

    func all() -> [String: BotMeta] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    private func read() -> [String: BotMeta] {
        guard let data = store.data(key), let m = try? JSONDecoder().decode([String: BotMeta].self, from: data) else { return [:] }
        return m
    }

    func get(_ threadId: String) -> BotMeta? { all()[threadId] }

    func update(_ threadId: String, _ change: (inout BotMeta) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var m = read()
        var one = m[threadId] ?? BotMeta()
        change(&one)
        m[threadId] = one
        if let data = try? JSONEncoder().encode(m) { store.set(data, key) }
    }

    /// Fills what this phone does not know yet from a bot's marker, never over what was chosen here.
    func learn(_ threadId: String, from marker: BotMeta) {
        update(threadId) { m in
            if m.skin == nil { m.skin = marker.skin }
            if m.role == nil { m.role = marker.role }
            if m.members == nil { m.members = marker.members }
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.set(nil, key)
    }
}
