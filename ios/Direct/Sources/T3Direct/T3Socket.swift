import Foundation

// One websocket to a T3 Code environment, speaking Effect RPC as JSON (what T3 Code's own clients speak):
//   client -> {"_tag":"Request","id":"7","tag":"orchestration.dispatchCommand","payload":{...},"headers":[]}
//   server -> {"_tag":"Chunk","requestId":"7","values":[...]}   (a stream's values; the client answers "Ack")
//   server -> {"_tag":"Exit","requestId":"7","exit":{"_tag":"Success","value":...} | {"_tag":"Failure","cause":...}}
//   server -> {"_tag":"Ping"}  client -> {"_tag":"Pong"}; client -> {"_tag":"Interrupt","requestId":"7","interruptors":[]}
// A frame may also be an array of these. The socket opens with a one-time ticket from the HTTP API.

typealias JSON = [String: Any]

/// The websocket under a T3Socket: URLSession's in the app, a fake in the tests.
protocol T3Transport: AnyObject {
    func resume()
    func send(_ text: String, _ done: @escaping (Error?) -> Void)
    func receive(_ done: @escaping (Result<Data, Error>) -> Void)
    func ping(_ done: @escaping (Error?) -> Void)
    func cancel()
}

final class URLSessionTransport: T3Transport {
    private let task: URLSessionWebSocketTask
    init(_ session: URLSession, _ url: URL) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
    }
    func resume() { task.resume() }
    func send(_ text: String, _ done: @escaping (Error?) -> Void) { task.send(.string(text), completionHandler: done) }
    func receive(_ done: @escaping (Result<Data, Error>) -> Void) {
        task.receive { result in
            switch result {
            case let .failure(e): done(.failure(e))
            case let .success(.string(s)): done(.success(Data(s.utf8)))
            case let .success(.data(d)): done(.success(d))
            @unknown default: done(.success(Data()))
            }
        }
    }
    func ping(_ done: @escaping (Error?) -> Void) { task.sendPing(pongReceiveHandler: done) }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

final class T3Socket: @unchecked Sendable {
    enum State: Equatable { case idle, connecting, open, closed(String) }

    private let base: URL
    private let token: String
    private let session: URLSession
    private var task: T3Transport?
    private let opener: (URL) -> T3Transport
    private let ticket: () async throws -> String
    /// Every `keepAlive` seconds the socket pings; a connection that stays silent for two whole intervals after a
    /// ping (the phone slept, the network changed, the Mac went away without closing) is closed, so the app
    /// reconnects instead of waiting on a dead line. Two, not one: on a slow network one large frame (the first
    /// load) can take longer than an interval, and its pong waits behind it. 0 turns it off.
    private let keepAlive: TimeInterval
    /// Intervals in a row with nothing heard since their ping.
    private var quiet = 0
    static let quietLimit = 2
    private let lock = NSLock()
    private var nextId = 1
    private var calls: [String: CheckedContinuation<Any?, Error>] = [:]
    private var streams: [String: AsyncThrowingStream<Any, Error>.Continuation] = [:]
    private var opened: CheckedContinuation<Void, Error>?
    private(set) var state: State = .idle
    /// Called on the socket's queue when it closes for any reason (to reconnect or report).
    var onClose: (@Sendable (String) -> Void)?

    init(base: URL, token: String, session: URLSession = .shared, keepAlive: TimeInterval = 20,
         opener: ((URL) -> T3Transport)? = nil, ticket: (() async throws -> String)? = nil) {
        self.base = base
        self.token = token
        self.session = session
        self.keepAlive = keepAlive
        self.opener = opener ?? { URLSessionTransport(session, $0) }
        self.ticket = ticket ?? { try await T3Link.ticket(base, token: token, session: session) }
    }

    /// A socket nobody holds any more closes its connection instead of leaving it open on the Mac.
    deinit { task?.cancel() }

    // MARK: Opening

    func connect(timeout: TimeInterval = 15) async throws {
        let ticket = try await self.ticket()
        try Task.checkCancellation()
        let url = T3Link.socketURL(base, ticket: ticket)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                lock.lock()
                opened = c
                state = .connecting
                let t = opener(url)
                task = t
                lock.unlock()
                t.resume()
                receive(t)
                // The first frame proves the socket is open; T3 Code sends nothing until asked, so a ping does it.
                t.ping { [weak self] error in
                    guard let self else { return }
                    if let error { self.fail("could not open the connection: \(error.localizedDescription)") } else { self.markOpen(t) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let waiting = self.opened
                    self.opened = nil
                    self.lock.unlock()
                    if let waiting { waiting.resume(throwing: T3Error.timeout); self.close("timed out opening") }
                }
            }
        } onCancel: {
            // The caller gave up (the view went away): the wait ends now, not at the timeout.
            self.lock.lock()
            let waiting = self.opened
            self.opened = nil
            self.lock.unlock()
            if let waiting { waiting.resume(throwing: CancellationError()); self.close("cancelled") }
        }
    }

    private func markOpen(_ t: T3Transport) {
        lock.lock()
        // A pong that comes after the open timed out or the socket closed opens nothing.
        guard task === t, state == .connecting else { lock.unlock(); return }
        let c = opened
        opened = nil
        state = .open
        quiet = 0
        lock.unlock()
        c?.resume()
        watch(t)
    }

    /// The keep-alive: a ping each interval, and the end of a connection that answered nothing since the last one.
    private func watch(_ t: T3Transport) {
        guard keepAlive > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + keepAlive) { [weak self, weak t] in
            guard let self, let t else { return }
            self.lock.lock()
            guard self.task === t, self.state == .open else { self.lock.unlock(); return }
            let dead = self.quiet >= T3Socket.quietLimit
            self.quiet += 1
            self.lock.unlock()
            if dead { self.fail("the connection went quiet"); return }
            t.ping { [weak self] error in if error == nil { self?.alive() } }
            self.watch(t)
        }
    }

    private func alive() { lock.lock(); quiet = 0; lock.unlock() }

    /// One ping, now: true when the other side answers within `timeout`. For a caller that wants to know at once
    /// whether an open socket is still a real line (after the app was away, after the network changed) instead of
    /// waiting for the keep-alive. Closes nothing by itself.
    func ping(timeout: TimeInterval = 3) async -> Bool {
        lock.lock()
        guard let t = task, state == .open else { lock.unlock(); return false }
        lock.unlock()
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            t.ping { [weak self] error in
                guard once.first() else { return }
                if error == nil { self?.alive() }
                c.resume(returning: error == nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.first() { c.resume(returning: false) }
            }
        }
    }

    func close(_ why: String = "closed") {
        lock.lock()
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
        fail(why)
    }

    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return state == .open && task != nil }

    // MARK: Calls

    private func newId() -> String {
        lock.lock(); defer { lock.unlock() }
        let id = String(nextId)
        nextId += 1
        return id
    }

    /// One request, one answer (the Exit's value).
    func call(_ tag: String, _ payload: Any, timeout: TimeInterval = 25) async throws -> Any? {
        let id = newId()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any?, Error>) in
                lock.lock()
                guard let t = task, state == .open else { lock.unlock(); c.resume(throwing: T3Error.notConnected); return }
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                calls[id] = c
                lock.unlock()
                send(t, ["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]]) { [weak self] error in
                    if let error { self?.finish(id, .failure(T3Error.rpc("could not send: \(error.localizedDescription)"))) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(id, .failure(T3Error.timeout))
                }
            }
        } onCancel: {
            // The caller gave up: it gets its answer now, and T3 Code is told to stop working on it.
            self.lock.lock()
            let c = self.calls.removeValue(forKey: id)
            let t = self.task
            self.lock.unlock()
            guard let c else { return }
            c.resume(throwing: CancellationError())
            if let t { self.send(t, ["_tag": "Interrupt", "requestId": id, "interruptors": [] as [Any]], nil) }
        }
    }

    /// A stream: every value of every Chunk, until the server ends it or `cancel` interrupts it.
    func stream(_ tag: String, _ payload: Any) -> (id: String, values: AsyncThrowingStream<Any, Error>) {
        let id = newId()
        let s = AsyncThrowingStream<Any, Error> { cont in
            lock.lock()
            guard let t = task, state == .open else { lock.unlock(); cont.finish(throwing: T3Error.notConnected); return }
            streams[id] = cont
            lock.unlock()
            cont.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.interrupt(id) }
            }
            send(t, ["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [] as [Any]]) { [weak self] error in
                if let error { self?.endStream(id, T3Error.rpc("could not send: \(error.localizedDescription)")) }
            }
        }
        return (id, s)
    }

    func interrupt(_ id: String) {
        lock.lock()
        let t = task
        let had = streams.removeValue(forKey: id) != nil
        lock.unlock()
        guard had, let t else { return }
        send(t, ["_tag": "Interrupt", "requestId": id, "interruptors": [] as [Any]], nil)
    }

    // MARK: Wire

    private func send(_ t: T3Transport, _ msg: JSON, _ done: ((Error?) -> Void)?) {
        guard let data = T3JSON.data(msg), let s = String(data: data, encoding: .utf8) else {
            done?(T3Error.rpc("could not encode the request")); return
        }
        t.send(s) { error in done?(error) }
    }

    private func receive(_ t: T3Transport) {
        t.receive { [weak self, weak t] result in
            guard let self, let t else { return }
            switch result {
            case let .failure(error):
                // An old connection that ends late must not close the one that replaced it.
                self.lock.lock()
                let current = self.task === t
                self.lock.unlock()
                if current { self.fail("the connection dropped: \(error.localizedDescription)") }
            case let .success(data):
                self.alive()
                self.handle(data, on: t)
                self.lock.lock()
                let still = self.task === t
                self.lock.unlock()
                if still { self.receive(t) }
            }
        }
    }

    private func handle(_ data: Data, on t: T3Transport) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        // One frame or a list of them; anything in the list that is not a frame is passed over.
        let messages: [JSON] = (obj as? [Any])?.compactMap { $0 as? JSON } ?? ((obj as? JSON).map { [$0] } ?? [])
        for m in messages {
            let tag = m["_tag"] as? String
            let rid = (m["requestId"] as? String) ?? (m["requestId"] as? NSNumber)?.stringValue ?? ""
            switch tag {
            case "Ping":
                send(t, ["_tag": "Pong"], nil)
            case "Chunk":
                let values = m["values"] as? [Any] ?? []
                lock.lock()
                let cont = streams[rid]
                let isCall = calls[rid] != nil
                lock.unlock()
                if let cont {
                    for v in values { cont.yield(v) }
                    send(t, ["_tag": "Ack", "requestId": rid], nil)
                } else if isCall {
                    // A stream asked through `call`: its first value is the answer.
                    finish(rid, .success(values.first))
                    send(t, ["_tag": "Interrupt", "requestId": rid, "interruptors": [] as [Any]], nil)
                }
            case "Exit":
                let exit = m["exit"] as? JSON ?? [:]
                let ok = (exit["_tag"] as? String) == "Success"
                let err = ok ? nil : T3Error.rpc(T3Socket.describe(exit))
                lock.lock()
                let cont = streams.removeValue(forKey: rid)
                lock.unlock()
                if let cont { if let err { cont.finish(throwing: err) } else { cont.finish() } }
                finish(rid, ok ? .success(exit["value"]) : .failure(err!))
            case "Defect", "ClientProtocolError":
                fail("T3 Code refused the request: \(T3Socket.describe(m))")
            default:
                break
            }
        }
    }

    private func finish(_ id: String, _ result: Result<Any?, Error>) {
        lock.lock()
        let c = calls.removeValue(forKey: id)
        lock.unlock()
        c?.resume(with: result)
    }

    private func endStream(_ id: String, _ error: Error) {
        lock.lock()
        let c = streams.removeValue(forKey: id)
        lock.unlock()
        c?.finish(throwing: error)
    }

    private func fail(_ why: String) {
        lock.lock()
        let pendingCalls = calls
        let pendingStreams = streams
        let open = opened
        calls = [:]
        streams = [:]
        opened = nil
        let wasClosed: Bool
        if case .closed = state { wasClosed = true } else { wasClosed = false }
        state = .closed(why)
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
        open?.resume(throwing: T3Error.rpc(why))
        for c in pendingCalls.values { c.resume(throwing: T3Error.closed) }
        for s in pendingStreams.values { s.finish(throwing: T3Error.closed) }
        if !wasClosed { onClose?(why) }
    }

    /// A failure's cause as one readable line ("Unauthorized: ...", or the tagged error's message).
    static func describe(_ x: Any?) -> String {
        guard let x else { return "unknown error" }
        if let d = x as? JSON {
            for k in ["message", "reason", "error"] { if let s = d[k] as? String, !s.isEmpty { return s } }
            for k in ["cause", "error", "defect", "failure"] { if let inner = d[k] { let s = describe(inner); if s != "unknown error" { return s } } }
            if let tag = d["_tag"] as? String, !["Fail", "Failure", "Die", "Sequential", "Parallel"].contains(tag) { return tag }
            if let l = d["left"] { return describe(l) }
        }
        if let s = x as? String { return s }
        if let data = T3JSON.data(x), let s = String(data: data, encoding: .utf8) { return String(s.prefix(300)) }
        return "unknown error"
    }
}

/// True once, then false: for two callbacks that race to answer one continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
