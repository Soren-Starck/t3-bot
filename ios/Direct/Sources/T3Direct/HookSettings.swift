import Foundation

// Pushes for a T3 Code pairing, with nothing installed on the Mac: Claude Code hooks, given to T3 Code's Claude
// provider in its launch arguments (`--settings '<json>'`, read at every session start). When a Claude thread asks
// for permission or asks a question (PermissionRequest), or a bot's thread finishes a reply (Stop), the hook sends
// one small request to the push sender: which phone (a sealed address), which thread, which kind. The phone then
// reads the text from T3 Code itself, so nothing about the work passes through the push sender.
//
// The thread comes from T3CODE_THREAD_ID, which T3 Code puts in the environment of the Claude process it starts
// (nightly builds from November 2026; older builds do not). Without it a permission request still rings, with an
// empty thread: the phone then shows a plain "A Claude thread needs you" that opens the app. A finished reply does
// not ring, since nothing says whether the thread is a bot's.
//
// The JSON carries a marker (env T3BOT_HOOKS) so T3 Bot finds and replaces only its own part of the launch arguments.

enum HookSettings {
    static let marker = "T3BOT_HOOKS"

    /// The `--settings` JSON. `ring` is the push sender's ring URL; `bots` the threads whose finished replies ring.
    static func json(ring: URL, addresses: [String], bots: [String]) -> String {
        let to = addresses.filter(isSafe)
        let ids = bots.filter(isSafe)
        // A ring address that could end the quoting, or no phone to ring: the marker alone, no command.
        guard isSafe(ring: ring), !to.isEmpty else {
            let data = (try? JSONSerialization.data(withJSONObject: ["env": [marker: "1"]], options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        func curl(_ kind: String) -> String {
            // No single quote anywhere: the whole JSON sits between single quotes in the launch arguments.
            "for a in \(to.joined(separator: " ")); do curl -s -m 6 -X POST -H content-type:application/json --data \"{\\\"to\\\":\\\"$a\\\",\\\"thread\\\":\\\"$T3CODE_THREAD_ID\\\",\\\"kind\\\":\\\"\(kind)\\\"}\" \"\(ring.absoluteString)\" >/dev/null 2>&1 & done; exit 0"
        }
        var hooks: [String: Any] = [
            "PermissionRequest": [["hooks": [["type": "command", "command": curl("request")]]]],
        ]
        if !ids.isEmpty {
            let pattern = ids.joined(separator: "|")
            hooks["Stop"] = [["hooks": [["type": "command", "command": "case \"$T3CODE_THREAD_ID\" in \(pattern)) \(curl("reply")) ;; esac; exit 0"]]]]
        }
        let settings: [String: Any] = ["env": [marker: "1"], "hooks": hooks]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Only letters, digits and `-_:.=` in what goes into the shell command: an address or a thread id that holds
    /// anything else is left out rather than quoted.
    static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 300 && s.unicodeScalars.allSatisfy { c in
            CharacterSet.alphanumerics.contains(c) || "-_:.=".unicodeScalars.contains(c)
        } && s.unicodeScalars.allSatisfy { $0.isASCII }
    }

    /// A ring address that can sit between double quotes in the hook's shell command, itself inside the single
    /// quotes of the launch arguments: http or https, and none of the characters that end or reopen either quoting.
    static func isSafe(ring: URL) -> Bool {
        let s = ring.absoluteString
        guard let scheme = ring.scheme?.lowercased(), scheme == "http" || scheme == "https", ring.host?.isEmpty == false, s.count <= 500 else { return false }
        return s.unicodeScalars.allSatisfy { c in c.isASCII && c.value > 0x20 && c.value != 0x7F && !"'\"$`\\".unicodeScalars.contains(c) }
    }

    /// The launch arguments without T3 Bot's part.
    static func strip(_ args: String) -> String {
        let out = T3Text.replace(args, "\\s*--settings\\s+'[^']*\(marker)[^']*'", "")
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The phones T3 Bot's part already rings (each phone paired with this T3 Code adds its own address).
    static func addresses(in args: String) -> [String] {
        guard let r = T3Text.re("for a in ([^;]*); do").firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
              let list = Range(r.range(at: 1), in: args) else { return [] }
        return args[list].split(separator: " ").map(String.init).filter(isSafe)
    }

    /// True when the launch arguments hold T3 Bot's part.
    static func has(_ args: String) -> Bool { T3Text.matches(args, "--settings\\s+'[^']*\(marker)[^']*'") }

    enum Problem: Error, Equatable { case otherSettings, unsafeRing }

    /// The launch arguments with T3 Bot's part put in (or replaced). Another `--settings` of the person's own
    /// cannot be merged safely: that is a Problem the app explains.
    static func merged(_ args: String, ring: URL, addresses: [String], bots: [String]) throws -> String {
        guard isSafe(ring: ring) else { throw Problem.unsafeRing }
        let base = strip(args)
        if T3Text.matches(base, "(^|\\s)--settings(\\s|=|$)") { throw Problem.otherSettings }
        let ours = "--settings '\(json(ring: ring, addresses: addresses, bots: bots))'"
        return base.isEmpty ? ours : base + " " + ours
    }
}

// The read and the write of a Claude provider instance. T3 Code's `upsert` replaces the whole instance with what
// the client sends (serverSettings.ts, applyProviderInstanceMutation), so the instance goes back exactly as it was
// read, unknown keys included, with `config.launchArgs` the only change. An instance that carries anything secret
// or hidden is never written: what was read may not be what T3 Code keeps.
extension HookSettings {
    /// What T3 Code shows a client in place of a saved secret (settingsSecrets.ts, SECRET_REDACTED).
    static let redactedSecret = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"

    /// The Claude provider instances in a `server.getConfig` answer, each with its settings entry as read (an
    /// implicit default instance has none yet and gets one). An entry with environment values is left out: the
    /// sensitive ones come back hidden or as a reference, and a write would have to send them back untouched.
    static func claudeInstances(in v: [String: Any]) -> [(id: String, entry: [String: Any])] {
        let configured = ((v["settings"] as? [String: Any])?["providerInstances"] as? [String: Any]) ?? [:]
        let providers = (v["providers"] as? [[String: Any]]) ?? []
        var ids = providers.filter { ($0["driver"] as? String) == "claudeAgent" }.compactMap { $0["instanceId"] as? String }
        for id in configured.keys.sorted() where ((configured[id] as? [String: Any])?["driver"] as? String) == "claudeAgent" && !ids.contains(id) { ids.append(id) }
        return ids.compactMap { id in
            let entry = (configured[id] as? [String: Any]) ?? ["driver": "claudeAgent", "enabled": true, "config": [String: Any]()]
            if let env = entry["environment"] {
                // Only an empty list (or an empty object) is safe to send back; any other shape is not ours to guess.
                if let a = env as? [Any] { if !a.isEmpty { return nil } }
                else if let d = env as? [String: Any] { if !d.isEmpty { return nil } }
                else { return nil }
            }
            return (id, entry)
        }
    }

    /// True when a provider instance carries a secret anywhere but its launch arguments: a key named for one
    /// (secret, password, api key) with a value, T3 Code's marker for a hidden secret, a hidden environment value,
    /// or a reference to a secret provider (`{provider, reference}`, secretReference.ts), at any depth.
    static func holdsSecret(_ value: Any, key: String = "") -> Bool {
        let k = key.lowercased()
        if ["secret", "password", "apikey", "api_key"].contains(where: { k.contains($0) }) {
            if value is NSNull || value is Bool { return false }
            if let t = value as? String { return !t.isEmpty }
            if let d = value as? [String: Any] { return !d.isEmpty }
            if let a = value as? [Any] { return !a.isEmpty }
            return true
        }
        if let t = value as? String { return t == redactedSecret }
        if let d = value as? [String: Any] {
            if d["provider"] is String, d["reference"] is String { return true }
            if (d["valueRedacted"] as? Bool) == true { return true }
            return d.contains { name, v in name != "launchArgs" && holdsSecret(v, key: name) }
        }
        if let a = value as? [Any] { return a.contains { holdsSecret($0) } }
        return false
    }

    /// The instance to send with the upsert: the entry as read, with `config.launchArgs` the only change. Nil when
    /// it must not be written (it holds a secret, or its config is not an object).
    static func rewritten(_ entry: [String: Any], launchArgs: String) -> [String: Any]? {
        if holdsSecret(entry) { return nil }
        var config: [String: Any] = [:]
        if let c = entry["config"], !(c is NSNull) {
            guard let d = c as? [String: Any] else { return nil }
            config = d
        }
        config["launchArgs"] = launchArgs
        var instance = entry
        instance["config"] = config
        return instance
    }
}
