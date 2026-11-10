import SwiftUI
import UIKit

/// First run, and "Pair another server" from Settings: where the phone learns its T3 Bot server.
/// Three ways in: scan the QR code `t3bot pair` shows, paste its link, or type the address and the token.
/// A pairing link opened from outside the app (t3bot://connect?...) lands here too.
/// Nothing is saved until the server has answered `/v1/hello` with this token.
struct ConnectView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL

    enum Phase: Equatable {
        case idle
        case checking(Connection)
        case failed(title: String, advice: String)
        /// Already paired with another server: ask before this one replaces it.
        case confirm(Connection)
    }

    enum Field { case address, token }

    static let repo = URL(string: "https://github.com/Soren-Starck/t3-bot")!

    @State private var phase: Phase = .idle
    @State private var manual = false
    @State private var address = ""
    @State private var token = ""
    @State private var scanning = false
    @State private var demo = false
    /// The pairing checked last, so "Try again" does not need a second scan.
    @State private var last: Connection?
    @State private var check: Task<Void, Never>?
    @FocusState private var field: Field?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if case let .confirm(c) = phase {
                        confirmBlock(c)
                    } else {
                        actions
                        if manual { form.transition(.opacity.combined(with: .move(edge: .top))) }
                        status
                        demoBlock
                    }
                    footer
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.paired {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { cancel() } }
                }
            }
        }
        .sheet(isPresented: $scanning) {
            ConnectScanner { c in
                scanning = false
                arrived(c, asked: true)
            }
        }
        .onAppear {
            take(store.pendingPairing)
            #if DEBUG
            debug(store.debugConnect)
            #endif
        }
        .onChange(of: store.pendingPairing) { _, c in take(c) }
        #if DEBUG
        .onChange(of: store.debugConnect) { _, w in debug(w) }
        #endif
        .onDisappear { check?.cancel() }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 12) {
            ConnectFace(state: faceState)
            Text(store.paired ? "Pair another server" : "Connect T3 Bot")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Group {
                if store.paired {
                    Text("This phone stays connected to \(Connection.current?.label.unbroken ?? "its server") until another one answers.")
                } else {
                    Text("T3 Bot talks to a small server that runs beside T3 Code on your Mac. Run `t3bot pair` there, then scan the code it shows.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                field = nil
                scanning = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(ConnectButtonStyle())

            Button { paste() } label: {
                Label("Paste pairing link", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(ConnectButtonStyle(filled: false))

            if !manual {
                Button {
                    withAnimation(.spring(duration: 0.3)) { manual = true }
                    field = .address
                } label: {
                    Label("Enter address and token", systemImage: "keyboard")
                }
                .buttonStyle(ConnectButtonStyle(filled: false))
            }

            // After Disconnect on a build that carries its own server: one tap brings it back.
            if !store.paired, let own = Connection.builtIn {
                Button { arrived(own, asked: true) } label: {
                    Label("Use \(own.label.unbroken)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(ConnectButtonStyle(filled: false))
            }
        }
        .disabled(isChecking)
    }

    private var form: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server address").font(.caption).foregroundStyle(.secondary)
                    TextField("Server address", text: $address, prompt: Text("https://my-mac.example.ts.net:8809"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($field, equals: .address)
                        .onSubmit { field = .token }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider().padding(.leading, 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token").font(.caption).foregroundStyle(.secondary)
                    SecureField("Token", text: $token, prompt: Text("The token t3bot pair prints"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($field, equals: .token)
                        .onSubmit { connectTyped() }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))

            Button { connectTyped() } label: { Text("Connect") }
                .buttonStyle(ConnectButtonStyle())
                .disabled(isChecking || address.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case let .checking(c):
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking \(c.label.unbroken)").foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        case let .failed(title, advice):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                // Host names in the advice stay in one piece too.
                Text(advice.unbroken)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last {
                    // A real button in the app's own black and white: a bare blue word was a small target.
                    Button("Try again") { verify(last) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Color.primary)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    private func confirmBlock(_ c: Connection) -> some View {
        let old = Connection.current?.label.unbroken ?? "the current server"
        return VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Connect to \(c.label.unbroken)?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("This phone is connected to \(old). Switching forgets what it keeps here from that server: saved chats, drafts and anything not sent yet. Nothing changes on either server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            Button { verify(c) } label: { Text("Connect") }
                .buttonStyle(ConnectButtonStyle())
            Button { cancel() } label: { Text("Keep \(old)") }
                .buttonStyle(ConnectButtonStyle(filled: false))
        }
    }

    /// No server yet: what the demo is and how to start it.
    private var demoBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) { demo.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                    Text("No server yet? Try the demo").foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(demo ? 90 : 0))
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(demo ? "Hides the steps" : "Shows the steps")

            if demo {
                Divider().padding(.leading, 16)
                VStack(alignment: .leading, spacing: 10) {
                    Text("The demo is a pretend server with made-up bots that answer everything. It needs no T3 Code and changes nothing on your Mac.")
                    // Hyphens that do not break and a joiner after each slash: the address stays in one piece.
                    step(1, Text("Get T3 Bot on your Mac from github.com/\u{2060}Soren\u{2011}Starck/\u{2060}t3\u{2011}bot."))
                    step(2, Text("In its folder, run `t3bot demo` (or `bun server/demo.ts`)."))
                    step(3, Text("Pair with what it prints: scan the QR code, paste the link, or type the address with the token `demo`."))
                    Text("The phone and the Mac must be on the same Wi-Fi, or on the same Tailscale network.")
                    #if targetEnvironment(simulator)
                    Button("Connect to the demo on this Mac") {
                        if let c = Connection.make("http://127.0.0.1:8810", "demo") { arrived(c, asked: true) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .disabled(isChecking)
                    #endif
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func step(_ n: Int, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 16)
            text
        }
    }

    private var footer: some View {
        Button { openURL(Self.repo) } label: {
            Label("How to set up the server", systemImage: "arrow.up.right")
                .labelStyle(.titleAndIcon)
                .font(.footnote.weight(.medium))
                // A full-height target around a small line of text.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - What happens

    private var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    /// The face follows the pairing: asleep until something happens, thinking while the server is asked,
    /// drooping when it failed.
    private var faceState: FaceState {
        switch phase {
        case .idle: return scanning || manual ? .idle : .asleep
        case .checking: return .thinking
        case .failed: return .failed
        case .confirm: return .waiting
        }
    }

    /// A pairing link opened from outside the app.
    private func take(_ c: Connection?) {
        guard let c else { return }
        store.pendingPairing = nil
        arrived(c, asked: false)
    }

    /// A pairing to check. `asked` is true when the person chose it on this screen; a link from outside is
    /// confirmed first when it would replace the server the phone is paired with.
    private func arrived(_ c: Connection, asked: Bool) {
        if !asked, store.paired, let now = Connection.current, now.url != c.url {
            check?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { phase = .confirm(c) }
        } else {
            verify(c)
        }
    }

    private func verify(_ c: Connection) {
        check?.cancel()
        field = nil
        last = c
        withAnimation(.easeInOut(duration: 0.2)) { phase = .checking(c) }
        check = Task {
            do {
                let h = try await API.hello(c)
                guard !Task.isCancelled else { return }
                Haptics.success()
                store.connect(c, hello: h)
            } catch {
                guard !Task.isCancelled else { return }
                let e = (error as? PairingError) ?? .unreachable(error.localizedDescription)
                Haptics.error()
                // Kept in the form, so one wrong character can be fixed by hand.
                address = c.url.absoluteString
                token = c.token
                withAnimation(.easeInOut(duration: 0.2)) { phase = .failed(title: e.title, advice: e.advice) }
            }
        }
    }

    private func connectTyped() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Connection.normalized(address) != nil else { return fail(.badAddress) }
        guard !t.isEmpty, let c = Connection.make(address, t) else {
            return fail(title: "The token is missing", advice: "Run t3bot pair on your Mac: it prints the token with the address.")
        }
        arrived(c, asked: true)
    }

    private func paste() {
        Haptics.tap()
        field = nil
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return fail(title: "Nothing to paste", advice: "Copy the link t3bot pair prints (it starts with t3bot://connect), then tap Paste pairing link again.")
        }
        if let c = Connection.parse(link: text) { return arrived(c, asked: true) }
        // An address alone: it goes into the form, where the token is still needed.
        if !text.contains("\n"), text.count < 200, let u = Connection.normalized(text) {
            address = u.absoluteString
            withAnimation(.spring(duration: 0.3)) { manual = true; phase = .idle }
            field = .token
            return
        }
        fail(title: "That is not a pairing link", advice: "A pairing link starts with t3bot://connect and carries the address and the token. Run t3bot pair on your Mac and copy the link it prints.")
    }

    private func fail(_ e: PairingError) { fail(title: e.title, advice: e.advice) }

    private func fail(title: String, advice: String) {
        Haptics.error()
        last = nil
        withAnimation(.easeInOut(duration: 0.2)) { phase = .failed(title: title, advice: advice) }
    }

    private func cancel() {
        check?.cancel()
        field = nil
        store.pendingPairing = nil
        #if DEBUG
        store.debugConnect = nil
        #endif
        store.showConnect = false
    }

    #if DEBUG
    /// Screen checks (t3bot://debug/connect/<state>): each state of this screen without a camera or a server.
    private func debug(_ what: String?) {
        guard let what else { return }
        let sample = Connection.make("https://my-mac.example.ts.net:8809", "sample-token")
        check?.cancel()
        manual = false
        demo = false
        last = sample
        address = ""
        token = ""
        switch what {
        case "first": phase = .idle; last = nil
        case "scan": phase = .idle; scanning = true
        case "manual":
            manual = true
            address = "https://my-mac.example.ts.net:8809"
            token = "sample-token"
            phase = .idle
        case "demo": demo = true; phase = .idle
        case "checking": if let sample { phase = .checking(sample) }
        case "unreachable":
            let e = PairingError.unreachable("my-mac.example.ts.net did not answer. Check that the server is running and that this phone is on the same network or VPN as your Mac.")
            phase = .failed(title: e.title, advice: e.advice)
        case "token": phase = .failed(title: PairingError.wrongToken.title, advice: PairingError.wrongToken.advice)
        case "notserver": phase = .failed(title: PairingError.notT3Bot.title, advice: PairingError.notT3Bot.advice)
        case "address":
            manual = true
            address = "my mac"
            last = nil
            phase = .failed(title: PairingError.badAddress.title, advice: PairingError.badAddress.advice)
        case "confirm": if let sample { phase = .confirm(sample) }
        default: phase = .idle
        }
    }
    #endif
}

extension String {
    /// A host name that stays in one piece: with plain hyphens, "my-mac.example.ts.net" was cut after "my-".
    var unbroken: String { replacingOccurrences(of: "-", with: "\u{2011}") }
}

/// The connect screen's buttons: one filled, the others quiet, all the same height.
struct ConnectButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, filled: filled)
    }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        let filled: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(filled ? Color(.systemBackground) : Color.primary)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? Color.primary : Color(.secondarySystemGroupedBackground)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// A BoopFace on the connect screen. It draws from the library bundled in the app, so it needs no server.
struct ConnectFace: View {
    var state: FaceState
    var size: CGFloat = 96
    @State private var ready = false

    var body: some View {
        ZStack {
            if !ready {
                Circle().fill(Color(.secondarySystemFill)).padding(size * 0.14).transition(.opacity)
            }
            FaceWebView(face: Face(skin: "101"), size: size, state: state) {
                withAnimation(.easeOut(duration: 0.25)) { ready = true }
            }
            .opacity(ready ? 1 : 0.011)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
