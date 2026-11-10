import UIKit
import WidgetKit

/// Mirrors each bot's face and color to where the extensions read them (Shared/SharedFaces.swift): the
/// widgets, the Live Activity (which cannot fetch anything), the notification extension and the share sheet.
///
/// Called after every home load; it only works on what changed. A face comes through ImageStore, so it is
/// the copy the app already has, and is written once per skin: the server's avatar path carries the skin's
/// version, so a new skin is mirrored again. Nothing here knows any bot by name.
@MainActor
enum FaceShare {
    private static let key = "t3bot.faces.mirrored"
    /// Bot id to the avatar path last mirrored.
    private static var mirrored: [String: String] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    /// Tried in this launch, so a bot the server has no picture of is not asked for at every refresh.
    private static var tried: [String: String] = [:]
    private static var busy: Set<String> = []
    private static var colors: [String: String]?
    /// A face was mirrored since the widgets last reloaded.
    private static var fresh = false

    static func sync(_ agents: [Agent]) {
        var hex: [String: String] = [:]
        for a in agents { if let c = a.color, !c.isEmpty { hex[a.id] = c } }
        if colors == nil { colors = SharedFaces.colors() }
        if colors != hex {
            // Kept as done even when the Keychain refused it (a build with no access group), so this is
            // not tried again at every refresh.
            SharedFaces.setColors(hex)
            colors = hex
        }

        let ids = Set(agents.map(\.id))
        for gone in Array(mirrored.keys) where !ids.contains(gone) {
            SharedFaces.setPicture(nil, for: gone)
            mirrored[gone] = nil
            UserDefaults.standard.set(mirrored, forKey: key)
        }

        // A group has no face of its own: it is drawn from its members' faces.
        for a in agents where a.kind != "group" {
            let id = a.id
            let path = AvatarView.avatarPath(id)
            guard mirrored[id] != path, tried[id] != path, !busy.contains(id) else { continue }
            busy.insert(id)
            tried[id] = path
            let server = Connection.current
            Task {
                let image = await ImageStore.shared.load("face:" + path, path: path)
                busy.remove(id)
                // Paired with another server (or disconnected) while this was on its way: not ours any more.
                if server == Connection.current, let png = image.flatMap({ small($0) }), SharedFaces.setPicture(png, for: id) {
                    mirrored[id] = path
                    UserDefaults.standard.set(mirrored, forKey: key)
                    fresh = true
                }
                if busy.isEmpty, fresh {
                    fresh = false
                    WidgetCenter.shared.reloadTimelines(ofKind: "needs")
                }
            }
        }
    }

    /// Forgets everything mirrored: the phone was paired with another server, or disconnected.
    static func forget() {
        mirrored = [:]
        tried = [:]
        colors = [:]
        fresh = false
        UserDefaults.standard.removeObject(forKey: key)
        SharedFaces.clear()
    }

    /// 132 pixels square: the largest face an extension draws (44 points) at 3x, and small enough for a
    /// Keychain item.
    private static func small(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let side: CGFloat = 132
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()
    }
}
