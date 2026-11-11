import UIKit
import UserNotifications

/// Pushes come from the T3 Bot server over APNs. Each category has the buttons that fit it, so most things
/// can be answered from the lock screen or the watch without opening the app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        // A new install is asked once it has a server to hear from (Store.connect), not on the connect screen.
        if Connection.current != nil { Self.askForPush() }
        return true
    }

    /// Asks for notifications (iOS shows its question once) and registers this phone for pushes.
    static func askForPush() {
        #if DEBUG
        // Simulator screen checks launch with -noPushPrompt: no alert over the screens being captured.
        if ProcessInfo.processInfo.arguments.contains("-noPushPrompt") { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    /// What the server put in a push. Servers from before the rename to T3 Bot used the key "crew".
    static func payload(_ content: UNNotificationContent) -> [String: Any] {
        (content.userInfo["t3bot"] as? [String: Any]) ?? (content.userInfo["crew"] as? [String: Any]) ?? [:]
    }

    static let categories: Set<UNNotificationCategory> = {
        let handle = UNNotificationAction(identifier: "HANDLE", title: "Handle it", options: [.foreground])
        let done = UNNotificationAction(identifier: "DONE", title: "Done", options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Not now", options: [])
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.authenticationRequired])
        let decline = UNNotificationAction(identifier: "DECLINE", title: "Decline", options: [.destructive])
        let answer = UNTextInputNotificationAction(identifier: "ANSWER", title: "Answer", options: [.authenticationRequired],
                                                   textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        return [
            UNNotificationCategory(identifier: "CARD", actions: [handle, done, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "QUESTION", actions: [answer], intentIdentifiers: []),
            // A T3 Code pairing's generic push, before the notification extension names it.
            UNNotificationCategory(identifier: "T3REQUEST", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "QUESTION_MULTI", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "APPROVAL", actions: [approve, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: "REPLY", actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "DIGEST", actions: [], intentIdentifiers: []),
        ]
    }()

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // The store sends it to the server, and again after a pairing or a failed try.
        Task { @MainActor in Store.shared.registered(deviceToken: hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Shown in Settings, under Notifications, where it stays until iOS registers this phone.
        Task { @MainActor in Store.shared.pushError = "Push not available: \(error.localizedDescription)" }
    }

    /// A bot's answer reached the phone while T3 Bot was in memory: its Live Activity ends with that answer.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let t3 = userInfo["t3"] as? [String: Any]
        Task { @MainActor in
            await Store.shared.refresh()
            if (t3?["kind"] as? String) == "reply", let thread = t3?["thread"] as? String,
               let a = Store.shared.home?.agents.first(where: { $0.threadId == thread }) {
                await Store.shared.loadTimeline(a.id)
                let text = Store.shared.timelines[a.id]?.entries.last { $0.type == "agent" && $0.working != true }?.text ?? ""
                Store.shared.endLive(a.id, text: text)
            }
            completionHandler(.newData)
        }
    }

    // A push for the chat already on screen only refreshes it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let payload = Self.payload(notification.request.content)
        let agent = payload["agent"] as? String
        let category = notification.request.content.categoryIdentifier
        // Decide at once (a slow server must never hold the banner back), then refresh behind it.
        Task { @MainActor in
            if category == "REPLY", let agent, agent == Store.shared.currentAgent {
                completionHandler([])
            } else {
                completionHandler([.banner, .list, .sound])
            }
            await Store.shared.refresh()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = Self.payload(response.notification.request.content)
        let named = payload["agent"] as? String
        let cardId = payload["cardId"] as? String
        let threadId = payload["threadId"] as? String
        let requestId = payload["requestId"] as? String
        let questionId = payload["questionId"] as? String
        let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)

        let content = response.notification.request.content
        // On the main actor: the store is read and changed here, and iOS is told "finished" on the main thread.
        Task { @MainActor in
            // A push that names no bot belongs to the one that leads.
            let agent = named ?? Store.shared.chiefId
            // False once an action could not be sent: said on the lock screen, never dropped in silence.
            var sent = true
            switch response.actionIdentifier {
            case "DONE", "SNOOZE", "HANDLE":
                if let cardId {
                    let action = response.actionIdentifier == "DONE" ? "done" : response.actionIdentifier == "SNOOZE" ? "snooze" : "handle"
                    sent = await Self.deliver("v1/cards/\(action)", ["id": cardId])
                    if action == "handle" { Store.shared.open(agent: agent) }
                    if !sent { Self.notSent(action == "done" ? "\u{201C}Done\u{201D}" : action == "snooze" ? "\u{201C}Not now\u{201D}" : "\u{201C}Handle it\u{201D}", content) }
                }
            case "APPROVE", "DECLINE":
                if let threadId, let requestId {
                    let approve = response.actionIdentifier == "APPROVE"
                    sent = await Self.deliver("v1/answer", ["threadId": threadId, "requestId": requestId, "decision": approve ? "accept" : "decline"])
                    if !sent { Self.notSent(approve ? "\u{201C}Approve\u{201D}" : "\u{201C}Decline\u{201D}", content) }
                }
            case let id where id.hasPrefix("OPT:"):
                // One of the question's own options, tapped on the lock screen.
                let options = payload["options"] as? [String] ?? []
                if let threadId, let requestId, let questionId, let i = Int(id.dropFirst(4)), i < options.count {
                    sent = await Self.deliver("v1/answer", ["threadId": threadId, "requestId": requestId, "answers": [questionId: options[i]]])
                    if !sent { Self.notSent("\u{201C}\(options[i])\u{201D}", content) }
                }
            case "ANSWER":
                if let threadId, let requestId, let questionId, let text, !text.isEmpty {
                    sent = await Self.deliver("v1/answer", ["threadId": threadId, "requestId": requestId, "answers": [questionId: text]])
                    if !sent { Self.notSent("Your answer", content) }
                }
            case "REPLY":
                if let text, !text.isEmpty {
                    sent = await Self.deliver("v1/agents/\(agent)/send", ["text": text])
                    if !sent {
                        // What was typed waits in that chat's message field, unless something is already there.
                        if Store.shared.drafts[agent] == nil { Store.shared.saveDraft(text, for: agent) }
                        Self.notSent("Your reply", content)
                    }
                }
            default:
                if named == nil, cardId == nil, payload["kind"] != nil, (threadId ?? "").isEmpty {
                    // A ring from T3 Code that names no thread (its hook had no thread id): the app's home, where
                    // what waits is listed, not the leading bot's chat.
                    Store.shared.path = .init()
                    Store.shared.currentAgent = nil
                } else {
                    Store.shared.open(agent: agent)
                }
                if let cardId, cardId.hasPrefix("req:") || cardId.hasPrefix("desk:") || cardId.hasPrefix("note:") {
                    await Store.shared.open(card: cardId)
                }
            }
            // After a failure the server is away: no second wait on it before iOS is told this is finished.
            if sent { await Store.shared.refresh() }
            completionHandler()
        }
    }

    /// One action from a notification, with a second try: a VPN on the phone can need a moment to wake up.
    private static func deliver(_ path: String, _ body: [String: Any]) async -> Bool {
        for attempt in 0..<2 {
            do {
                try await API.post(path, body)
                return true
            } catch let APIError.status(code, _) where code == 200 || code == 404 {
                // The server says there is nothing left to act on (answered or done somewhere else): the app
                // shows what is true at its next refresh, and there is no failure to report.
                return true
            } catch APIError.status {
                // The server answered and refused: a second try changes nothing.
                return false
            } catch {
                // The second try goes out on new connections: the one kept from before can be dead.
                if attempt == 0 {
                    API.rebuildSessions()
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
        }
        return false
    }

    /// The action was not sent: a notification says so, and a tap on it opens the same bot or card.
    private static func notSent(_ what: String, _ original: UNNotificationContent) {
        let c = UNMutableNotificationContent()
        c.title = "Not sent"
        c.body = "\(what) could not be sent to your server. Open T3 Bot to try again."
        c.userInfo = original.userInfo
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
