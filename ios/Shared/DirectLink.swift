import Foundation

/// The DirectBackend for the current T3 Code pairing, one per connection. In the app it keeps T3 Code's streams
/// open while it runs; in an extension (widgets, notifications, share sheet) it reads over HTTP only.
///
/// Compiled into all four targets.
enum DirectLink {
    private static let lock = NSLock()
    private static var cached: (connection: Connection, backend: DirectBackend)?

    /// True in the app itself, false in an extension (whose bundle is an .appex).
    static var isApp: Bool { !Bundle.main.bundlePath.hasSuffix(".appex") }

    static func backend(_ c: Connection) -> DirectBackend {
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.connection == c { return cached.backend }
        let b = DirectBackend(config: DirectConfig(base: c.url, token: c.token, environmentId: c.environmentId ?? "", label: c.name ?? c.label), live: isApp)
        cached = (c, b)
        return b
    }

    /// The backend of the current pairing, when it is a T3 Code one.
    static var current: DirectBackend? {
        guard let c = Connection.current, c.isDirect else { return nil }
        return backend(c)
    }

    /// After a failure, when the app is back on screen, when the network changed: the current backend checks its
    /// socket (a ping) and replaces it, with its session, when it no longer answers. Does nothing in an extension,
    /// which keeps no socket, and for a T3 Bot server pairing. True when the socket in place answered.
    @discardableResult
    static func reconnect() async -> Bool {
        guard isApp, let b = current else { return false }
        return await b.reconnect()
    }

    static func reset() {
        lock.lock()
        let old = cached?.backend
        cached = nil
        lock.unlock()
        if let old { Task { await old.pause() } }
    }
}
