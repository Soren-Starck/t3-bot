import Foundation
import UIKit

/// What a scanned code, a pasted link or the typed form points at: a T3 Bot server (`t3bot://connect?...`), or
/// T3 Code itself (its own pairing links: `https://<host>/pair#token=`, `t3code://pair?...`, `app.t3.codes/pair?host=`).
enum PairTarget: Equatable {
    case server(Connection)
    case t3code(T3PairingInput)

    static func from(_ text: String) -> PairTarget? {
        if let c = Connection.parse(link: text) { return .server(c) }
        if let p = T3Link.parse(link: text) { return .t3code(p) }
        return nil
    }

    var base: URL {
        switch self {
        case let .server(c): return c.url
        case let .t3code(p): return p.base
        }
    }

    /// The host, with the port when it is not the default one.
    var label: String {
        guard let host = base.host else { return base.absoluteString }
        return base.port.map { "\(host):\($0)" } ?? host
    }

    /// Pairs and returns the connection to save with what answered, or throws a PairingError or T3PairingError.
    func pair() async throws -> (Connection, Hello) {
        switch self {
        case let .server(c):
            return (c, try await API.hello(c))
        case let .t3code(p):
            let r = try await T3Link.pair(p, label: "T3 Bot on \(UIDevice.current.name)", os: "iOS \(UIDevice.current.systemVersion)", session: API.session)
            let c = Connection(url: p.base, token: r.token, kind: .t3code, environmentId: r.descriptor.environmentId, name: r.descriptor.label)
            return (c, Hello(ok: true, name: r.descriptor.label ?? "T3 Code", version: r.descriptor.serverVersion, user: nil, demo: false, push: nil, bots: nil,
                             t3: T3State(ok: true, error: nil)))
        }
    }

    /// The form's address and code or token: T3 Code when T3 Code answers at that address, else a T3 Bot server.
    static func typed(address: String, secret: String) async -> PairTarget? {
        let code = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        if let base = T3Link.baseURL(address), (try? await T3Link.descriptor(base, session: API.session)) != nil {
            return .t3code(T3PairingInput(base: base, code: code))
        }
        return Connection.make(address, code).map { .server($0) }
    }
}
