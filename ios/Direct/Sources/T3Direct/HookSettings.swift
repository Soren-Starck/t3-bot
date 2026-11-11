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
