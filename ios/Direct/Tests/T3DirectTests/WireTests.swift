import XCTest
@testable import T3Direct

/// Decodes the private samples from this Mac's T3 Code when they are there (NATIVE/samples, never committed).
final class WireSampleTests: XCTestCase {
    static let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../NATIVE/samples").standardized

    func load(_ name: String) throws -> Data {
        let u = Self.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: u.path) else { throw XCTSkip("no private sample \(name)") }
        return try Data(contentsOf: u)
    }

    func testShellSample() throws {
        let shell = try JSONDecoder().decode(T3Shell.self, from: try load("shell-trimmed.json"))
        XCTAssertGreaterThan(shell.threads.count, 5)
        XCTAssertGreaterThan(shell.projects.count, 0)
        let bots = shell.threads.compactMap { t in t.title.flatMap(BotBook.parse(title:)) }
        XCTAssertGreaterThan(bots.count, 3)
        XCTAssertTrue(shell.threads.contains { $0.pendingRuntimeRequest?.kind == "user_input" })
    }

    func testThreadSample() throws {
        let snap = try JSONDecoder().decode(T3ThreadSnapshot.self, from: try load("thread-chief-bounded.json"))
        XCTAssertGreaterThan(snap.projection.messages.count, 5)
        XCTAssertGreaterThan(snap.projection.runs.count, 1)
        XCTAssertTrue(snap.projection.turnItems.contains { $0.type == "user_input_request" && ($0.questions?.first?.options?.count ?? 0) > 0 })
        XCTAssertTrue(snap.projection.turnItems.contains { $0.type == "command_execution" && $0.input != nil })
    }
}

final class BotBookTests: XCTestCase {
    func testTitles() {
        XCTAssertEqual(BotBook.parse(title: "%BOT Chief")?.name, "Chief")
        XCTAssertEqual(BotBook.parse(title: "%BOT Website (36)")?.name, "Website")
        XCTAssertEqual(BotBook.parse(title: "%BOT Group: Launch crew")?.kind, "group")
        XCTAssertEqual(BotBook.parse(title: "%BOT Group: Launch crew")?.name, "Launch crew")
        XCTAssertNil(BotBook.parse(title: "#SW SEO autopilot"))
        XCTAssertNil(BotBook.parse(title: "%BOT "))
    }

    func testDefaultSkinIsStable() {
        XCTAssertEqual(BotBook.defaultSkin(for: "Chief"), BotBook.defaultSkin(for: "chief"))
        XCTAssertTrue(Skins.isSkin(BotBook.defaultSkin(for: "Anything")))
    }

    func testFreeSkinAvoidsUsed() {
        let s = BotBook.freeSkin(used: ["101", "102"])
        XCTAssertFalse(["101", "102"].contains(s))
        XCTAssertTrue(Skins.isSkin(s))
    }

    func testMarkerRoundTrip() {
        let first = Rules.firstMessage(name: "Releases", job: "Ship the apps", user: "Ada", skin: "404")
        let m = BotBook.readMarker(first)
        XCTAssertEqual(m?.skin, "404")
        XCTAssertEqual(m?.role, "Ship the apps")
        XCTAssertFalse(BotBook.withoutMarker(first).contains("[T3 Bot: "))
        let group = Rules.firstMessage(name: "Crew", job: "", user: nil, skin: "101", members: [("A", "t1"), ("B", "t2")])
        XCTAssertEqual(BotBook.readMarker(group)?.members ?? [], ["t1", "t2"])
    }

    func testBotId() {
        XCTAssertEqual(BotBook.botId("mcp:A4f8-b"), "mcp-a4f8-b")
        XCTAssertEqual(BotBook.botId("5de2f8af-3fe2"), "5de2f8af-3fe2")
    }

    func testStore() {
        let d = UserDefaults(suiteName: "t3bot.tests.\(UUID().uuidString)")!
        let s = BotStore(store: DefaultsStore(d))
        s.update("t1") { $0.skin = "105" }
        s.learn("t1", from: BotMeta(skin: "106", role: "Job"))
        XCTAssertEqual(s.get("t1")?.skin, "105")
        XCTAssertEqual(s.get("t1")?.role, "Job")
    }
}

final class RouterTests: XCTestCase {
    func testSplitAndAgentPath() {
        XCTAssertEqual(DirectRouter.split("/v1/search?q=a%20b").0, "v1/search")
        XCTAssertEqual(DirectRouter.split("v1/search?q=a%20b").1["q"], "a b")
        XCTAssertEqual(DirectRouter.agentPath("v1/agents/mcp-a4f8", suffix: nil), "mcp-a4f8")
        XCTAssertEqual(DirectRouter.agentPath("v1/agents/mcp-a4f8/send", suffix: "send"), "mcp-a4f8")
        XCTAssertNil(DirectRouter.agentPath("v1/agents/mcp-a4f8/send", suffix: nil))
        XCTAssertNil(DirectRouter.agentPath("v1/agents", suffix: nil))
        XCTAssertTrue(DirectRouter.isHHMM("07:30"))
        XCTAssertFalse(DirectRouter.isHHMM("7:30"))
    }

    func testScheduleWords() {
        XCTAssertEqual(DirectBackend.describe(schedule: ["type": "interval", "everyMs": 3_600_000]), "Every hour")
        XCTAssertEqual(DirectBackend.describe(schedule: ["type": "interval", "everyMs": 7_200_000]), "Every 2 h")
        XCTAssertEqual(DirectBackend.describe(schedule: ["type": "fixed_time", "timeOfDay": "07:30"]), "Every day at 07:30")
        XCTAssertEqual(DirectBackend.describe(schedule: ["type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 2, 3, 4, 5]]), "Weekdays at 09:00")
        XCTAssertEqual(DirectBackend.describe(schedule: ["type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 3]]), "Mon, Wed at 09:00")
    }

    func testThreadEvents() {
        var p = T3Projection(messages: [T3Message(id: "m1", role: "assistant", text: "Hel", streaming: true)])
        DirectBackend.apply(type: "message.updated", payload: ["id": "m1", "role": "assistant", "text": "Hello", "streaming": false], to: &p)
        DirectBackend.apply(type: "message.updated", payload: ["id": "m2", "role": "user", "text": "Hi"], to: &p)
        DirectBackend.apply(type: "run.updated", payload: ["id": "r1", "status": "completed", "ordinal": 1], to: &p)
        DirectBackend.apply(type: "runtime-request.updated", payload: ["id": "q", "status": "resolved"], to: &p)
        XCTAssertEqual(p.messages.map(\.text), ["Hello", "Hi"])
        XCTAssertEqual(p.runs.first?.status, "completed")
        XCTAssertEqual(p.runtimeRequests.first?.status, "resolved")
    }

    func testNextMorning() {
        let now = Ago.date("2026-11-10T20:00:00.000Z")!
        let m = DirectBackend.nextMorning("08:00", from: now)
        XCTAssertGreaterThan(m, now)
        XCTAssertLessThan(m.timeIntervalSince(now), 86400)
    }
}

final class HookSettingsTests: XCTestCase {
    let ring = URL(string: "https://t3bot-push.vercel.app/api/ring")!

    func testJSONIsValidAndHasNoSingleQuote() throws {
        let j = HookSettings.json(ring: ring, addresses: ["abc_DEF-1"], bots: ["mcp:a4f8-1", "5de2"])
        XCTAssertFalse(j.contains("'"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(j.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["Stop"])
        let stop = ((((hooks["Stop"] as? [[String: Any]])?.first?["hooks"]) as? [[String: Any]])?.first?["command"]) as? String ?? ""
        XCTAssertTrue(stop.contains("mcp:a4f8-1|5de2)"))
    }

    func testUnsafeValuesAreLeftOut() {
        let j = HookSettings.json(ring: ring, addresses: ["ok1", "bad;rm -rf"], bots: ["x$(id)", "good-1"])
        XCTAssertFalse(j.contains("rm -rf"))
        XCTAssertFalse(j.contains("$(id)"))
        XCTAssertTrue(j.contains("good-1"))
    }

    func testMergeStripReplace() throws {
        let first = try HookSettings.merged("--model x", ring: ring, addresses: ["a1"], bots: [])
        XCTAssertTrue(first.hasPrefix("--model x --settings '"))
        XCTAssertTrue(HookSettings.has(first))
        let again = try HookSettings.merged(first, ring: ring, addresses: ["a1", "a2"], bots: ["t1"])
        XCTAssertEqual(again.components(separatedBy: "--settings").count, 2, "replaced, not added twice")
        XCTAssertEqual(HookSettings.strip(again), "--model x")
        XCTAssertThrowsError(try HookSettings.merged("--settings /x.json", ring: ring, addresses: ["a"], bots: []))
        XCTAssertEqual(HookSettings.strip(""), "")
        XCTAssertEqual(HookSettings.addresses(in: again), ["a1", "a2"])
        XCTAssertEqual(HookSettings.addresses(in: "--model x"), [])
    }
}

/// Writes the launch arguments for live-hooks.ts (T3BOT_HOOK_OUT, T3BOT_HOOK_RING, T3BOT_HOOK_BOT). Skipped otherwise.
final class HookDumpTests: XCTestCase {
    func testDump() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["T3BOT_HOOK_OUT"], let ring = env["T3BOT_HOOK_RING"].flatMap(URL.init(string:)), let bot = env["T3BOT_HOOK_BOT"] else { throw XCTSkip("live-hooks only") }
        try HookSettings.merged("", ring: ring, addresses: ["testaddr-1"], bots: [bot]).write(toFile: out, atomically: true, encoding: .utf8)
    }
}

final class NotifyTextTests: XCTestCase {
    func testQuestionFromAWatchedThread() {
        let p = T3Projection(thread: Fake.thread("t-q", "#HEALTH watch"),
                             runtimeRequests: [T3RuntimeRequest(id: "r1", kind: "user_input", status: "pending", createdAt: "2026-11-10T19:00:00.000Z")],
                             turnItems: [T3TurnItem(id: "i", type: "user_input_request", requestId: "r1",
                                                    questions: [T3Question(id: "q1", question: "Delete old Chrome?", options: [T3QuestionOption(label: "Yes"), T3QuestionOption(label: "No")])])])
        var roster = Roster()
        roster.bots["t-chief"] = .init(id: "t-chief", name: "Chief", skin: "101", kind: "bot")
        roster.chief = "t-chief"
        let n = NotifyText.make(kind: "request", threadId: "t-q", projection: p, roster: roster)
        XCTAssertEqual(n.title, "Chief")
        XCTAssertEqual(n.subtitle, "Asks in #HEALTH watch")
        XCTAssertEqual(n.body, "Delete old Chrome?")
        XCTAssertEqual(n.category, "T3OPTIONS")
        XCTAssertEqual(n.options, ["Yes", "No"])
        XCTAssertEqual(n.requestId, "r1")
        XCTAssertEqual(n.questionId, "q1")
        XCTAssertEqual(n.agent, "t-chief")
    }

    func testReplyFromABot() {
        let p = T3Projection(thread: Fake.thread("t-rel", "%BOT Releases"), runs: [T3Run(id: "r", ordinal: 1, status: "completed")], messages: [
            Fake.msg("u", "user", "Ship?", run: "r", at: "2026-11-10T11:00:00.000Z"),
            Fake.msg("a", "assistant", "Shipped 2.4.1.\n» Thanks · Show me", run: "r", at: "2026-11-10T11:01:00.000Z"),
        ])
        var roster = Roster()
        roster.bots["t-rel"] = .init(id: "t-rel", name: "Releases", skin: "404", kind: "bot")
        let n = NotifyText.make(kind: "reply", threadId: "t-rel", projection: p, roster: roster)
        XCTAssertEqual(n.title, "Releases")
        XCTAssertEqual(n.body, "Shipped 2.4.1.")
        XCTAssertEqual(n.category, "REPLY")
        XCTAssertEqual(n.agent, "t-rel")
    }

    func testApproval() {
        let p = T3Projection(runtimeRequests: [T3RuntimeRequest(id: "r2", kind: "command", status: "pending")],
                             turnItems: [T3TurnItem(id: "i", type: "approval_request", requestId: "r2", command: "rm -rf build")])
        let n = NotifyText.make(kind: "request", threadId: "t-x", projection: p, roster: Roster())
        XCTAssertEqual(n.category, "APPROVAL")
        XCTAssertEqual(n.body, "Wants to run: rm -rf build")
    }
}
