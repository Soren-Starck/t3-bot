import SwiftUI
import UIKit
import UserNotifications

// The parts of Settings that do not depend on the server's settings file: which server this phone talks to,
// whether pushes can reach it, and what this app and server are. They show even when the server is away,
// which is when they are needed most.

/// Which server, how the link is doing, and the ways to change it.
struct SettingsConnectionSection: View {
    @EnvironmentObject var store: Store
    /// Closes Settings before the connect screen takes over.
    var close: () -> Void
    @State private var confirmDisconnect = false
    @State private var checking = false

    var body: some View {
        Section {
            HStack {
                // A coloured dot in the icon column, the words in the text colour, when it last answered under them.
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.text).foregroundStyle(.primary)
                        if !checking, store.online, let at = store.lastSync {
                            // "Updated just now", not a bare counter that ticks every second.
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Self.updated(at, now: context.date)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } icon: {
                    Circle().fill(status.color).frame(width: 10, height: 10)
                }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .combine)
            if let problem = t3Problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            // Where and what: for the curious, folded away.
            DisclosureGroup {
                LabeledContent("Address", value: Connection.current?.label ?? "None")
                if let hello = store.hello {
                    LabeledContent("Server", value: serverLine(hello))
                }
                // When it last answered and what went wrong the last time it did not: what to read when it says Offline.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("Last answer", value: Self.lastAnswer(store.link.lastSuccess, now: context.date))
                }
                if let problem = lastProblem {
                    Text(problem).font(.footnote).foregroundStyle(.secondary)
                }
                if let details {
                    Text(details).font(.footnote).foregroundStyle(.secondary)
                }
            } label: {
                // An icon like the rows under it, so every title starts on the same edge.
                Label("Details", systemImage: "info.circle")
            }
            Button {
                Haptics.tap()
                checking = true
                Task { @MainActor in
                    await store.refreshAll()
                    checking = false
                }
            } label: { Label("Reconnect now", systemImage: "arrow.clockwise") }
                .disabled(checking)
            Button { pairAnother() } label: { Label(Connection.current?.isDirect == true ? "Connect to another" : "Pair another server", systemImage: "qrcode.viewfinder") }
        } header: {
            // Not "Server": a row under it has that name.
            ListHeader(text: "Connection")
        } footer: {
            if let footer { Text(footer) }
        }
        // Leaving, apart from the rest.
        Section {
            Button(role: .destructive) { confirmDisconnect = true } label: {
                // Red on the icon too: the role alone colours only the title.
                Label("Disconnect", systemImage: "xmark.circle").foregroundStyle(.red)
            }
            // On the row, not the section: a modifier on a section is applied to each of its rows.
            .confirmationDialog("Disconnect from \(Connection.current?.label ?? "this server")?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    close()
                    store.disconnect()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Connection.current?.isDirect == true
                     ? "This phone forgets T3 Code, its chats and its token. Your threads and their work stay in T3 Code. Connect again any time by scanning a new link from T3 Code's Settings > Sharing & access."
                     : "This phone forgets the server, its chats and its token. Your bots and their work stay on the server. Pair again any time with t3bot pair.")
            }
        }
    }

    /// "Updated just now", "Updated 5m ago": when the server last answered.
    static func updated(_ at: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(at)))
        if s < 60 { return "Updated just now" }
        if s < 3600 { return "Updated \(s / 60)m ago" }
        return "Updated \(s / 3600)h ago"
    }

    /// "10:41, 3m ago", with the day when it was not today. "Never" before the first answer.
    static func lastAnswer(_ at: Date?, now: Date) -> String {
        guard let at else { return "Never" }
        let when = Calendar.current.isDate(at, inSameDayAs: now)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(date: .abbreviated, time: .shortened)
        let s = max(0, Int(now.timeIntervalSince(at)))
        if s < 60 { return "\(when), just now" }
        if s < 3600 { return "\(when), \(s / 60)m ago" }
        if s < 86400 { return "\(when), \(s / 3600)h ago" }
        return when
    }

    /// The last failed try, in one or two short sentences: when, why, and how many in a row while it is away.
    private var lastProblem: String? {
        let link = store.link
        guard let why = link.lastError, let at = link.lastErrorAt else { return nil }
        var text = "Last problem at \(at.formatted(date: .omitted, time: .standard)): \(why)."
        if !store.online, link.failures > 1 { text += " \(link.failures) tries in a row have failed; the app keeps trying." }
        return text
    }

    private var status: (text: String, symbol: String, color: Color) {
        if store.refused { return ("Token refused", "lock.slash", .red) }
        if store.online {
            let name = Connection.current?.isDirect == true ? "T3 Code" : store.hello?.demo == true ? "the demo" : "your server"
            return ("Connected to \(name)", "checkmark.circle.fill", .green)
        }
        return ("Offline", "wifi.slash", .orange)
    }

    /// What answers at that address. Its version is under About, once.
    private func serverLine(_ h: Hello) -> String {
        var parts = [h.name ?? "T3 Bot"]
        if h.demo == true { parts.append("demo") }
        return parts.joined(separator: " · ")
    }

    private var t3Problem: String? {
        guard let t3 = store.home?.t3 ?? store.hello?.t3, t3.ok == false else { return nil }
        return t3.error ?? "The server cannot reach T3 Code."
    }

    /// Only what the user must know now; the rest is under Details.
    private var footer: String? {
        if store.refused {
            return Connection.current?.isDirect == true
                ? "T3 Code answered but refused this phone's token. Scan a new link from T3 Code's Settings > Sharing & access."
                : "The server answered but refused this phone's token. Pair again with the link or the QR code from t3bot pair."
        }
        if store.hello?.demo == true { return "Made-up bots that answer by themselves, nothing real behind them." }
        return nil
    }

    private var details: String? {
        switch Connection.source {
        case .some(.arguments): return "Set by launch arguments for this run only."
        case .some(.builtIn): return "This build came with this server's address. Pairing with another one replaces it on this phone."
        default:
            if store.hello?.demo == true { return nil }
            if Connection.current?.isDirect == true { return "Connected to T3 Code itself, with no T3 Bot server. The token is kept in this phone's Keychain; T3 Code lists this phone under Settings > Sharing & access." }
            return "Paired with the link from t3bot pair. The token is kept in this phone's Keychain."
        }
    }

    private func pairAnother() {
        close()
        // The sheet leaves first; the connect screen then takes the place of home.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            store.showConnect = true
        }
    }
}

/// Whether a push can reach this phone: iOS's permission, the phone's registration, the server's key, and a
/// button to try it.
struct SettingsNotificationsSection: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    @State private var permission: UNAuthorizationStatus?
    @State private var testing = false
    @State private var result: (text: String, ok: Bool)?

    var body: some View {
        Section {
            // Not asked yet: the button under it says all there is to say.
            if permission != .notDetermined {
                HStack {
                    // Not "Notifications": the section already has that name. An icon like the row under it.
                    Label("Permission", systemImage: "bell")
                    Spacer()
                    Text(permissionText).foregroundStyle(permission == .denied ? Color.red : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            // One row at a time in this group, so the reads below run once: a modifier on a section would be
            // applied to each of its rows.
            Group {
            if permission == .notDetermined {
                // An icon on each action, so their titles line up with "Send a test push" under them.
                Button {
                    AppDelegate.askForPush()
                    // iOS answers after its own question; read the new state once it is likely closed, and again
                    // whenever the app comes back to the front.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        await readPermission()
                    }
                } label: { Label("Allow notifications", systemImage: "bell") }
            } else {
                Button {
                    if let u = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(u) }
                } label: { Label("Open iOS Settings", systemImage: "gear") }
            }
            }
            .task { await readPermission() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { @MainActor in await readPermission() }
            }
            if Connection.current?.isDirect == true {
                // Paired with T3 Code itself: the phone rings through hooks T3 Bot adds to T3 Code's Claude settings.
                Toggle(isOn: Binding(get: { store.directPushOn }, set: { store.setDirectPush($0) })) {
                    Text("Ring this phone")
                }
                .tint(.green)
                // No push sender in this build: nothing to turn on, and the footer says why.
                .disabled(permission == .denied || DirectPush.host == nil)
                if DirectPush.host != nil, let p = store.directPushProblem {
                    Label(p, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if let error = store.pushError {
                Label(Self.plain(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            // Only where a push can come: never on the demo, never before iOS allows it.
            if store.hello?.demo != true, permission == .authorized || permission == .provisional,
               Connection.current?.isDirect != true || DirectPush.host != nil {
            Button {
                Task { @MainActor in await test() }
            } label: {
                HStack {
                    Label("Send a test push", systemImage: "bell.badge")
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(testing)
            }
            if let result {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(result.ok ? Color.green : Color.red)
            }
        } header: {
            ListHeader(text: "Notifications")
        } footer: {
            Text(footer)
        }
    }

    /// iOS's own words for a build without push ("no valid aps-environment entitlement string found") say
    /// nothing to the person holding the phone; this says what it means.
    static func plain(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("aps-environment") {
            return "This build of T3 Bot cannot receive pushes: it was signed without Apple's push capability."
        }
        return error
    }

    private var permissionText: String {
        switch permission {
        case .authorized: return "Allowed"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Allowed for now"
        case .denied: return "Off in iOS Settings"
        case .notDetermined: return "Not asked yet"
        default: return permission == nil ? "Checking" : "Unknown"
        }
    }

    private var footer: String {
        if Connection.current?.isDirect == true {
            // A build with no T3BOT_PUSH_HOST (a plain clone): notifications are off, and nothing is added to T3 Code.
            if DirectPush.host == nil { return "This build of T3 Bot has no push sender, so T3 Code cannot ring this phone. Deploy one (push/README.md), then run setup.sh --push-host and build again." }
            if permission == .denied { return "Notifications are off for T3 Bot, so nothing can ring. Turn them on in iOS Settings." }
            return store.directPushOn
                ? "Claude threads in T3 Code ring this phone when they ask you something, and bots when they answer. T3 Bot keeps a small hook for that in T3 Code's Claude settings; turning this off takes it out."
                : "Turned on, T3 Bot adds a small hook to T3 Code's Claude settings so Claude threads can ring this phone. Codex and other providers do not ring yet."
        }
        if store.hello?.demo == true { return "The demo server does not send pushes. A real server rings this phone when a bot needs you." }
        if store.hello?.push == false { return "The server has no Apple push key yet, so it cannot ring this phone. Run t3bot doctor on your Mac to see what is missing." }
        if permission == .denied { return "Notifications are off for T3 Bot, so nothing can ring. Turn them on in iOS Settings." }
        if store.pushError == nil && !store.pushRegistered && permission == .authorized {
            return "This phone is not registered with the server yet. It registers by itself once the server can be reached."
        }
        return "The test arrives like a real push, a few seconds after you tap."
    }

    private func readPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func test() async {
        testing = true
        result = nil
        defer { testing = false }
        if Connection.current?.isDirect == true {
            do {
                try await DirectPush.test()
                result = ("Sent. It should arrive in a few seconds.", true)
                Haptics.success()
            } catch {
                result = (store.directPushOn ? error.localizedDescription : "Turn on Ring this phone first.", false)
                Haptics.error()
            }
            return
        }
        do {
            let reply = try await API.post("v1/test-push", ["title": "T3 Bot", "body": "Push works on this phone."])
            if reply.ok == false {
                result = (reply.error ?? "The server could not send it.", false)
                Haptics.error()
            } else if let n = reply.devices, n == 0 {
                result = ("The server knows no phone yet. Allow notifications, wait a moment and try again.", false)
                Haptics.error()
            } else if store.hello?.push == false {
                result = ("The server took it, but it has no Apple push key, so nothing will arrive.", false)
            } else {
                let n = reply.devices ?? 1
                result = ("Sent to \(n) \(n == 1 ? "device" : "devices"). It should arrive in a few seconds.", true)
                Haptics.success()
            }
        } catch {
            result = ("Could not reach the server, so nothing was sent.", false)
            Haptics.error()
        }
    }
}

/// What this app and its server are, and where the project lives.
struct SettingsAboutSection: View {
    @EnvironmentObject var store: Store

    static let repo = URL(string: "https://github.com/Soren-Starck/t3-bot")!

    var body: some View {
        Section {
            LabeledContent("App", value: Self.appVersion)
            LabeledContent("Server", value: store.hello?.version ?? (store.online ? "Unknown" : "Not reachable"))
            Link(destination: Self.repo) {
                HStack {
                    Label("Source and setup guide", systemImage: "chevron.left.forwardslash.chevron.right")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        } header: {
            ListHeader(text: "About")
        } footer: {
            // A credit, not a setting: under the card like the other notes.
            Text("An unofficial app, not affiliated with T3 Code or Ping. Faces: BoopFace by CX ArtLab, MIT license.")
        }
    }

    /// "1.2 (34)": the version and the build of this app.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
