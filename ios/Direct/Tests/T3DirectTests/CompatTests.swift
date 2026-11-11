import XCTest
@testable import T3Direct

// Other versions of T3 Code than the one T3 Bot was built against. The JSON here follows T3 Code's own contracts
// (packages/contracts/src/environment.ts, apps/server/src/ws.ts) at three points: a host from before protocol
// negotiation, the first protocol 2 builds (0.0.46-nightly.20261003, stable 0.1.0 to 0.1.4), and main of 9 Nov 2026.

final class CompatTests: XCTestCase {
    func descriptor(_ json: String) throws -> T3Descriptor { try JSONDecoder().decode(T3Descriptor.self, from: Data(json.utf8)) }

    /// ExecutionEnvironmentDescriptor before `orchestrationProtocolVersion` existed: T3 Code's own CLI reads that as 1.
    func testAHostFromBeforeProtocolVersionsIsToldItIsTooOld() throws {
        let d = try descriptor(#"{"environmentId":"env-1","label":"Old Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.0.40","capabilities":{"repositoryIdentity":true}}"#)
        XCTAssertNil(d.orchestrationProtocolVersion)
        XCTAssertThrowsError(try T3Link.check(d)) { e in
            XCTAssertEqual(e as? T3PairingError, .tooOld(1, "0.0.40"))
            let text = (e as? T3PairingError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("too old"), text)
            XCTAssertTrue(text.contains("0.0.40"), text)
            XCTAssertTrue(text.contains("0.1.0"), text)
            XCTAssertTrue(text.contains("Update T3 Code"), text)
        }
    }

    /// The descriptor of 15 Sept to 3 Oct 2026, protocol 1.
    func testProtocolOneIsTooOld() throws {
        let d = try descriptor(#"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.0.45","orchestrationProtocolVersion":1,"capabilities":{"repositoryIdentity":true}}"#)
        XCTAssertThrowsError(try T3Link.check(d)) { XCTAssertEqual($0 as? T3PairingError, .tooOld(1, "0.0.45")) }
    }

    /// The first protocol 2 nightly and the latest stable release: same descriptor shape, fewer capabilities.
    func testTheFirstProtocolTwoBuildsAndTheStableReleasePair() throws {
        for version in ["0.0.46-nightly.20261003.2610", "0.1.0", "0.1.4"] {
            let d = try descriptor(#"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"\#(version)","orchestrationProtocolVersion":2,"capabilities":{"repositoryIdentity":true,"desktopAppUpdate":true}}"#)
            XCTAssertNoThrow(try T3Link.check(d), version)
            XCTAssertEqual(d.serverVersion, version)
        }
    }

    /// main of 9 Nov 2026: `databaseMigration` and many new capabilities, still protocol 2.
    func testTodaysMainPairs() throws {
        let d = try descriptor(#"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.1.9-nightly.20261109.4301","orchestrationProtocolVersion":2,"databaseMigration":87,"capabilities":{"repositoryIdentity":true,"peerLinks":true,"linkFence":true,"triage":true,"voiceTranscription":false,"serverBrowser":true}}"#)
        XCTAssertNoThrow(try T3Link.check(d))
        XCTAssertEqual(d.platform?.os, "darwin")
    }

    /// A later protocol: T3 Code only accepts a client that sends exactly its version (ws.ts,
    /// hasCompatibleOrchestrationProtocol), so refusing here is right and not a false alarm.
    func testALaterProtocolIsTooNew() throws {
        let d = try descriptor(#"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.2.0","orchestrationProtocolVersion":3,"capabilities":{}}"#)
        XCTAssertThrowsError(try T3Link.check(d)) { XCTAssertEqual($0 as? T3PairingError, .tooNew(3)) }
    }

    /// What T3 Code answers (status 426) to a client that speaks another protocol, word for word from ws.ts.
    func testTheRefusalOfAnotherProtocolIsSaidInPlainWords() {
        let newer = #"{"code":"orchestration_protocol_incompatible","message":"Update this client to one that supports orchestration protocol 3.","orchestrationProtocolVersion":3}"#
        let a = T3Error.http(426, newer).errorDescription ?? ""
        XCTAssertTrue(a.contains("version 3"), a)
        XCTAssertTrue(a.contains("Update T3 Bot"), a)
        XCTAssertFalse(a.contains("{"), a)

        let older = #"{"code":"orchestration_protocol_incompatible","message":"Update this client to one that supports orchestration protocol 1.","orchestrationProtocolVersion":1}"#
        let b = T3Error.http(426, older).errorDescription ?? ""
        XCTAssertTrue(b.contains("Update T3 Code"), b)
        XCTAssertTrue(b.contains("0.1.0"), b)

        // Cut short (the app keeps 300 characters) or without the number: still words, never raw JSON alone.
        XCTAssertNotNil(T3Link.protocolRefusal(#"{"code":"orchestration_protocol_incompatible","mess"#))
        // Another 426, or another answer: unchanged.
        XCTAssertNil(T3Link.protocolRefusal("Upgrade Required"))
        XCTAssertEqual(T3Error.http(426, "Upgrade Required").errorDescription, "T3 Code answered 426: Upgrade Required")
        XCTAssertEqual(T3Error.http(500, "boom").errorDescription, "T3 Code answered 500: boom")
    }

    /// A shell with only the keys every protocol 2 build has sent since 3 Oct 2026 (no pinnedAt, settledAt,
    /// lineage, and no projects key): the thread still shows, with what is missing left empty.
    func testAShellWithoutTheNewerFieldsShowsItsThreads() throws {
        let json = #"{"snapshotSequence":41,"threads":[{"id":"thread-1","projectId":"p1","title":"Fix login","status":"idle","createdAt":"2026-10-03T10:00:00.000Z","updatedAt":"2026-10-03T10:05:00.000Z","archivedAt":null,"latestVisibleMessage":{"id":"m1","role":"assistant","text":"Done","createdAt":"2026-10-03T10:05:00.000Z"}}]}"#
        let shell = try JSONDecoder().decode(T3Shell.self, from: Data(json.utf8))
        XCTAssertEqual(shell.threads.map(\.id), ["thread-1"])
        XCTAssertEqual(shell.threads.first?.latestVisibleMessage?.text, "Done")
        XCTAssertNil(shell.threads.first?.pinnedAt)
        XCTAssertFalse(shell.threads.first?.isGone ?? true)
        XCTAssertEqual(shell.projects.count, 0)
        XCTAssertEqual(shell.snapshotSequence, 41)
    }

    // MARK: A T3 Code that changed after pairing

    /// The shell call with the header of protocol 2 against a server of another protocol: the header is a
    /// `Schema.Literal` of the server's own version (environmentHttp.ts, OrchestrationProtocolHeaders), so the
    /// answer is a 400. The app asks the descriptor and says which side to update. (The 400's body here is a
    /// stand-in, its wording is not in the contracts; only the status and the descriptor decide.)
    func testASnapshotRefusedByAnotherProtocolSaysWhichSideToUpdate() async {
        let session = StubServer.session()
        defer { StubServer.routes = [:] }
        let refused = (400, #"{"_tag":"HttpApiDecodeError","message":"Expected \"3\", actual \"2\" at [\"x-t3-orchestration-protocol\"]"}"#)
        let base = URL(string: "http://stub.test:3773")!
        func problem() async -> String {
            do { _ = try await T3Link.get(base, "/api/orchestration/shell", token: "t", session: session); return "" } catch { return error.localizedDescription }
        }

        StubServer.routes = ["/api/orchestration/shell": refused,
                             "/.well-known/t3/environment": (200, #"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.2.0","orchestrationProtocolVersion":3,"capabilities":{}}"#)]
        let newer = await problem()
        XCTAssertTrue(newer.contains("too new") && newer.contains("Update T3 Bot"), newer)

        StubServer.routes["/.well-known/t3/environment"] = (200, #"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.0.45","orchestrationProtocolVersion":1,"capabilities":{}}"#)
        let older = await problem()
        XCTAssertTrue(older.contains("too old") && older.contains("0.0.45") && older.contains("Update T3 Code"), older)

        // The same protocol: the 400 is about something else and stays as it was.
        StubServer.routes["/.well-known/t3/environment"] = (200, #"{"environmentId":"env-1","label":"Mac","platform":{"os":"darwin","arch":"arm64"},"serverVersion":"0.1.4","orchestrationProtocolVersion":2,"capabilities":{}}"#)
        let same = await problem()
        XCTAssertTrue(same.hasPrefix("T3 Code answered 400"), same)

        // A refused token is still a refused token, with no second request.
        StubServer.routes["/api/orchestration/shell"] = (401, "{}")
        StubServer.routes["/.well-known/t3/environment"] = nil
        let auth = await problem()
        XCTAssertTrue(auth.contains("Pair again"), auth)
    }
}

/// Answers URLSession from a table of paths, so no network is touched.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = StubServer.routes[request.url?.path ?? ""] ?? (404, "Not Found")
        let r = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
