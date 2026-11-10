import Intents
import UIKit
import UserNotifications

/// Shows every T3 Bot push as coming from the bot that sent it: its face where the app icon would be (the app
/// icon becomes a small badge), its name as the title, and what kind of push it is under the name.
/// This is iOS's communication-notification style (an INSendMessageIntent from an INPerson with an image).
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        original = request.content
        let content = request.content
        // A server from before the rename sends the same data under "crew".
        let info = content.userInfo
        let payload = (info["t3bot"] as? [String: Any]) ?? (info["crew"] as? [String: Any]) ?? [:]
        let named = payload["agent"] as? String
        let name = payload["agentName"] as? String ?? content.title
        let label = payload["kindLabel"] as? String
        let color = payload["agentColor"] as? String
        Task {
            var agent = named ?? ""
            // A push that names no bot comes from the one the server calls its chief.
            if agent.isEmpty { agent = await Self.chief() ?? "" }
            if agent.isEmpty {
                // No bot to show it as: it arrives as the server sent it.
                self.finish(content)
                return
            }
            let image = await Self.avatar(agent, name: name, color: color)
            self.finish(Self.fromBot(content, agent: agent, name: name, label: label, image: image))
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let original { finish(original) }
    }

    private func finish(_ content: UNNotificationContent) {
        handler?(content)
        handler = nil
    }

    private static func fromBot(_ content: UNNotificationContent, agent: String, name: String, label: String?, image: Data?) -> UNNotificationContent {
        let person = INPerson(personHandle: INPersonHandle(value: agent, type: .unknown), nameComponents: nil, displayName: name,
                              image: image.map { INImage(imageData: $0) }, contactIdentifier: nil, customIdentifier: agent)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: agent, serviceName: nil, sender: person, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        guard let updated = try? content.updating(from: intent), let mutable = updated.mutableCopy() as? UNMutableNotificationContent else { return content }
        if let label, !label.isEmpty { mutable.subtitle = label }
        return mutable
    }

    /// The id of the bot the server calls its chief: asked from the server, else what it said last time.
    private static func chief() async -> String? {
        let key = "t3bot.chief"
        struct Hello: Decodable { var chief: String? = nil }
        if var r = Connection.load()?.request("v1/hello", timeout: 4) {
            r.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, _) = try? await URLSession.shared.data(for: r),
               let id = (try? JSONDecoder().decode(Hello.self, from: data))?.chief, !id.isEmpty {
                UserDefaults.standard.set(id, forKey: key)
                return id
            }
        }
        return UserDefaults.standard.string(forKey: key)
    }

    /// The bot's face, square: fresh from the server, else the copy this extension kept last time, else the
    /// one the app mirrored for its extensions, all on white. A bot with no picture anywhere gets its initial
    /// on its color, so the notification still shows who it is from. No build carries any bot's picture.
    private static func avatar(_ agent: String, name: String, color: String?) async -> Data? {
        // Bot ids are lowercase letters, digits and dashes; anything else has no face to ask for.
        let id = agent.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        var png: Data?
        if !id.isEmpty, id == agent {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("face-\(id).png")
            if var r = Connection.load()?.request("v1/avatars/\(id).png", timeout: 5) {
                r.cachePolicy = .reloadIgnoringLocalCacheData
                if let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil {
                    png = data
                    try? data.write(to: cache, options: .atomic)
                }
            }
            if png == nil { png = try? Data(contentsOf: cache) }
            if png == nil { png = SharedFaces.picture(id) }
        }
        let side: CGFloat = 240
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        if let png, let face = UIImage(data: png) {
            let out = UIGraphicsImageRenderer(size: square.size).image { _ in
                UIColor.white.setFill()
                UIRectFill(square)
                face.draw(in: CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8))
            }
            return out.pngData()
        }
        // The push says the bot's color when the server sends it; else what the app mirrored; else gray.
        let tint = Self.tint(color ?? SharedFaces.color(agent))
        let shown = name.trimmingCharacters(in: .whitespaces).isEmpty ? agent : name.trimmingCharacters(in: .whitespaces)
        let letter = String(shown.prefix(1)).uppercased() as NSString
        var font = UIFont.systemFont(ofSize: side * 0.46, weight: .semibold)
        if let rounded = font.fontDescriptor.withDesign(.rounded) { font = UIFont(descriptor: rounded, size: font.pointSize) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tint.light ? UIColor.black.withAlphaComponent(0.75) : UIColor.white,
        ]
        let out = UIGraphicsImageRenderer(size: square.size).image { _ in
            tint.color.setFill()
            UIRectFill(square)
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attributes)
        }
        return out.pngData()
    }

    /// "#RRGGBB" as a color, and whether it is light enough to need dark lettering. Gray when there is none.
    private static func tint(_ hex: String?) -> (color: UIColor, light: Bool) {
        let digits = (hex ?? "").filter { $0.isHexDigit }
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return (UIColor(white: 0.55, alpha: 1), false) }
        let r = CGFloat((v >> 16) & 0xFF) / 255, g = CGFloat((v >> 8) & 0xFF) / 255, b = CGFloat(v & 0xFF) / 255
        return (UIColor(red: r, green: g, blue: b, alpha: 1), 0.299 * r + 0.587 * g + 0.114 * b > 0.7)
    }
}
