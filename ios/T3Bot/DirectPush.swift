import Foundation
import UIKit

/// Notifications for a T3 Code pairing (no T3 Bot server): this phone gets a sealed address from the push sender
/// (push/ in the repo, `T3BotPushHost`), and T3 Bot puts Claude Code hooks in T3 Code's Claude provider settings
/// (ios/Direct/Sources/T3Direct/HookSettings.swift). A Claude thread that asks something, or a bot that answers,
/// then rings this phone; the notification extension reads the words from T3 Code.
///
/// Every phone paired with the same T3 Code adds its own address to the hook, and takes only its own out.
@MainActor
enum DirectPush {
    struct Saved: Codable, Equatable { var address: String; var token: String; var env: String }

    private static let store = KeychainStore()
    private static let key = "push"

    static var host: String? {
        guard let h = Bundle.main.object(forInfoDictionaryKey: "T3BotPushHost") as? String else { return nil }
        let t = h.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.hasPrefix("$") ? nil : t
    }

    static var saved: Saved? {
        guard let d = store.data(key) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: d)
    }

    private static func save(_ s: Saved?) { store.set(s.flatMap { try? JSONEncoder().encode($0) }, key) }

    /// The address the hooks were last written with, set only once that write went through.
    private static var installed: String? {
        get { UserDefaults.standard.string(forKey: "t3bot.direct.push.installed") }
        set { UserDefaults.standard.set(newValue, forKey: "t3bot.direct.push.installed") }
    }

    /// True when the hooks do not ring this phone at `token`: iOS gave it a new push token (a restore, a reinstall),
    /// or the last write of the hooks did not finish. They are then written again.
    static func stale(token: String) -> Bool {
        guard let s = saved, s.token == token, s.env == API.apnsEnv else { return true }
        return installed != s.address
    }

    enum Failure: LocalizedError {
        case noSender, refused(String), otherSettings([String]), secrets([String]), noClaude, scope

        var errorDescription: String? {
            switch self {
            case .noSender: return "This build of T3 Bot has no push sender set."
            case let .refused(why): return "The push sender said no: \(why)"
            case let .otherSettings(names): return "\(names.joined(separator: ", ")) already has its own --settings in T3 Code's launch arguments, so T3 Bot cannot add its hooks there."
            case let .secrets(names): return "\(names.joined(separator: ", ")) keeps a secret in its T3 Code settings, and T3 Bot does not rewrite a provider that has one. Its hooks were left as they are."
            case .noClaude: return "T3 Code runs no Claude provider here. Notifications come from Claude threads."
            case .scope: return "This pairing may not change T3 Code's provider settings. Pair again with a link that has the standard access."
            }
        }
    }

    /// This phone's sealed address for its push token.
    private static func address(token: String) async throws -> String {
        if let s = saved, s.token == token, s.env == API.apnsEnv { return s.address }
        guard let host, let url = URL(string: "https://\(host)/api/address") else { throw Failure.noSender }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "env": API.apnsEnv, "topic": Bundle.main.bundleIdentifier ?? ""])
        let (data, _) = try await API.session.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let a = json["address"] as? String, !a.isEmpty else { throw Failure.refused((json["error"] as? String) ?? "no address") }
        save(Saved(address: a, token: token, env: API.apnsEnv))
        return a
    }

    /// The Claude provider instances of this T3 Code, with their settings entries as read (HookSettings holds the
    /// rules: an entry with environment values is left alone, and nothing read is dropped).
    private static func claudeInstances(_ b: DirectBackend) async throws -> [(id: String, entry: [String: Any])] {
        let v = try await b.call("server.getConfig", [:]) as? [String: Any] ?? [:]
        return HookSettings.claudeInstances(in: v)
    }

    /// True when a provider instance carries a secret anywhere but its launch arguments (HookSettings.holdsSecret).
    static func holdsSecret(_ value: Any, key: String = "") -> Bool { HookSettings.holdsSecret(value, key: key) }

    /// Puts this phone's address in the hooks of every Claude provider (or takes it out with `remove`), with the
    /// bots of now. Returns how many providers ring this phone.
    @discardableResult
    static func apply(token: String?, remove: Bool = false) async throws -> Int {
        guard let b = DirectLink.current else { return 0 }
        guard let host, let ring = URL(string: "https://\(host)/api/ring") else { throw Failure.noSender }
        // This phone's earlier addresses (its push token changed since): they ring nothing now and go out of the hooks.
        let earlier = [installed, saved?.address].compactMap { $0 }
        let mine: String? = remove ? saved?.address : try await address(token: token ?? saved?.token ?? "")
        let home: Home = try await API.get("v1/home")
        // Sorted, so the order the bots come in never makes a write by itself.
        let bots = home.agents.map(\.threadId).sorted()
        let instances = try await claudeInstances(b)
        guard !instances.isEmpty else { throw Failure.noClaude }
        var ringing = 0
        var blocked: [String] = []
        var secret: [String] = []
        for (id, entry) in instances {
            let args = ((entry["config"] as? [String: Any])?["launchArgs"] as? String) ?? ""
            var addresses = HookSettings.addresses(in: args)
            // This phone's address keeps its place: moving it to the end made two phones paired with the same
            // T3 Code rewrite each other's order for ever.
            if let mine {
                if remove { addresses.removeAll { $0 == mine } } else if !addresses.contains(mine) { addresses.append(mine) }
            }
            addresses.removeAll { $0 != mine && earlier.contains($0) }
            let next: String
            if addresses.isEmpty {
                next = HookSettings.strip(args)
            } else {
                do { next = try HookSettings.merged(args, ring: ring, addresses: addresses, bots: bots) } catch { blocked.append(id); continue }
            }
            if !remove { ringing += 1 }
            guard next != args else { continue }
            // The whole instance goes back with the write, as read, with only its launch arguments changed. One that
            // holds a secret (a reference on a newer T3 Code, a hidden value on an older one) is left alone: what was
            // read may not be what T3 Code keeps.
            guard let instance = HookSettings.rewritten(entry, launchArgs: next) else {
                if !remove { ringing -= 1 }
                secret.append(id)
                continue
            }
            do {
                _ = try await b.call("server.updateSettings", ["patch": [String: Any](),
                                                               "providerInstanceMutation": ["operation": "upsert", "instanceId": id, "instance": instance]])
            } catch {
                if error.localizedDescription.lowercased().contains("scope") || error.localizedDescription.lowercased().contains("forbidden") { throw Failure.scope }
                throw error
            }
        }
        if ringing == 0, !blocked.isEmpty, !remove { throw Failure.otherSettings(blocked) }
        if ringing == 0, !secret.isEmpty, !remove { throw Failure.secrets(secret) }
        if remove { save(nil); installed = nil } else { installed = mine }
        return ringing
    }

    /// Turned on for this pairing (kept on the phone; the hooks themselves live in T3 Code).
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: "t3bot.direct.push.on") }
        set { UserDefaults.standard.set(newValue, forKey: "t3bot.direct.push.on") }
    }

    static func turnOn(token: String) async throws -> Int {
        let n = try await apply(token: token)
        isOn = true
        return n
    }

    static func turnOff() async {
        _ = try? await apply(token: nil, remove: true)
        isOn = false
    }

    /// The bots changed: the hooks get the new list (a new bot's replies ring too).
    static func sync() async {
        guard isOn, let token = saved?.token else { return }
        _ = try? await apply(token: token)
    }

    /// A push to this phone now, through the same sender the hooks use.
    static func test() async throws {
        guard let host, let url = URL(string: "https://\(host)/api/ring"), let a = saved?.address else { throw Failure.noSender }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["to": a, "thread": "", "kind": "test"])
        let (data, resp) = try await API.session.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            throw Failure.refused((json["error"] as? String) ?? "status \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }
}
