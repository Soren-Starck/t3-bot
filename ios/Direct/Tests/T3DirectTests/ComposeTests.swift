import XCTest
@testable import T3Direct

/// Made-up threads in T3 Code's shapes, so these tests carry no one's data.
enum Fake {
    static let now = Ago.date("2026-11-10T20:00:00.000Z")!

    static func thread(_ id: String, _ title: String, status: String = "completed", created: String = "2026-11-01T10:00:00.000Z",
                       pending: T3PendingRequest? = nil, visible: T3VisibleMessage? = nil, activity: String? = nil) -> T3ThreadSummary {
        T3ThreadSummary(id: id, projectId: "p1", title: title, status: status, activityRunStatus: activity, pendingRuntimeRequest: pending,
                        latestVisibleMessage: visible, createdAt: created, updatedAt: "2026-11-10T19:00:00.000Z")
    }

    static func msg(_ id: String, _ role: String, _ text: String, run: String, at: String, by: String = "user") -> T3Message {
        T3Message(id: id, role: role, text: text, runId: run, createdBy: role == "assistant" ? "agent" : by, streaming: false, createdAt: at)
    }

    static func input(shell: [T3ThreadSummary], projections: [String: T3Projection] = [:], meta: [String: BotMeta] = [:],
                      snoozed: [String: Date] = [:], replies: [String] = []) -> ComposeInput {
        ComposeInput(shell: Dictionary(uniqueKeysWithValues: shell.map { ($0.id, $0) }), projections: projections, meta: meta,
                     snoozed: snoozed, quickReplies: replies, environmentId: "env-1", userName: "Ada", now: now)
    }
}

final class ComposeTests: XCTestCase {
    func testBotsAndChief() {
        let i = Fake.input(shell: [
            Fake.thread("t-rel", "%BOT Releases", created: "2026-11-02T00:00:00.000Z"),
            Fake.thread("t-chief", "%BOT Chief", created: "2026-11-03T00:00:00.000Z"),
            Fake.thread("t-grp", "%BOT Group: Crew", created: "2026-11-01T00:00:00.000Z"),
            Fake.thread("t-other", "#SW autopilot"),
        ])
        let home = Compose.home(i)
        XCTAssertEqual(home.agents.map(\.name), ["Chief", "Releases", "Crew"])
        XCTAssertEqual(home.chief, "t-chief")
        XCTAssertEqual(home.agents.first?.kind, "bot")
        XCTAssertEqual(home.agents.last?.kind, "group")
        XCTAssertTrue(home.agents.allSatisfy { Skins.isSkin($0.face.skin) })
    }

    func testTimelineGroupsRunsAndHidesSystem() {
        let p = T3Projection(
            thread: Fake.thread("t1", "%BOT Chief"),
            runs: [T3Run(id: "r0", ordinal: 0, status: "completed"), T3Run(id: "r1", ordinal: 1, status: "completed"), T3Run(id: "r2", ordinal: 2, status: "completed")],
            messages: [
                Fake.msg("t3bot:rule:1", "user", "You are Chief...", run: "r0", at: "2026-11-10T10:00:00.000Z", by: "agent"),
                Fake.msg("a0", "assistant", "Ready.", run: "r0", at: "2026-11-10T10:00:05.000Z"),
                Fake.msg("u1", "user", "Deploy the site", run: "r1", at: "2026-11-10T11:00:00.000Z"),
                Fake.msg("a1", "assistant", "Checking the build.", run: "r1", at: "2026-11-10T11:00:10.000Z"),
                Fake.msg("a2", "assistant", "Deployed. Want the link?\n» Yes · No", run: "r1", at: "2026-11-10T11:01:00.000Z"),
                Fake.msg("u2", "user", "/compact", run: "r2", at: "2026-11-10T12:00:00.000Z"),
            ])
        let e = Compose.entries(p, quickReplies: [])
        XCTAssertFalse(e.working)
        XCTAssertEqual(e.entries.map(\.type), ["me", "agent"])
        XCTAssertEqual(e.entries[1].text, "Deployed. Want the link?")
        XCTAssertEqual(e.entries[1].steps, ["Checking the build."])
        XCTAssertEqual(e.entries[1].suggestions ?? [], ["Yes", "No"])
    }

    func testWorkingRunShowsStepsOnly() {
        let p = T3Projection(runs: [T3Run(id: "r1", ordinal: 1, status: "running")], messages: [
            Fake.msg("u1", "user", "Go", run: "r1", at: "2026-11-10T11:00:00.000Z"),
            Fake.msg("a1", "assistant", "Looking", run: "r1", at: "2026-11-10T11:00:10.000Z"),
        ])
        let e = Compose.entries(p, quickReplies: ["Yes"])
        XCTAssertTrue(e.working)
        XCTAssertEqual(e.entries.last?.working, true)
        XCTAssertEqual(e.entries.last?.text, "")
        XCTAssertEqual(e.entries.last?.steps, ["Looking"])
    }

    func testQuickRepliesOnlyWhenAsked() {
        let p = T3Projection(runs: [T3Run(id: "r1", ordinal: 1, status: "completed")], messages: [
            Fake.msg("u1", "user", "Go", run: "r1", at: "2026-11-10T11:00:00.000Z"),
            Fake.msg("a1", "assistant", "Done. Shall I deploy?", run: "r1", at: "2026-11-10T11:00:10.000Z"),
        ])
        XCTAssertEqual(Compose.entries(p, quickReplies: ["Yes, go"]).entries.last?.suggestions ?? [], ["Yes, go"])
    }

    func question(_ capability: String = "live", status: String = "pending") -> (T3ThreadSummary, T3Projection) {
        let pending = T3PendingRequest(id: "req-1", kind: "user_input", createdAt: "2026-11-10T19:30:00.000Z", blocking: true)
        let t = Fake.thread("t-q", "#HEALTH watch", status: "waiting", pending: pending)
        let p = T3Projection(runtimeRequests: [T3RuntimeRequest(id: "req-1", kind: "user_input", status: status, responseCapability: .init(type: capability))],
                             turnItems: [T3TurnItem(id: "ti", type: "user_input_request", requestId: "req-1",
                                                    questions: [T3Question(id: "q1", header: "Chrome", question: "Delete old Chrome versions?",
                                                                           options: [T3QuestionOption(label: "Yes"), T3QuestionOption(label: "No")])])])
        return (t, p)
    }

    func testQuestionCardGoesToChief() {
        let (t, p) = question()
        let i = Fake.input(shell: [Fake.thread("t-chief", "%BOT Chief"), t], projections: ["t-q": p])
        let home = Compose.home(i)
        XCTAssertEqual(home.needs.count, 1)
        let c = home.needs[0]
        XCTAssertEqual(c.id, "req:req-1")
        XCTAssertEqual(c.agent, "t-chief")
        XCTAssertEqual(c.title, "Delete old Chrome versions?")
        XCTAssertEqual(c.questions?.first?.options.map(\.label) ?? [], ["Yes", "No"])
        XCTAssertEqual(home.badge, 1)
        XCTAssertEqual(home.agents.first?.mood, "waiting")
    }

    func testDeadQuestionIsHidden() {
        let (t, p) = question("not_resumable")
        XCTAssertTrue(Compose.home(Fake.input(shell: [Fake.thread("t-chief", "%BOT Chief"), t], projections: ["t-q": p])).needs.isEmpty)
        let (t2, p2) = question(status: "resolved")
        XCTAssertTrue(Compose.home(Fake.input(shell: [Fake.thread("t-chief", "%BOT Chief"), t2], projections: ["t-q": p2])).needs.isEmpty)
    }

    func testSnoozedQuestionWaits() {
        let (t, p) = question()
        let later = Fake.now.addingTimeInterval(3600)
        XCTAssertTrue(Compose.home(Fake.input(shell: [Fake.thread("t-chief", "%BOT Chief"), t], projections: ["t-q": p], snoozed: ["req:req-1": later])).needs.isEmpty)
    }

    func testOldQuestionIsLeftOut() {
        let pending = T3PendingRequest(id: "old", kind: "user_input", createdAt: "2026-10-01T00:00:00.000Z")
        let t = Fake.thread("t-old", "x", pending: pending)
        XCTAssertTrue(Compose.questionCards(Fake.input(shell: [t]), bots: [], chief: nil).isEmpty)
    }

    func testWatchingBot() {
        let i = Fake.input(shell: [Fake.thread("t-chief", "%BOT Chief"), Fake.thread("t-sw", "#SW nightly", status: "running")],
                           meta: ["t-chief": BotMeta(watch: ["#SW"])])
        let a = Compose.home(i).agents[0]
        XCTAssertEqual(a.mood, "watching")
        XCTAssertEqual(a.watching, ["#SW nightly"])
    }

    func testPreviewFromShellWhenChatNotLoaded() {
        let v = T3VisibleMessage(id: "m", role: "assistant", text: "All green.\n» Thanks", updatedAt: "2026-11-10T18:00:00.000Z")
        let a = Compose.home(Fake.input(shell: [Fake.thread("t-chief", "%BOT Chief", visible: v)])).agents[0]
        XCTAssertEqual(a.last?.text, "All green.")
        XCTAssertEqual(a.last?.from, "agent")
        XCTAssertEqual(a.lastReplyAt, "2026-11-10T18:00:00.000Z")
    }
}

/// The same, on the private samples from this Mac when they are there.
final class ComposeSampleTests: XCTestCase {
    func testHomeAndChiefChatFromSamples() throws {
        let t = WireSampleTests()
        let shell = try JSONDecoder().decode(T3Shell.self, from: try t.load("shell-trimmed.json"))
        let snap = try JSONDecoder().decode(T3ThreadSnapshot.self, from: try t.load("thread-chief-bounded.json"))
        guard let chiefId = snap.projection.thread?.id else { return XCTFail("no thread in projection") }
        let input = ComposeInput(shell: Dictionary(shell.threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                                 projections: [chiefId: snap.projection], meta: [:], snoozed: [:], quickReplies: [], environmentId: "e", userName: nil)
        let home = Compose.home(input)
        XCTAssertGreaterThanOrEqual(home.agents.count, 8)
        XCTAssertEqual(home.chief, BotBook.botId(chiefId))
        let chief = try XCTUnwrap(home.agents.first)
        XCTAssertEqual(chief.name, "Chief")
        XCTAssertNotNil(chief.last)
        let tl = try XCTUnwrap(Compose.timeline(agentId: BotBook.botId(chiefId), input, routines: []))
        XCTAssertFalse(tl.entries.isEmpty)
        XCTAssertTrue(tl.entries.contains { $0.type == "agent" && !$0.text.isEmpty })
        // Nothing from T3 Bot's own setup message shows.
        XCTAssertFalse(tl.entries.contains { $0.text.contains("[T3 Bot: ") })
        print("sample home:", home.agents.map { "\($0.name)=\($0.mood ?? "")" }.joined(separator: ", "), "needs:", home.needs.count, "entries:", tl.entries.count)
    }
}
