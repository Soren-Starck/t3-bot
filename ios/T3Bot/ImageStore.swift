import CryptoKit
import SwiftUI
import UIKit

/// Every image the app shows (bot faces, skins, screenshots, photos), kept in memory and on disk, so a restart or a
/// slow network never leaves a blank: the saved copy shows at once and the network only refreshes it.
/// Failed loads retry with backoff (1, 3, 8 s) and again when the app comes back to the foreground.
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()
    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL = {
        let d = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appendingPathComponent("t3bot-images")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func file(_ key: String) -> URL {
        dir.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Memory, then disk. Instant; safe to call while drawing.
    func cached(_ key: String) -> UIImage? {
        if let m = memory.object(forKey: key as NSString) { return m }
        guard let data = try? Data(contentsOf: file(key)), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    /// The image for `key`, fetched from the server (`path` relative to it) when not saved yet.
    func load(_ key: String, path: String, refresh: Bool = false) async -> UIImage? {
        if !refresh, let c = cached(key) { return c }
        // A stock face ("skin:902"), carried by the app: no network, nothing to save.
        if path.hasPrefix("skin:") {
            let n = String(path.dropFirst(5))
            guard let u = Bundle.main.url(forResource: n, withExtension: "png", subdirectory: "skins"), let img = UIImage(contentsOfFile: u.path) else { return nil }
            memory.setObject(img, forKey: key as NSString)
            return img
        }
        // The connection is read once: a retry after a new pairing must not send the old path to the new server.
        guard let server = Connection.current else { return cached(key) }
        var url = API.url(path)
        // A picture T3 Code keeps (a bot's screenshot, a photo sent with a message): a short-lived link from T3 Code.
        if server.isDirect, path.hasPrefix("t3media:") || path.hasPrefix("t3attachment:") {
            guard let link = try? await DirectLink.backend(server).imageURL(path) else { return cached(key) }
            url = link
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        for delay in [0.0, 1.0, 3.0, 8.0] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if Task.isCancelled { break }
            if Connection.current != server { break }
            if let (data, resp) = try? await API.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               let img = UIImage(data: data) {
                if Connection.current != server { break }
                try? data.write(to: file(key), options: .atomic)
                memory.setObject(img, forKey: key as NSString)
                return img
            }
        }
        return cached(key)
    }

    /// Forgets every saved image. Keys are not tied to a server, so pairing with another one starts clean:
    /// its bots can share ids with the old ones.
    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// An image from the server, through ImageStore: saved copy first, network refresh behind, retry on the next foreground.
struct StoredImage<Placeholder: View>: View {
    let key: String
    let path: String
    var fallback: UIImage? = nil
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var attempt = 0
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let img = image ?? ImageStore.shared.cached(key) ?? fallback {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                placeholder()
            }
        }
        .task(id: "\(key)#\(attempt)") {
            if image == nil { image = ImageStore.shared.cached(key) }
            if image == nil { image = await ImageStore.shared.load(key, path: path) }
        }
        .onChange(of: phase) { _, p in if p == .active && image == nil { attempt += 1 } }
    }
}
