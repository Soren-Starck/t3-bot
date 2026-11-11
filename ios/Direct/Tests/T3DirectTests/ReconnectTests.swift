import XCTest
@testable import T3Direct

// DirectBackend.reconnect and the socket's own ping, on a websocket made of nothing (FakeTransport).

final class ReconnectTests: XCTestCase {
    func backend(_ made: Transports, ticket: @escaping @Sendable () async throws -> String = { "ticket" }) -> DirectBackend {
        let d = UserDefaults(suiteName: "t3direct.reconnect.\(UUID().uuidString)")!
        let config = DirectConfig(base: URL(string: "http://127.0.0.1:9")!, token: "t", environmentId: "e", label: "This Mac")
        return DirectBackend(config: config, live: true, session: .shared, bots: BotStore(store: DefaultsStore(d)), local: DefaultsStore(d),
                             socket: { _ in
                                 T3Socket(base: config.base, token: "t", keepAlive: 0, opener: { _ in made.make() }, ticket: ticket)
                             })
    }

    func until(_ what: String = "", _ check: @escaping () -> Bool) async {
        for _ in 0..<600 { if check() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("never happened: \(what)")
    }

    /// One call through the backend, answered by the newest fake websocket.
    func roundTrip(_ b: DirectBackend, _ made: Transports, connection n: Int, id: String) async throws {
        let asked = Task { try await b.call("thing.get", [:] as [String: Any], timeout: 5) }
        await until("connection \(n) is made and asked") { made.all.count == n && made.all[n - 1].sent.contains { $0.contains("\"Request\"") } }
        made.all[n - 1].push(#"{"_tag":"Exit","requestId":"\#(id)","exit":{"_tag":"Success","value":{"ok":true}}}"#)
        let v = try await asked.value as? [String: Any]
        XCTAssertEqual(v?["ok"] as? Bool, true)
    }

    func testASocketThatAnswersIsKept() async throws {
        let made = Transports()
        let b = backend(made)
        try await roundTrip(b, made, connection: 1, id: "1")
        let kept = await b.reconnect(pingTimeout: 1)
        XCTAssertTrue(kept)
        XCTAssertEqual(made.all.count, 1, "nothing new was opened")
        XCTAssertFalse(made.all[0].wasCancelled, "a healthy line, and what is being sent on it, is not cut")
    }

    func testAHalfOpenSocketIsReplaced() async throws {
        let made = Transports()
        let b = backend(made)
        try await roundTrip(b, made, connection: 1, id: "1")
        // The line went dead without closing: pings get no answer.
        made.all[0].goSilent()
        let started = Date()
        let kept = await b.reconnect(pingTimeout: 0.1)
        XCTAssertFalse(kept)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(made.all[0].wasCancelled, "the dead websocket is let go")
        await until("a new connection is opened without being asked") { made.all.count == 2 }
        let ready = await b.mayTrySocket
        XCTAssertTrue(ready, "replacing a dead line starts no wait")
        try await roundTrip(b, made, connection: 2, id: "1")
    }

    func testTheWaitAfterFailuresStartsOver() async throws {
        let made = Transports()
        struct Down: Error {}
        let tries = Tries()
        let b = backend(made, ticket: { tries.add(); throw Down() })
        do { _ = try await b.call("thing.get", [:] as [String: Any], timeout: 1); XCTFail("no ticket, no socket") } catch {}
        XCTAssertEqual(tries.count, 1)
        let waiting = await b.mayTrySocket
        XCTAssertFalse(waiting, "a failed open waits before the next try")
        await b.reconnect(pingTimeout: 0.1)
        await until("reconnect tries again at once, whatever wait was left") { tries.count == 2 }
    }

    func testPingSaysWhetherTheLineAnswers() async throws {
        let made = Transports()
        let s = T3Socket(base: URL(string: "http://127.0.0.1:9")!, token: "t", keepAlive: 0, opener: { _ in made.make() }, ticket: { "ticket" })
        let before = await s.ping(timeout: 0.1)
        XCTAssertFalse(before, "not open yet")
        try await s.connect()
        let open = await s.ping(timeout: 1)
        XCTAssertTrue(open)
        made.last?.goSilent()
        let silent = await s.ping(timeout: 0.1)
        XCTAssertFalse(silent)
        XCTAssertTrue(s.isOpen, "a ping closes nothing by itself")
        s.close()
    }

    /// A pong that takes longer than one interval (one large frame on a slow network) is not a dead line.
    func testASlowPongDoesNotCloseAHealthyConnection() async throws {
        let made = Transports()
        let s = T3Socket(base: URL(string: "http://127.0.0.1:9")!, token: "t", keepAlive: 0.2, opener: { _ in made.make() }, ticket: { "ticket" })
        s.onClose = { why in made.closed(why) }
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        t.holdPongs()
        // Past the first ping (0.2 s) and a whole silent interval after it (0.4 s), before the second one ends (0.6 s).
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(s.isOpen, "one silent interval is slow, not dead")
        t.releasePongs()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(s.isOpen)
        XCTAssertEqual(made.closeReasons, [])
        s.close()
    }
}

// MARK: A T3 Code that gives the hook no thread id

final class NoThreadIdTests: XCTestCase {
    func testARingWithNoThreadNamesNobodyAndOffersNoReply() {
        var roster = Roster()
        roster.bots["t-chief"] = .init(id: "t-chief", name: "Chief", skin: "101", kind: "bot")
        roster.chief = "t-chief"
        for kind in ["request", "reply"] {
            let n = NotifyText.make(kind: kind, threadId: "", projection: nil, roster: roster)
            XCTAssertEqual(n.title, "T3 Bot")
            XCTAssertNil(n.agent, "not the leading bot: a typed reply would go to a thread that asked nothing")
            XCTAssertEqual(n.category, "", "no reply field")
            XCTAssertFalse(n.body.isEmpty)
        }
    }

    #if os(macOS)
    /// The hook's command with T3CODE_THREAD_ID not set: a permission request still rings, with an empty thread;
    /// a finished reply does not ring.
    func testTheHookWithoutAThreadId() throws {
        let ring = URL(string: "https://push.example.com/api/ring")!
        let args = try HookSettings.merged("", ring: ring, addresses: ["addr-1"], bots: ["mcp:t1"])
        let json = String(args.dropFirst("--settings '".count).dropLast())
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        for (hook, rings) in [("PermissionRequest", true), ("Stop", false)] {
            let entry = try XCTUnwrap((hooks[hook] as? [[String: Any]])?.first)
            let raw = try XCTUnwrap(((entry["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
            let cmd = raw.replacingOccurrences(of: "& done;", with: "& done; wait;")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("t3bot-hook-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: out) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "curl() { for x in \"$@\"; do printf '%s\\n' \"$x\"; done > \"$OUT\"; }\n" + cmd]
            p.environment = ["OUT": out.path, "PATH": "/usr/bin:/bin"]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, hook)
            guard rings else { XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), hook); continue }
            let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
            let body = try XCTUnwrap(lines.firstIndex(of: "--data").map { lines[$0 + 1] })
            let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
            XCTAssertEqual(sent, ["to": "addr-1", "thread": "", "kind": "request"])
        }
    }
    #endif
}

final class Tries: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
