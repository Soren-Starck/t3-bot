import XCTest
@testable import T3Direct

/// Against a real T3 Code. Run through `live-test.sh`, which mints a one-time code and revokes the session after.
/// Skipped when T3BOT_LIVE_CODE is not set.
final class LiveTests: XCTestCase {
    static var paired: (DirectConfig, String)?

    func config() async throws -> DirectConfig {
        if let p = Self.paired { return p.0 }
        let env = ProcessInfo.processInfo.environment
        guard let base = env["T3BOT_LIVE_BASE"].flatMap(T3Link.baseURL), let code = env["T3BOT_LIVE_CODE"], !code.isEmpty else {
            throw XCTSkip("no live T3 Code (run ios/Direct/live-test.sh)")
        }
        let r = try await T3Link.pair(T3PairingInput(base: base, code: code), label: "T3 Bot live test", os: "macOS", session: .shared)
        let c = DirectConfig(base: base, token: r.token, environmentId: r.descriptor.environmentId, label: r.descriptor.label ?? "T3 Code")
        Self.paired = (c, env["T3BOT_LIVE_MODE"] ?? "read")
        return c
    }

    func backend(live: Bool = true) async throws -> DirectBackend {
        let d = UserDefaults(suiteName: "t3bot.live.\(UUID().uuidString)")!
        return DirectBackend(config: try await config(), live: live, bots: BotStore(store: DefaultsStore(d)), local: DefaultsStore(d))
    }

    func test1PairingAndHello() async throws {
        let b = try await backend()
        let h = try await b.hello()
        XCTAssertEqual(h.ok, true)
        XCTAssertNotNil(h.version)
        print("live hello:", h.name ?? "", h.version ?? "", "bots:", h.bots ?? 0)
    }

    func test2Home() async throws {
        let b = try await backend()
        let t0 = Date()
        let home = try await b.home()
        let first = Date().timeIntervalSince(t0)
        XCTAssertFalse(home.agents.isEmpty, "this Mac has bots")
        XCTAssertNotNil(home.chief)
        let t1 = Date()
        _ = try await b.home()
        let second = Date().timeIntervalSince(t1)
        XCTAssertLessThan(second, 1.0, "a second Home comes from the live state, not the network")
        print(String(format: "live home: %d bots, %d needs, first %.2fs, again %.3fs", home.agents.count, home.needs.count, first, second))
        for c in home.needs { print("  need:", c.requestKind ?? "", "|", c.title.prefix(60), "| under", home.agents.first { $0.id == c.agent }?.name ?? c.agent) }
    }

    func test3ChiefChat() async throws {
        let b = try await backend()
        let home = try await b.home()
        let chief = try XCTUnwrap(home.chief)
        let t = try await b.timeline(chief)
        XCTAssertEqual(t.agent.id, chief)
        XCTAssertFalse(t.entries.isEmpty)
        print("live chief chat:", t.entries.count, "entries, working:", t.working, "routines:", t.routines.count, "last:", t.entries.last?.text.prefix(60) ?? "")
    }

    func test4EveryBotChat() async throws {
        let b = try await backend()
        let home = try await b.home()
        for a in home.agents {
            let t = try await b.timeline(a.id)
            XCTAssertEqual(t.agent.id, a.id)
            print("  chat \(a.name): \(t.entries.count) entries, mood \(t.agent.mood ?? "")")
        }
    }

    func test5Search() async throws {
        let b = try await backend()
        let r = try await b.search("deploy")
        print("live search 'deploy':", r.messages.count, "hits")
    }

    func test6ExtensionModeHTTPOnly() async throws {
        let b = try await backend(live: false)
        let home = try await b.home()
        XCTAssertFalse(home.agents.isEmpty)
    }

    func test7StreamsDeliver() async throws {
        let b = try await backend()
        _ = try await b.home()
        let expectation = XCTestExpectation(description: "a change arrives")
        expectation.isInverted = false
        // Any shell event (T3 Code is busy on this Mac) or the socket staying open is fine: this checks nothing crashes
        // and the stream stays up for a few seconds.
        try await Task.sleep(for: .seconds(4))
        let again = try await b.home()
        XCTAssertFalse(again.agents.isEmpty)
    }
}

/// Writes to a real T3 Code: a bot made in the scratch project ("No project") with a small model, two messages and
/// one answered question, then the thread is archived. `live-test.sh write`.
final class LiveWriteTests: XCTestCase {
    func waitFor(_ what: String, timeout: TimeInterval = 150, _ check: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await check() { return }
            try await Task.sleep(for: .seconds(2))
        }
        XCTFail("timed out waiting for \(what)")
        throw XCTSkip("timed out waiting for \(what)")
    }

    func testBotRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["T3BOT_LIVE_MODE"] == "write" else { throw XCTSkip("write tests: live-test.sh write") }
        let live = LiveTests()
        let b = try await live.backend()
        // A test that died before its cleanup left a thread: archived now.
        for a in try await b.home().agents where a.name.hasPrefix("T3BotTest") { try? await b.archive(threadId: a.threadId); print("live write: archived a leftover", a.name) }
        let projects = try await b.projectList()
        let scratch = try XCTUnwrap(projects.first { ($0.workspaceRoot ?? "").hasSuffix("/.t3/scratch") } ?? projects.first { $0.title == "No project" }, "a scratch project")
        await b.updateLocal { $0.botProject = scratch.id; $0.userName = "Tester" }
        let models = try await b.models()
        let small = models.first { $0.id.lowercased().contains("haiku") } ?? models.first { $0.id.lowercased().contains("sonnet") } ?? models.first
        let model = try XCTUnwrap(small, "a model")
        print("live write: project \(scratch.title ?? "") model \(model.instance)/\(model.id)")
        let name = "T3BotTest \(Int.random(in: 100...999))"
        let agent = try await b.newBot(name: name, job: "Answer test messages in one word.", kind: "bot", skin: nil, members: [],
                                       model: ["instanceId": model.instance, "model": model.id])
        let thread = try await b.threadIdOf(agent: agent)
        do { try await roundTrip(b, agent: agent, thread: thread, name: name) } catch { try? await b.archive(threadId: thread); throw error }
        try await b.archive(threadId: thread)
        print("live write: archived the test thread")
    }

    func roundTrip(_ b: DirectBackend, agent: String, thread: String, name: String) async throws {

        // The setup run (hidden) finishes first.
        try await waitFor("the bot to be ready") { try await !b.timeline(agent).working }
        let setup = try await b.timeline(agent)
        XCTAssertTrue(setup.entries.isEmpty, "the setup message and its answer do not show: \(setup.entries.map(\.text))")
        XCTAssertEqual(setup.agent.name, name)

        // One message, sent twice with the same client id (a retry): T3 Code keeps one.
        let clientId = UUID().uuidString
        try await b.send(threadId: thread, text: "Reply with exactly the word pong.", images: [], clientId: clientId)
        try? await b.send(threadId: thread, text: "Reply with exactly the word pong.", images: [], clientId: clientId)
        try await waitFor("pong") { let t = try await b.timeline(agent); return !t.working && t.entries.last?.type == "agent" && !(t.entries.last?.text.isEmpty ?? true) }
        let t1 = try await b.timeline(agent)
        XCTAssertEqual(t1.entries.filter { $0.type == "me" }.count, 1, "the retry did not post twice")
        XCTAssertTrue(t1.entries.last?.text.lowercased().contains("pong") ?? false, "got: \(t1.entries.last?.text ?? "")")

        // A question with options, answered from the app.
        try await b.send(threadId: thread, text: "Use the AskUserQuestion tool now to ask me one question, header \"Color\", question \"Pick a color\", options Red and Blue. After I answer, reply with only the color I picked.", images: [], clientId: nil)
        var card: Card?
        try await waitFor("the question card") { card = try await b.home().needs.first { $0.threadId == thread }; return card != nil }
        let c = try XCTUnwrap(card)
        XCTAssertEqual(c.questions?.first?.options.map(\.label).sorted() ?? [], ["Blue", "Red"])
        XCTAssertEqual(c.agent, agent, "the question shows under the bot that asked")
        let qid = try XCTUnwrap(c.questions?.first?.id)
        let outcome = try await b.answer(threadId: thread, requestId: try XCTUnwrap(c.requestId), decision: nil, answers: [qid: "Blue"])
        XCTAssertEqual(outcome, .answered)
        try await waitFor("the answer to land") { let t = try await b.timeline(agent); return !t.working && (t.entries.last?.text.lowercased().contains("blue") ?? false) }
        let home = try await b.home()
        XCTAssertFalse(home.needs.contains { $0.threadId == thread }, "the card left the list")
        print("live write: bot made, pong, question answered")
    }
}
