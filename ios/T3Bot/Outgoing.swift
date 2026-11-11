import UIKit

/// The photos of messages on their way, kept on this phone so their bubble shows them at once (and the "Not sent"
/// bubble still has them), instead of "[1 photo]" until the bot's copy arrives.
@MainActor
enum Outgoing {
    private static var images: [String: UIImage] = [:]
    /// The ids, oldest first: a dictionary has no order, so dropping "its first key" could drop the photo just added.
    private static var order: [String] = []

    /// Keeps a photo and returns its id (used as `local:<id>` in a bubble).
    static func put(_ data: Data) -> String {
        let id = UUID().uuidString
        if let img = UIImage(data: data) { images[id] = img; order.append(id) }
        // A few dozen at most: older ones have long reached the bot.
        while order.count > 40 { images.removeValue(forKey: order.removeFirst()) }
        return id
    }

    static func image(_ id: String) -> UIImage? { images[id] }
}
