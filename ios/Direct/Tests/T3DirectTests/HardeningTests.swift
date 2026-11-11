import XCTest
@testable import T3Direct

// The tests of the hardening pass before 0.3.0: each one fails on the code as it was before its fix.

// MARK: A websocket made of nothing, to drive T3Socket

final class FakeTransport: T3Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var waiting: ((Result<Data, Error>) -> Void)?
    private var inbox: [Result<Data, Error>] = []
    private var heldPongs: [(Error?) -> Void] = []
    private var answers = true
    private var holds = false
    private(set) var pings = 0
    private(set) var cancelled = false

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return sentFrames }
    var pingCount: Int { lock.lock(); defer { lock.unlock() }; return pings }
    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Pings get no answer from now on (the line went dead without closing).
    func goSilent() { lock.lock(); answers = false; lock.unlock() }
    /// Pongs are kept until `releasePongs`.
    func holdPongs() { lock.lock(); holds = true; lock.unlock() }
    func releasePongs() {
        lock.lock(); let h = heldPongs; heldPongs = []; holds = false; lock.unlock()
        for done in h { done(nil) }
    }

    func resume() {}
    func send(_ text: String, _ done: @escaping (Error?) -> Void) {
        lock.lock(); sentFrames.append(text); lock.unlock()
        done(nil)
    }
    func receive(_ done: @escaping (Result<Data, Error>) -> Void) {
        lock.lock()
        if inbox.isEmpty { waiting = done; lock.unlock(); return }
        let r = inbox.removeFirst()
        lock.unlock()
        DispatchQueue.global().async { done(r) }
    }
    func ping(_ done: @escaping (Error?) -> Void) {
        lock.lock()
        pings += 1
        if holds { heldPongs.append(done); lock.unlock(); return }
        let answer = answers
        lock.unlock()
        if answer { done(nil) }
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func push(_ json: String) { deliver(.success(Data(json.utf8))) }
    func drop() { deliver(.failure(URLError(.networkConnectionLost))) }
    private func deliver(_ r: Result<Data, Error>) {
        lock.lock()
        if let w = waiting { waiting = nil; lock.unlock(); w(r) } else { inbox.append(r); lock.unlock() }
    }
}

final class Transports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [FakeTransport] = []
    private var closes: [String] = []
    var prepare: ((FakeTransport) -> Void)?
    func make() -> FakeTransport { let t = FakeTransport(); prepare?(t); lock.lock(); list.append(t); lock.unlock(); return t }
    var all: [FakeTransport] { lock.lock(); defer { lock.unlock() }; return list }
    var last: FakeTransport? { all.last }
    func closed(_ why: String) { lock.lock(); closes.append(why); lock.unlock() }
    var closeReasons: [String] { lock.lock(); defer { lock.unlock() }; return closes }
}

final class SocketTests: XCTestCase {
    func socket(keepAlive: TimeInterval = 0, _ made: Transports) -> T3Socket {
        let s = T3Socket(base: URL(string: "http://127.0.0.1:9")!, token: "t", keepAlive: keepAlive,
                         opener: { _ in made.make() }, ticket: { "ticket" })
        s.onClose = { why in made.closed(why) }
        return s
    }

    /// Waits up to 3 s for something another thread does.
    func until(_ what: String = "", _ check: @escaping () -> Bool) async {
        for _ in 0..<600 { if check() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("never happened: \(what)")
    }

    func testACallGetsItsAnswer() async throws {
        let made = Transports()
        let s = socket(made)
        try await s.connect()
        XCTAssertTrue(s.isOpen)
        let t = try XCTUnwrap(made.last)
        async let answer = s.call("thing.get", ["a": 1])
        await until("the request is sent") { t.sent.contains { $0.contains("\"Request\"") } }
        // A list of frames with things that are not frames in it: the frame is still read.
        t.push(#"[42, "noise", null, {"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":{"ok":true}}}]"#)
        let v = try await answer as? [String: Any]
        XCTAssertEqual(v?["ok"] as? Bool, true)
    }

    func testUnknownFramesAreIgnoredAndPingIsAnswered() async throws {
        let made = Transports()
        let s = socket(made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        t.push(#"{"_tag":"SomethingNew","requestId":"9"}"#)
        t.push("not json at all")
        t.push(#"{"_tag":"Ping"}"#)
        await until("the pong") { t.sent.contains { $0.contains("\"Pong\"") } }
        XCTAssertTrue(s.isOpen)
    }

    func testAStreamYieldsAcksAndEnds() async throws {
        let made = Transports()
        let s = socket(made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        let (id, values) = s.stream("things.subscribe", [:] as [String: Any])
        var got: [Int] = []
        let reader = Task { () -> [Int] in
            var out: [Int] = []
            for try await v in values { if let n = v as? Int { out.append(n) } }
            return out
        }
        await until("the subscription is sent") { t.sent.contains { $0.contains("things.subscribe") } }
        t.push(#"{"_tag":"Chunk","requestId":"\#(id)","values":[1,2]}"#)
        t.push(#"{"_tag":"Chunk","requestId":"\#(id)","values":[3]}"#)
        t.push(#"{"_tag":"Exit","requestId":"\#(id)","exit":{"_tag":"Success"}}"#)
        got = try await reader.value
        XCTAssertEqual(got, [1, 2, 3])
        XCTAssertEqual(t.sent.filter { $0.contains("\"Ack\"") }.count, 2)
    }

    func testAQuietConnectionIsClosedAndWaitingCallsEnd() async throws {
        let made = Transports()
        let s = socket(keepAlive: 0.05, made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        t.goSilent()
        let started = Date()
        do {
            _ = try await s.call("thing.get", [:] as [String: Any], timeout: 30)
            XCTFail("a call on a dead line must not answer")
        } catch {
            XCTAssertEqual(error as? T3Error, .closed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "long before the call's own 30 s")
        XCTAssertFalse(s.isOpen)
        XCTAssertEqual(s.state, .closed("the connection went quiet"))
        XCTAssertTrue(t.wasCancelled, "the dead websocket is let go")
        await until("the close is reported") { made.closeReasons.count == 1 }
    }

    func testAnAnsweringConnectionStaysOpen() async throws {
        let made = Transports()
        let s = socket(keepAlive: 0.05, made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        await until("a few keep-alive pings") { t.pingCount >= 5 }
        XCTAssertTrue(s.isOpen)
        XCTAssertEqual(made.closeReasons, [])
        s.close()
    }

    func testFramesCountAsLifeWithoutPongs() async throws {
        let made = Transports()
        let s = socket(keepAlive: 0.2, made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        t.goSilent()
        for _ in 0..<12 {
            t.push(#"{"_tag":"Ping"}"#)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(s.isOpen, "a server that keeps talking is alive, pong or not")
        s.close()
    }

    func testACancelledCallEndsAtOnceAndTellsT3Code() async throws {
        let made = Transports()
        let s = socket(made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        let call = Task { try await s.call("slow.thing", [:] as [String: Any], timeout: 30) }
        await until("the request is sent") { t.sent.contains { $0.contains("slow.thing") } }
        let started = Date()
        call.cancel()
        do { _ = try await call.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        await until("the interrupt") { t.sent.contains { $0.contains("\"Interrupt\"") } }
        XCTAssertTrue(s.isOpen, "one cancelled call does not close the socket")
        // The late answer of the cancelled call is passed over.
        t.push(#"{"_tag":"Exit","requestId":"1","exit":{"_tag":"Success","value":1}}"#)
        async let next = s.call("thing.get", [:] as [String: Any])
        await until("the next request") { t.sent.contains { $0.contains("thing.get") } }
        t.push(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Success","value":"two"}}"#)
        let v = try await next as? String
        XCTAssertEqual(v, "two")
    }

    func testADropEndsEverythingAndIsReportedOnce() async throws {
        let made = Transports()
        let s = socket(made)
        try await s.connect()
        let t = try XCTUnwrap(made.last)
        let (_, values) = s.stream("things.subscribe", [:] as [String: Any])
        let reader = Task { () -> Error? in
            do { for try await _ in values {}; return nil } catch { return error }
        }
        let call = Task { try await s.call("thing.get", [:] as [String: Any], timeout: 30) }
        await until("both are sent") { t.sent.count >= 2 }
        t.drop()
        do { _ = try await call.value; XCTFail("dropped") } catch { XCTAssertEqual(error as? T3Error, .closed) }
        let streamError = await reader.value
        XCTAssertEqual(streamError as? T3Error, .closed)
        s.close("again")
        s.close("and again")
        await until("the close is reported") { !made.closeReasons.isEmpty }
        XCTAssertEqual(made.closeReasons.count, 1)
        do { _ = try await s.call("thing.get", [:] as [String: Any]); XCTFail("closed") } catch { XCTAssertEqual(error as? T3Error, .notConnected) }
    }

    func testAPongAfterTheOpenTimedOutOpensNothing() async throws {
        let made = Transports()
        made.prepare = { $0.holdPongs() }
        let s = socket(made)
        do { try await s.connect(timeout: 0.1); XCTFail("no pong, no open") } catch { XCTAssertEqual(error as? T3Error, .timeout) }
        let t = try XCTUnwrap(made.last)
        t.releasePongs()
        XCTAssertFalse(s.isOpen)
        XCTAssertTrue(t.wasCancelled)
    }

    func testACancelledOpenEndsAtOnce() async throws {
        let made = Transports()
        made.prepare = { $0.holdPongs() }
        let s = socket(made)
        let opening = Task { try await s.connect(timeout: 30) }
        await until("the websocket is made") { made.last?.pingCount == 1 }
        let started = Date()
        opening.cancel()
        do { try await opening.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(s.isOpen)
    }

    func testAnOldConnectionEndingLateDoesNotCloseTheNewOne() async throws {
        let made = Transports()
        let s = socket(made)
        try await s.connect()
        let old = try XCTUnwrap(made.last)
        s.close("going away")
        try await s.connect()
        XCTAssertEqual(made.all.count, 2)
        old.drop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(s.isOpen)
    }

    func testAFailureWithOddPartsIsDescribedNotCrashed() {
        // null, numbers and lists inside a failure: none of them is a JSON document by itself.
        XCTAssertTrue(T3Socket.describe(["_tag": "Failure", "cause": ["_tag": "Die", "defect": NSNull()]] as [String: Any]).contains("Die"))
        XCTAssertTrue(T3Socket.describe(["_tag": "Failure", "cause": 42] as [String: Any]).contains("42"))
        XCTAssertEqual(T3Socket.describe(NSNull()), "unknown error")
        XCTAssertEqual(T3Socket.describe(7), "unknown error")
        XCTAssertEqual(T3Socket.describe(["_tag": "Failure", "cause": ["_tag": "Fail", "error": ["message": "No such thread"]]] as [String: Any]), "No such thread")
        XCTAssertEqual(T3Socket.describe(nil), "unknown error")
    }
}

// MARK: Reading what a newer T3 Code sends

final class TolerantWireTests: XCTestCase {
    func testAThreadWithFieldsInANewShapeStillShows() throws {
        let json = """
        {"snapshotSequence":"42","threads":[
          {"id":"a","title":"%BOT Chief","status":{"new":"shape"},"pendingRuntimeRequest":{"kind":"user_input"},
           "modelSelection":{"model":7,"options":[{"id":"x","value":true},"junk",{"id":"y","value":"z"}]},"futureField":[1,2],"pinnedAt":null},
          {"title":"no id"},
          "junk",
          {"id":"b","pinnedAt":12,"lineage":"flat"}
        ],"projects":[{"id":"p","title":null,"defaultModelSelection":[]},{"nope":1}],"somethingNew":{"x":1}}
        """
        let shell = try JSONDecoder().decode(T3Shell.self, from: Data(json.utf8))
        XCTAssertEqual(shell.snapshotSequence, 42)
        XCTAssertEqual(shell.threads.map(\.id), ["a", "b"], "the two threads that have an id, whatever else is odd")
        XCTAssertEqual(shell.threads[0].title, "%BOT Chief")
        XCTAssertNil(shell.threads[0].status)
        XCTAssertNil(shell.threads[0].pendingRuntimeRequest, "a request with no id is no request, and the thread stays")
        XCTAssertNotNil(shell.threads[0].modelSelection)
        XCTAssertNil(shell.threads[0].modelSelection?.model)
        XCTAssertEqual(shell.threads[0].modelSelection?.options?.map(\.id), ["x", "y"])
        XCTAssertNil(shell.threads[1].pinnedAt)
        XCTAssertEqual(shell.projects.map(\.id), ["p"])
    }

    func testAChatWithOddItemsShowsTheRest() throws {
        let json = """
        {"snapshotSequence":7,"hasMoreHistory":"yes","projection":{
          "thread":{"id":"t","status":3},
          "runs":[{"id":"r1","ordinal":"first","status":"running"},{"status":"no id"}],
          "messages":[{"id":"m1","role":"assistant","text":"hi","attachments":[{"id":"a1","sizeBytes":"big"},5],"streaming":"no"},
                      {"id":7},
                      {"id":"m2","text":["blocks"],"role":"user"}],
          "runtimeRequests":[{"id":"q1","kind":"user_input","responseCapability":"new"}],
          "turnItems":[{"id":"i1","type":"a_kind_from_next_year","questions":[{"id":"q","question":"Go?","options":[{"label":"Yes"},{"nolabel":1}]},"junk"]},
                       {"id":"i2","type":"command_execution","input":{"cmd":"ls"}}],
          "newList":[1]}}
        """
        let snap = try JSONDecoder().decode(T3ThreadSnapshot.self, from: Data(json.utf8))
        let p = snap.projection
        XCTAssertEqual(snap.snapshotSequence, 7)
        XCTAssertNil(snap.hasMoreHistory)
        XCTAssertEqual(p.thread?.id, "t")
        XCTAssertNil(p.thread?.status)
        XCTAssertEqual(p.runs.map(\.id), ["r1"])
        XCTAssertNil(p.runs[0].ordinal)
        XCTAssertEqual(p.runs[0].status, "running")
        XCTAssertEqual(p.messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(p.messages[0].text, "hi")
        XCTAssertEqual(p.messages[0].attachments?.count, 1)
        XCTAssertNil(p.messages[0].streaming)
        XCTAssertNil(p.messages[1].text)
        XCTAssertEqual(p.messages[1].role, "user")
        XCTAssertEqual(p.runtimeRequests.map(\.id), ["q1"])
        XCTAssertEqual(p.turnItems.map(\.id), ["i1", "i2"])
        XCTAssertEqual(p.turnItems[0].type, "a_kind_from_next_year")
        XCTAssertEqual(p.turnItems[0].questions?.count, 1)
        XCTAssertEqual(p.turnItems[0].questions?.first?.options?.map(\.label), ["Yes"])
        XCTAssertNil(p.turnItems[1].input)
    }

    func testSequenceAsTextOrMissing() throws {
        let a = try JSONDecoder().decode(T3ThreadSnapshot.self, from: Data(#"{"snapshotSequence":"12","projection":{}}"#.utf8))
        XCTAssertEqual(a.snapshotSequence, 12)
        XCTAssertEqual(a.projection.messages.count, 0)
        let b = try JSONDecoder().decode(T3ThreadSnapshot.self, from: Data(#"{"snapshotSequence":{"n":1},"projection":{"messages":null,"runs":"none"}}"#.utf8))
        XCTAssertNil(b.snapshotSequence)
        XCTAssertEqual(b.projection.runs.count, 0)
        let empty = try JSONDecoder().decode(T3Shell.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.threads.count, 0)
        XCTAssertEqual(empty.projects.count, 0)
    }

    func testWhatIsNotThereIsNotWritten() throws {
        let m = T3Message(id: "m", role: "user", text: "x")
        let data = try JSONEncoder().encode(m)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj.keys.sorted(), ["id", "role", "text"])
        XCTAssertEqual(try JSONDecoder().decode(T3Message.self, from: data), m)
    }

    func testEventsInAShapeNobodyKnows() {
        var p = T3Projection(messages: [T3Message(id: "m1", role: "assistant", text: "a")])
        DirectBackend.apply(type: "something.invented", payload: ["id": "x"], to: &p)
        DirectBackend.apply(type: "message.updated", payload: ["no": "id"], to: &p)
        // A payload that is no object used to raise an exception inside JSONSerialization: the app went down.
        DirectBackend.apply(type: "message.updated", payload: "just text", to: &p)
        DirectBackend.apply(type: "run.updated", payload: NSNull(), to: &p)
        DirectBackend.apply(type: "turn-item.updated", payload: 7, to: &p)
        DirectBackend.apply(type: "thread.renamed", payload: [1, 2], to: &p)
        DirectBackend.apply(type: "message.updated", payload: ["id": "m1", "text": 5, "role": "assistant"], to: &p)
        DirectBackend.apply(type: "turn-item.updated", payload: ["id": "i", "type": "new_kind", "questions": "none"], to: &p)
        XCTAssertEqual(p.messages.map(\.id), ["m1"])
        XCTAssertEqual(p.runs.count, 0)
        XCTAssertEqual(p.turnItems.map(\.type), ["new_kind"])
        XCTAssertNil(p.thread)
    }

    func testOnlyListsAndObjectsBecomeData() {
        XCTAssertNil(T3JSON.data(NSNull()))
        XCTAssertNil(T3JSON.data("text"))
        XCTAssertNil(T3JSON.data(3))
        XCTAssertNil(T3JSON.data(["d": Date()]))
        XCTAssertNotNil(T3JSON.data(["a": 1]))
        XCTAssertNotNil(T3JSON.data([1, 2]))
    }

    func testDescriptorWithOddFields() throws {
        let d = try JSONDecoder().decode(T3Descriptor.self, from: Data(#"{"environmentId":"e1","label":5,"platform":"mac","orchestrationProtocolVersion":"2","new":true}"#.utf8))
        XCTAssertEqual(d.environmentId, "e1")
        XCTAssertNil(d.label)
        XCTAssertNil(d.platform)
        XCTAssertNil(d.orchestrationProtocolVersion)
    }
}

// MARK: Links

final class LinkTests: XCTestCase {
    func check(_ text: String, _ base: String, _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        let p = T3Link.parse(link: text)
        XCTAssertEqual(p?.base.absoluteString, base, file: file, line: line)
        XCTAssertEqual(p?.code, code, file: file, line: line)
    }

    func testEveryShapeT3CodeMakes() {
        check("https://my-mac.tail1234.ts.net/pair#token=ABC123", "https://my-mac.tail1234.ts.net", "ABC123")
        check("http://192.168.1.20:3773/pair#token=ABC123", "http://192.168.1.20:3773", "ABC123")
        check("https://name.t3coderelay.com/pair/#token=ABC123", "https://name.t3coderelay.com", "ABC123")
        check("https://host.example:8443/pair?token=Q1", "https://host.example:8443", "Q1")
        check("t3code://pair?pairingUrl=https%3A%2F%2Fhost.example%3A8443%2Fpair%23token%3DXYZ", "https://host.example:8443", "XYZ")
        check("t3code-dev://pair?pairingUrl=http%3A%2F%2F10.0.0.2%3A3773%2Fpair%23token%3DXYZ", "http://10.0.0.2:3773", "XYZ")
        check("https://app.t3.codes/pair?host=https%3A%2F%2Fname.t3coderelay.com#token=T1", "https://name.t3coderelay.com", "T1")
        check("https://app.t3.codes/pair?host=192.168.1.5:3773#token=T1", "http://192.168.1.5:3773", "T1")
        check("https://app.t3.codes/pair?host=my-mac.tail1234.ts.net#token=T1", "https://my-mac.tail1234.ts.net", "T1")
        check("HTTPS://Host.Example/pair#token=aB3", "https://Host.Example", "aB3")
    }

    func testALinkInsideOtherText() {
        check("  https://x.example.com/pair#token=AB12  \n", "https://x.example.com", "AB12")
        check("Pair with this:\nhttps://x.example.com/pair#token=AB12\nthanks", "https://x.example.com", "AB12")
        check("<https://x.example.com/pair#token=AB12>", "https://x.example.com", "AB12")
        check("(\"https://x.example.com/pair#token=AB12\")", "https://x.example.com", "AB12")
        // The end of a sentence is not part of the code.
        check("Open https://x.example.com/pair#token=AB12.", "https://x.example.com", "AB12")
        check("Here: https://x.example.com/pair#token=AB12, then tap Pair!", "https://x.example.com", "AB12")
    }

    func testWhatIsNoLink() {
        XCTAssertNil(T3Link.parse(link: ""))
        XCTAssertNil(T3Link.parse(link: "hello world"))
        XCTAssertNil(T3Link.parse(link: "https://x.example.com/pair"), "no code")
        XCTAssertNil(T3Link.parse(link: "https://x.example.com/pair#token="))
        XCTAssertNil(T3Link.parse(link: "ftp://x.example.com/pair#token=a"))
        XCTAssertNil(T3Link.parse(link: "t3code://pair?pairingUrl="))
        XCTAssertNil(T3Link.parse(link: "t3code://pair"))
        XCTAssertNil(T3Link.parse(link: "https://app.t3.codes/pair?host=name.t3coderelay.com"), "the hosted form with no code")
    }

    func testAddressesAsTyped() {
        func base(_ s: String) -> String? { T3Link.baseURL(s)?.absoluteString }
        XCTAssertEqual(base("example.com"), "https://example.com")
        XCTAssertEqual(base("my-mac.tail1234.ts.net:3773/"), "https://my-mac.tail1234.ts.net:3773")
        XCTAssertEqual(base("https://x.example.com/mcp/"), "https://x.example.com")
        XCTAssertEqual(base("https://x.example.com///"), "https://x.example.com")
        XCTAssertEqual(base("wss://x.example.com/ws?wsTicket=1"), "https://x.example.com")
        XCTAssertEqual(base("ws://10.0.0.2:3773/ws"), "http://10.0.0.2:3773")
        XCTAssertEqual(base(" 10.0.0.2 "), "http://10.0.0.2")
        XCTAssertEqual(base("192.168.1.20:3773"), "http://192.168.1.20:3773")
        XCTAssertEqual(base("localhost:3773"), "http://localhost:3773")
        XCTAssertEqual(base("MyMac.local:3773"), "http://MyMac.local:3773")
        // A name with no dot is a machine on this network or a tailnet short name, where T3 Code speaks plain http.
        XCTAssertEqual(base("my-mac:3773"), "http://my-mac:3773")
        XCTAssertEqual(base("[fe80::1]:3773"), "http://[fe80::1]:3773")
        XCTAssertEqual(base("https://user:secret@x.example.com/a?b=c#d"), "https://x.example.com")
        XCTAssertNil(base(""))
        XCTAssertNil(base("   "))
        XCTAssertNil(base("two words"))
        XCTAssertNil(base("ftp://x.example.com"))
        XCTAssertNil(base("https://"))
    }

    func testPathsNeverCrash() {
        let base = URL(string: "https://x.example.com/")!
        XCTAssertEqual(T3Link.url(base, "api/x").absoluteString, "https://x.example.com/api/x")
        XCTAssertEqual(T3Link.url(base, "/api/x").absoluteString, "https://x.example.com/api/x")
        XCTAssertTrue(T3Link.url(base, "/a b/ç").absoluteString.hasPrefix("https://x.example.com/a%20b/"))
        XCTAssertEqual(T3Link.url(base, "").absoluteString, "https://x.example.com/")
        XCTAssertEqual(T3Link.segment("mcp:a b/c"), "mcp%3Aa%20b%2Fc")
        XCTAssertEqual(T3Link.socketURL(URL(string: "https://x.example.com")!, ticket: "a+b/c=").absoluteString,
                       "wss://x.example.com/ws?orchestrationProtocol=2&wsTicket=a%2Bb%2Fc%3D")
        XCTAssertEqual(T3Link.socketURL(URL(string: "http://10.0.0.2:3773/")!, ticket: "t").scheme, "ws")
    }
}

// MARK: The hooks in the launch arguments

final class HookHardeningTests: XCTestCase {
    let ring = URL(string: "https://push.example.com/api/ring")!

    func command(_ json: String, _ hook: String) throws -> String {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(obj["hooks"] as? [String: Any])
        return try XCTUnwrap((((hooks[hook] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"]) as? String)
    }

    func testInstallingTwiceChangesNothing() throws {
        let once = try HookSettings.merged("--model opus --verbose", ring: ring, addresses: ["a1"], bots: ["t1"])
        let twice = try HookSettings.merged(once, ring: ring, addresses: ["a1"], bots: ["t1"])
        XCTAssertEqual(once, twice)
        XCTAssertEqual(HookSettings.strip(twice), "--model opus --verbose")
        XCTAssertEqual(HookSettings.strip(HookSettings.strip(twice)), "--model opus --verbose")
    }

    func testThePersonsOwnArgumentsStay() throws {
        let ours = try HookSettings.merged("", ring: ring, addresses: ["a1"], bots: [])
        XCTAssertTrue(ours.hasPrefix("--settings '"))
        // Ours in the middle of theirs (they added a flag after): only ours goes.
        XCTAssertEqual(HookSettings.strip("--model x " + ours + " --verbose"), "--model x --verbose")
        // Their own --settings is never ours to remove or replace.
        let theirs = "--settings '{\"model\":\"opus\"}' --verbose"
        XCTAssertEqual(HookSettings.strip(theirs), theirs)
        XCTAssertFalse(HookSettings.has(theirs))
        for own in [theirs, "--settings=/x.json", "--settings /x.json", "--model x --settings"] {
            XCTAssertThrowsError(try HookSettings.merged(own, ring: ring, addresses: ["a1"], bots: [])) {
                XCTAssertEqual($0 as? HookSettings.Problem, .otherSettings)
            }
        }
        // A flag that only starts the same is not a --settings.
        XCTAssertNoThrow(try HookSettings.merged("--settings-sources user", ring: ring, addresses: ["a1"], bots: []))
    }

    func testEmptyAndOddArguments() throws {
        for args in ["", "   ", "\t"] {
            let m = try HookSettings.merged(args, ring: ring, addresses: ["a1"], bots: [])
            XCTAssertTrue(m.hasPrefix("--settings '"), "nothing before ours for \"\(args)\"")
            XCTAssertEqual(HookSettings.strip(m), "")
        }
        XCTAssertEqual(HookSettings.strip("--model x"), "--model x")
        XCTAssertEqual(HookSettings.addresses(in: ""), [])
        XCTAssertFalse(HookSettings.has(""))
    }

    func testNoPhoneNoCommand() throws {
        let j = HookSettings.json(ring: ring, addresses: ["bad one", ""], bots: ["t1"])
        XCTAssertFalse(j.contains("curl"))
        XCTAssertTrue(j.contains(HookSettings.marker))
        let m = try HookSettings.merged("--model x", ring: ring, addresses: [], bots: [])
        XCTAssertTrue(HookSettings.has(m), "still ours, so it is found and replaced next time")
        XCTAssertEqual(HookSettings.addresses(in: m), [])
        XCTAssertEqual(HookSettings.strip(m), "--model x")
    }

    func testARingAddressThatCouldBreakTheCommandIsRefused() throws {
        let bad = ["https://x.example/ring?a=$(id)", "https://x.example/ri'ng", "file:///etc/passwd", "ssh://x.example/ring"]
        for s in bad {
            guard let u = URL(string: s) else { continue }
            XCTAssertFalse(HookSettings.isSafe(ring: u), s)
            XCTAssertFalse(HookSettings.json(ring: u, addresses: ["a1"], bots: ["t1"]).contains("curl"), s)
            XCTAssertThrowsError(try HookSettings.merged("", ring: u, addresses: ["a1"], bots: [])) {
                XCTAssertEqual($0 as? HookSettings.Problem, .unsafeRing)
            }
        }
        XCTAssertTrue(HookSettings.isSafe(ring: ring))
        // What URL already encodes (a backtick, a space, a double quote) cannot reach the shell as itself.
        if let u = URL(string: "https://x.example/ring?a=`id` \"x\"") { XCTAssertFalse(u.absoluteString.contains("`")); XCTAssertTrue(HookSettings.isSafe(ring: u)) }
        XCTAssertTrue(HookSettings.isSafe(ring: URL(string: "http://10.0.0.2:8787/ring?v=1&k=2;x")!))
    }

    #if os(macOS)
    /// Runs the hook's command in a real shell with `curl` replaced by a function that writes its arguments to a
    /// temporary file: the ring address arrives whole (its `&` and `;` once cut the command in two), the body is JSON.
    func testTheCommandRunsInAShell() throws {
        let odd = URL(string: "https://push.example.com/api/ring?v=1&k=2;x")!
        let args = try HookSettings.merged("", ring: odd, addresses: ["addr-1"], bots: ["mcp:t1"])
        XCTAssertEqual(args.filter { $0 == "'" }.count, 2, "one pair of single quotes, around the whole JSON")
        let json = String(args.dropFirst("--settings '".count).dropLast())
        for (hook, kind) in [("PermissionRequest", "request"), ("Stop", "reply")] {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("t3bot-hook-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: out) }
            let cmd = try command(json, hook).replacingOccurrences(of: "& done;", with: "& done; wait;")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "curl() { for x in \"$@\"; do printf '%s\\n' \"$x\"; done > \"$OUT\"; }\n" + cmd]
            p.environment = ["OUT": out.path, "T3CODE_THREAD_ID": "mcp:t1", "PATH": "/usr/bin:/bin"]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.last, odd.absoluteString, hook)
            let body = try XCTUnwrap(lines.firstIndex(of: "--data").map { lines[$0 + 1] })
            let sent = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
            XCTAssertEqual(sent, ["to": "addr-1", "thread": "mcp:t1", "kind": kind])
        }
    }

    /// A thread that is no bot does not ring when it finishes.
    func testAnotherThreadsStopDoesNotRing() throws {
        let args = try HookSettings.merged("", ring: ring, addresses: ["addr-1"], bots: ["mcp:t1"])
        let json = String(args.dropFirst("--settings '".count).dropLast())
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("t3bot-hook-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let cmd = try command(json, "Stop").replacingOccurrences(of: "& done;", with: "& done; wait;")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "curl() { echo rang > \"$OUT\"; }\n" + cmd]
        p.environment = ["OUT": out.path, "T3CODE_THREAD_ID": "mcp:other", "PATH": "/usr/bin:/bin"]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
    #endif
}

// MARK: The router and the backend's small parts

final class RouterHardeningTests: XCTestCase {
    func backend() -> DirectBackend {
        let d = UserDefaults(suiteName: "t3bot.tests.\(UUID().uuidString)")!
        let config = DirectConfig(base: URL(string: "http://127.0.0.1:9")!, token: "t", environmentId: "e", label: "Test")
        return DirectBackend(config: config, live: false, bots: BotStore(store: DefaultsStore(d)), local: DefaultsStore(d))
    }

    func testWhatOnlyAServerDoes() {
        for p in ["v1/test-push", "v1/file", "v1/avatars/chief.png", "v1/avatars"] { XCTAssertTrue(DirectRouter.isServerOnly(p), p) }
        for p in ["v1/home", "v1/filex", "v1/agents/a/send", "", "v1"] { XCTAssertFalse(DirectRouter.isServerOnly(p), p) }
        XCTAssertFalse(DirectRouter.needsServer.contains("\u{2014}"))
    }

    func testServerOnlyPathsSayWhy() async {
        let b = backend()
        for path in ["v1/file?path=/tmp/x.png", "/v1/avatars/chief.png"] {
            do { _ = try await DirectRouter.get(b, path); XCTFail(path) } catch {
                XCTAssertEqual(error as? T3Error, .rpc(DirectRouter.needsServer), path)
                XCTAssertEqual(error.localizedDescription, DirectRouter.needsServer)
            }
        }
        do { _ = try await DirectRouter.post(b, "v1/test-push", [:]); XCTFail("test-push") } catch {
            XCTAssertEqual(error as? T3Error, .rpc(DirectRouter.needsServer))
        }
    }

    func testAnUnknownPathIsNotFound() async {
        let b = backend()
        do { _ = try await DirectRouter.get(b, "v1/never-heard-of-it"); XCTFail("unknown") } catch {
            XCTAssertEqual(error as? T3Error, .http(404, "not found: v1/never-heard-of-it"))
        }
        do { _ = try await DirectRouter.post(b, "v1/never-heard-of-it", [:]); XCTFail("unknown") } catch {
            guard case .http(404, _)? = error as? T3Error else { return XCTFail("\(error)") }
        }
    }

    func testOddPaths() {
        XCTAssertEqual(DirectRouter.split("").0, "")
        XCTAssertEqual(DirectRouter.split("///v1/home").0, "v1/home")
        XCTAssertEqual(DirectRouter.split("v1/search?q=").1["q"], "")
        XCTAssertEqual(DirectRouter.split("v1/search?").1.count, 0)
        XCTAssertNil(DirectRouter.agentPath("v1/agents/", suffix: nil))
    }
}

final class BackoffTests: XCTestCase {
    func testDoublesToACapAndStartsOver() {
        var b = Backoff()
        let now = Date()
        XCTAssertTrue(b.mayTry(now: now), "nothing failed yet")
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            b.failed(now: now)
            waits.append(b.retryAt.timeIntervalSince(now))
        }
        XCTAssertEqual(waits, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertFalse(b.mayTry(now: now.addingTimeInterval(29)))
        XCTAssertTrue(b.mayTry(now: now.addingTimeInterval(30)))
        b.succeeded()
        XCTAssertTrue(b.mayTry(now: now))
        b.failed(now: now)
        XCTAssertEqual(b.retryAt.timeIntervalSince(now), 1, "back to one second after a connection that worked")
    }

    func testAStreamThatWasReplacedCannotFreeItsPlace() {
        var slots = StreamSlots()
        let old = slots.start("shell")
        let new = slots.start("shell")
        let other = slots.start("thread-1")
        XCTAssertFalse(slots.end("shell", old), "the cancelled stream ends late: its replacement keeps the place")
        XCTAssertTrue(slots.end("shell", new))
        XCTAssertFalse(slots.end("shell", new), "only once")
        XCTAssertTrue(slots.end("thread-1", other))
        XCTAssertFalse(slots.end("never-started", 1))
    }
}
