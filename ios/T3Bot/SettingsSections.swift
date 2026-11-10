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
            LabeledContent("Address", value: Connection.current?.label ?? "None")
            if let hello = store.hello {
                LabeledContent("Server", value: serverLine(hello))
            }
            HStack {
                Label(status.text, systemImage: status.symbol).foregroundStyle(status.color)
                Spacer()
                if checking {
                    ProgressView().controlSize(.small)
                } else if store.online, let at = store.lastSync {
                    // "Updated just now", not a bare counter that ticks every second.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.updated(at, now: context.date)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let problem = t3Problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
            Button { pairAnother() } label: { Label("Pair another server", systemImage: "qrcode.viewfinder") }
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
                Text("This phone forgets the server, its chats and its token. Your bots and their work stay on the server. Pair again any time with t3bot pair.")
            }
        } header: {
            // Not "Server": a row under it has that name.
            Text("Connection")
        } footer: {
            Text(footer)
        }
    }

    /// "Updated just now", "Updated 5m ago": when the server last answered.
    static func updated(_ at: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(at)))
        if s < 60 { return "Updated just now" }
        if s < 3600 { return "Updated \(s / 60)m ago" }
        return "Updated \(s / 3600)h ago"
    }

    private var status: (text: String, symbol: String, color: Color) {
        if store.refused { return ("Token refused", "lock.slash", .red) }
        if store.online { return ("Connected", "checkmark.circle.fill", .green) }
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

    private var footer: String {
        if store.refused { return "The server answered but refused this phone's token. Pair again with the link or the QR code from t3bot pair." }
        switch Connection.source {
        case .some(.arguments): return "Set by launch arguments for this run only."
        case .some(.builtIn): return "This build came with this server's address. Pairing with another one replaces it on this phone."
        default:
            if store.hello?.demo == true { return "This is the demo server: made-up bots that answer by themselves, nothing real behind them." }
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
            HStack {
                // Not "Notifications": the section already has that name.
                Text("Permission")
                Spacer()
                Text(permissionText).foregroundStyle(permission == .denied ? Color.red : Color.secondary)
            }
            .accessibilityElement(children: .combine)
            // On this row, not the section: a modifier on a section is applied to each of its rows.
            .task { await readPermission() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { @MainActor in await readPermission() }
            }
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
            if let error = store.pushError {
                Label(Self.plain(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
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
            if let result {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(result.ok ? Color.green : Color.red)
            }
        } header: {
            Text("Notifications")
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
            Text("About")
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
