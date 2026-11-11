import Foundation

// The T3 Bot server's paths, answered by DirectBackend: the app keeps calling `API.get("v1/home")` and the rest,
// whichever it is paired with. Paths and bodies as server/t3bot.ts `route` takes them.

enum DirectRouter {
    static let encoder = JSONEncoder()

    /// What only a T3 Bot server does. Paired straight with T3 Code, the app gets one plain sentence, not a 404.
    static let serverOnly = ["v1/test-push", "v1/file", "v1/avatars", "v1/notes", "v1/drafts", "v1/phone", "v1/brief"]
    static let needsServer = "That needs a T3 Bot server. This phone is paired straight with T3 Code."

    static func isServerOnly(_ p: String) -> Bool { serverOnly.contains { p == $0 || p.hasPrefix($0 + "/") } }

    static func get(_ b: DirectBackend, _ path: String) async throws -> Data {
        let (p, query) = split(path)
        switch p {
        case "v1/hello": return try encoder.encode(try await b.hello())
        case "v1/home": return try encoder.encode(try await b.home())
        case "v1/settings": return try encoder.encode(await b.local().settings)
        case "v1/skins":
            let used = try await b.home().agents.map(\.face.skin)
            return try JSONSerialization.data(withJSONObject: ["skins": Skins.all.map { ["n": $0.n, "title": $0.title, "series": $0.series, "color": $0.color] }, "used": used])
        case "v1/know": return try JSONSerialization.data(withJSONObject: ["notes": [] as [Any]])
        case "v1/search":
            let r = try await b.search(query["q"] ?? "")
            let messages = r.messages.map { ["agent": $0.agent ?? "", "role": $0.role, "at": $0.at, "id": $0.id, "snippet": $0.snippet] }
            let cards = try r.cards.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
            return try JSONSerialization.data(withJSONObject: ["messages": messages, "cards": cards])
        default:
            if let id = agentPath(p, suffix: nil) { return try encoder.encode(try await b.timeline(id)) }
            if isServerOnly(p) { throw T3Error.rpc(needsServer) }
            throw T3Error.http(404, "not found: \(p)")
        }
    }

    static func post(_ b: DirectBackend, _ path: String, _ body: [String: Any]) async throws -> Reply {
        let (p, _) = split(path)
        func str(_ k: String) -> String? { (body[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch p {
        case "v1/answer":
            guard let t = str("threadId"), let r = str("requestId") else { throw T3Error.rpc("threadId and requestId are required") }
            let outcome = try await b.answer(threadId: t, requestId: r, decision: str("decision"), answers: (body["answers"] as? JSON) ?? [:])
            return Reply(ok: true, error: outcome == .sentAsMessage ? "sent-as-message" : nil, agent: nil)
        case "v1/cards/act", "v1/cards/done", "v1/cards/snooze", "v1/cards/handle":
            guard let id = str("id") else { throw T3Error.rpc("id required") }
            let action = p == "v1/cards/act" ? (str("action") ?? "") : String(p.dropFirst("v1/cards/".count))
            let until = str("until").flatMap(Ago.date)
            let agent = try await b.cardAction(id, action: action, text: str("text"), until: until)
            return Reply(ok: true, error: nil, agent: agent)
        case "v1/agents":
            let kind = str("kind") == "group" ? "group" : "bot"
            let id = try await b.newBot(name: str("name") ?? "", job: str("job") ?? "", kind: kind,
                                        skin: (body["face"] as? JSON)?["skin"] as? String, members: (body["members"] as? [String]) ?? [])
            return Reply(ok: true, error: nil, agent: id, id: id)
        case "v1/routines/enabled":
            guard let id = str("id") else { throw T3Error.rpc("id required") }
            try await b.setRoutine(id, enabled: (body["enabled"] as? Bool) ?? false)
            return Reply(ok: true, error: nil, agent: nil)
        case "v1/settings":
            var s = await b.local().settings
            if let q = body["quiet"] as? JSON {
                if let e = q["enabled"] as? Bool { s.quiet.enabled = e }
                if let f = q["from"] as? String, isHHMM(f) { s.quiet.from = f }
                if let t = q["to"] as? String, isHHMM(t) { s.quiet.to = t }
                if let a = q["alarms"] as? Bool { s.quiet.alarms = a }
            }
            if let qr = body["quickReplies"] as? [Any] {
                s.quickReplies = qr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { String($0.prefix(200)) }.prefix(6).map { $0 }
            }
            if let br = body["brief"] as? JSON {
                if let e = br["enabled"] as? Bool { s.brief.enabled = e }
                if let at = br["at"] as? String, at == "quiet-end" || isHHMM(at) { s.brief.at = at }
                if let ag = br["agent"] as? String { s.brief.agent = ag }
            }
            let saved = s
            await b.updateLocal { $0.settings = saved }
            return Reply(ok: true, error: nil, agent: nil)
        case "v1/share":
            let home = try await b.home()
            let agent = str("agent").flatMap { a in home.agents.first { $0.id == a } } ?? home.agents.first { $0.id == home.chief }
            guard let agent else { throw T3Error.rpc("There is no bot to share with yet.") }
            var parts: [String] = []
            if let n = str("note"), !n.isEmpty { parts.append(n) }
            if let u = str("url"), !u.isEmpty { parts.append("Shared link: \(u)") }
            if let t = str("text"), !t.isEmpty { parts.append("Shared text:\n\(t.prefix(20000))") }
            let images = ((body["images"] as? [String]) ?? []).compactMap { Data(base64Encoded: $0) }
            guard !parts.isEmpty || !images.isEmpty else { throw T3Error.rpc("Nothing to share.") }
            let who = await b.local().userName ?? "The user"
            try await b.send(threadId: agent.threadId, text: "\(who) shared this with you from the phone:\n\n\(parts.joined(separator: "\n\n"))",
                             images: images, clientId: str("clientId"))
            return Reply(ok: true, error: nil, agent: agent.id)
        // Nothing to do without a server: these keep their place for the app.
        case "v1/devices", "v1/devices/remove", "v1/live", "v1/phone/sync", "v1/phone/forget", "v1/notes/wrong":
            return Reply(ok: true, error: nil, agent: nil)
        default:
            if let id = agentPath(p, suffix: "send") {
                let threadId = try await b.threadIdOf(agent: id)
                let text = str("text") ?? ""
                let images = ((body["images"] as? [String]) ?? []).compactMap { Data(base64Encoded: $0) }
                guard !text.isEmpty || !images.isEmpty else { throw T3Error.rpc("empty message") }
                try await b.send(threadId: threadId, text: text, images: images, clientId: str("clientId"))
                return Reply(ok: true, error: nil, agent: id)
            }
            if let id = agentPath(p, suffix: "edit") {
                let told = try await b.editBot(id, body)
                return Reply(ok: true, error: told ? "told" : nil, agent: id)
            }
            if isServerOnly(p) { throw T3Error.rpc(needsServer) }
            throw T3Error.http(404, "not found: \(p)")
        }
    }

    // MARK: Paths

    /// "v1/search?q=a%20b" -> ("v1/search", ["q": "a b"]); a leading slash is dropped.
    static func split(_ path: String) -> (String, [String: String]) {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        guard let q = p.firstIndex(of: "?") else { return (p, [:]) }
        let comps = URLComponents(string: "x:/?" + p[p.index(after: q)...])
        var out: [String: String] = [:]
        for i in comps?.queryItems ?? [] { out[i.name] = i.value ?? "" }
        return (String(p[..<q]), out)
    }

    /// "v1/agents/<id>" (suffix nil) or "v1/agents/<id>/<suffix>" -> the id.
    static func agentPath(_ p: String, suffix: String?) -> String? {
        guard p.hasPrefix("v1/agents/") else { return nil }
        let rest = String(p.dropFirst("v1/agents/".count))
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let suffix { return parts.count == 2 && parts[1] == suffix && !parts[0].isEmpty ? parts[0].removingPercentEncoding ?? parts[0] : nil }
        return parts.count == 1 && !parts[0].isEmpty ? parts[0].removingPercentEncoding ?? parts[0] : nil
    }

    static func isHHMM(_ s: String) -> Bool { T3Text.matches(s, "^([01]\\d|2[0-3]):[0-5]\\d$") }
}
