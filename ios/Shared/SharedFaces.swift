import Foundation
import Security

/// The bots' faces and colors where the extensions can read them.
///
/// An extension cannot read the app's files, and the Live Activity cannot use the network at all, so the app
/// mirrors a small picture of each bot (and each bot's color) into the Keychain access group it shares with
/// its extensions, the same group that carries the pairing (`Connection`). The app writes
/// (T3Bot/FaceShare.swift); the widgets, the Live Activity, the notification extension and the share sheet
/// read. The pictures come from the server (`/v1/avatars/<id>.png`), so nothing here knows any bot by name.
///
/// Every failure is silent. A build with no access group (a simulator build without signing) keeps nothing
/// here, and each reader then draws the bot's initial on its color.
///
/// Compiled into all four targets. Foundation and Security only.
enum SharedFaces {
    private static let service = "t3bot.faces"
    /// Bot ids are lowercase letters, digits and dashes, so this account can never be a bot.
    private static let colorsAccount = "#colors"
    /// A face is kept at 132 pixels, 10 to 30 KB as PNG. Anything much bigger does not belong in a Keychain.
    static let limit = 150_000

    private static func query(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        if let group = Connection.keychainGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Replaces what is kept under `account`; nil removes it. True when the Keychain took it.
    private static func write(_ data: Data?, _ account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return true }
        var add = query(account)
        add[kSecValueData as String] = data
        // Read by the notification extension and the Live Activity while the phone is locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Only what a bot id is made of, so an id from a push or a link can never name another item.
    private static func account(_ bot: String) -> String? {
        let ok = !bot.isEmpty && bot.count <= 64 && bot.unicodeScalars.allSatisfy { s in
            (s.value >= 97 && s.value <= 122) || (s.value >= 48 && s.value <= 57) || s.value == 45
        }
        return ok ? bot : nil
    }

    /// The bot's picture as PNG data, if the app has mirrored one.
    static func picture(_ bot: String) -> Data? {
        account(bot).flatMap(read)
    }

    /// Keeps this picture for the bot, or forgets the bot's picture when `png` is nil.
    @discardableResult
    static func setPicture(_ png: Data?, for bot: String) -> Bool {
        guard let account = account(bot) else { return false }
        if let png, png.isEmpty || png.count > limit { return false }
        return write(png, account)
    }

    /// Every bot's color, as the server gives it ("#RRGGBB"), by bot id.
    static func colors() -> [String: String] {
        guard let data = read(colorsAccount),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return map
    }

    static func color(_ bot: String) -> String? { colors()[bot] }

    @discardableResult
    static func setColors(_ colors: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: colors) else { return false }
        return write(data, colorsAccount)
    }

    /// Forgets every face and color: the phone was paired with another server, or disconnected.
    static func clear() {
        SecItemDelete(query(nil) as CFDictionary)
    }
}
