import SwiftUI
import UIKit

/// First run, and "Connect to another" from Settings: where the phone learns where its bots are.
/// T3 Code itself (its pairing QR code or link, or its address and a code) or a T3 Bot server (`t3bot pair`).
/// A pairing link opened from outside the app (t3bot://connect?...) lands here too.
/// Nothing is saved until the other side has taken the code or token.
struct ConnectView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL

    enum Phase: Equatable {
        case idle
        case checking(PairTarget)
        case failed(title: String, advice: String)
        /// Already paired with another: ask before this one replaces it.
        case confirm(PairTarget)

        var isIdle: Bool { if case .idle = self { return true } else { return false } }
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
    @State private var last: PairTarget?
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
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            // The whole screen centred, so the buttons sit nearer the thumb and no third of it is empty.
            .defaultScrollAnchor(.center, for: .alignment)
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
        // VoiceOver hears why pairing failed: the message appears under the buttons, away from the finger.
        .onChange(of: phase) { _, p in
            guard UIAccessibility.isVoiceOverRunning, case let .failed(title, advice) = p else { return }
            AccessibilityNotification.Announcement("\(title). \(advice)").post()
        }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 14) {
            if store.paired {
                ConnectFace(state: faceState)
            } else {
                // First run: a few of the bots this app is made of, before anything is asked.
                FaceCrowd(state: faceState)
                    .padding(.bottom, 4)
            }
            Text(store.paired ? "Connect to another" : "T3 Bot")
                .font(store.paired ? .title2.weight(.bold) : .system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Group {
                if store.paired {
                    Text("This phone stays connected to \(Connection.current?.label.unbroken ?? "it") until another one answers.")
                } else {
                    Text("Your T3 Code agents as a team you text. They ask, you answer, from anywhere.")
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the code comes from, said once under the buttons.
    private var whereFrom: some View {
        Text("On your Mac, in T3 Code: Settings > Sharing & access > Create link, then scan its code.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                field = nil
                scanning = true
            } label: {
                Label("Scan the code from T3 Code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(ConnectButtonStyle())

            // One quiet way to the others (paste a link, type the address and code), not two more buttons.
            if !manual {
                Menu {
                    Button { paste() } label: { Label("Paste link", systemImage: "doc.on.clipboard") }
                    Button {
                        withAnimation(.spring(duration: 0.3)) { manual = true }
                        field = .address
                    } label: { Label("Enter code", systemImage: "keyboard") }
                } label: {
                    Label("Other ways to connect", systemImage: "ellipsis.circle")
                }
                // A real secondary button (as plain text it read as a caption).
                .buttonStyle(ConnectButtonStyle(filled: false))
            }
            if !store.paired { whereFrom.padding(.top, 4) }

            // After Disconnect on a build that carries its own server: one tap brings it back.
            if !store.paired, let own = Connection.builtIn {
                Button { arrived(.server(own), asked: true) } label: {
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
                    Text("Address").font(.caption).foregroundStyle(.secondary)
                    TextField("Address", text: $address, prompt: Text("Your T3 Connect or Tailscale address"))
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
                    Text("Code").font(.caption).foregroundStyle(.secondary)
                    SecureField("Code", text: $token, prompt: Text("The code from Create link"))
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
                Text("Connecting to \(c.label.unbroken)").foregroundStyle(.secondary)
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

    private func confirmBlock(_ c: PairTarget) -> some View {
        let old = Connection.current?.label.unbroken ?? "the current one"
        return VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Connect to \(c.label.unbroken)?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("This phone is connected to \(old). Switching forgets what it keeps here from it: saved chats, drafts and anything not sent yet. Nothing changes on your Mac.")
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
                    Text("Just looking? Try the demo").foregroundStyle(.primary).fontWeight(.semibold)
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
                    // How it works, in full: with the demo, not as a fourth choice on the first screen.
                    footer
                    #if targetEnvironment(simulator)
                    Button("Connect to the demo on this Mac") {
                        if let c = Connection.make("http://127.0.0.1:8810", "demo") { arrived(.server(c), asked: true) }
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

    private var howItWorks: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array([("bubble.left.and.exclamationmark.bubble.right", "A bot asks"),
                           ("iphone.radiowaves.left.and.right", "This phone rings"),
                           ("hand.tap", "You answer in a tap")].enumerated()), id: \.offset) { _, s in
                VStack(spacing: 6) {
                    Image(systemName: s.0).font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                        .frame(height: 24)
                    Text(s.1).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        Button { openURL(Self.repo) } label: {
            Label("How T3 Bot works", systemImage: "arrow.up.right")
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
        // Awake and friendly on the first screen (asleep, it read as bored).
        case .idle: return .idle
        case .checking: return .thinking
        case .failed: return .failed
        case .confirm: return .waiting
        }
    }

    /// A pairing link opened from outside the app.
    private func take(_ c: Connection?) {
        guard let c else { return }
        store.pendingPairing = nil
        arrived(.server(c), asked: false)
    }

    /// A pairing to check. `asked` is true when the person chose it on this screen; a link from outside is
    /// confirmed first when it would replace the server the phone is paired with.
    private func arrived(_ c: PairTarget, asked: Bool) {
        if !asked, store.paired, let now = Connection.current, now.url != c.base {
            check?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { phase = .confirm(c) }
        } else {
            verify(c)
        }
    }

    private func verify(_ c: PairTarget) {
        check?.cancel()
        field = nil
        last = c
        withAnimation(.easeInOut(duration: 0.2)) { phase = .checking(c) }
        check = Task {
            do {
                let (connection, hello) = try await c.pair()
                guard !Task.isCancelled else { return }
                Haptics.success()
                store.connect(connection, hello: hello)
            } catch {
                guard !Task.isCancelled else { return }
                let (title, advice): (String, String)
                if let e = error as? PairingError { (title, advice) = (e.title, e.advice) }
                else if let e = error as? T3PairingError { (title, advice) = (e.title, e.advice) }
                else { (title, advice) = (PairingError.unreachable(error.localizedDescription).title, error.localizedDescription) }
                Haptics.error()
                // Kept in the form, so one wrong character can be fixed by hand. A T3 Code code works once, so it
                // is not kept: a new one is needed anyway.
                address = c.base.absoluteString
                if case let .server(s) = c { token = s.token } else { token = "" }
                // A used code cannot be tried again; the button only shows when trying again can work.
                if case .t3code = c, (error as? T3PairingError) == .codeRefused { last = nil }
                withAnimation(.easeInOut(duration: 0.2)) { phase = .failed(title: title, advice: advice) }
            }
        }
    }

    private func connectTyped() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard T3Link.baseURL(address) != nil || Connection.normalized(address) != nil else { return fail(.badAddress) }
        guard !t.isEmpty else {
            return fail(title: "The code is missing", advice: "In T3 Code, open Settings > Sharing & access, create a link and copy its code.")
        }
        let typedAddress = address
        withAnimation(.easeInOut(duration: 0.2)) { phase = .idle }
        Task {
            guard let target = await PairTarget.typed(address: typedAddress, secret: t) else { return fail(.badAddress) }
            arrived(target, asked: true)
        }
    }

    private func paste() {
        Haptics.tap()
        field = nil
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return fail(title: "Nothing to paste", advice: "Copy the link T3 Code gives under Settings > Sharing & access, then tap Paste link again.")
        }
        if let c = PairTarget.from(text) { return arrived(c, asked: true) }
        // An address alone (T3 Code's "Copy MCP URL" gives one): it goes into the form, where the code is still needed.
        if !text.contains("\n"), text.count < 300, let u = T3Link.baseURL(text) {
            address = u.absoluteString
            withAnimation(.spring(duration: 0.3)) { manual = true; phase = .idle }
            field = .token
            return
        }
        fail(title: "That is not a pairing link", advice: "Copy the link T3 Code gives under Settings > Sharing & access, or type its address and code.")
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
        let sample = Connection.make("https://my-mac.example.ts.net:8809", "sample-token").map { PairTarget.server($0) }
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
            address = "https://prod-1234.t3coderelay.com"
            token = "sample-code"
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
    var skin = "101"
    @State private var ready = false

    var body: some View {
        ZStack {
            if !ready {
                // The still picture ships with the app: never an empty circle while the live face loads.
                StoredImage(key: "skin:\(skin)", path: "skin:\(skin)") { Color.clear }
                    .padding(size * 0.07)
                    .transition(.opacity)
            }
            FaceWebView(face: Face(skin: skin), size: size, state: state) {
                withAnimation(.easeOut(duration: 0.25)) { ready = true }
            }
            .opacity(ready ? 1 : 0.011)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A few bots, gently floating: the first thing a new install shows, before it asks for anything. Their still
/// pictures ship with the app, so they are there at once; the one in the middle is alive.
struct FaceCrowd: View {
    var state: FaceState = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Spot { let skin: String; let size: CGFloat; let x: CGFloat; let y: CGFloat; let tilt: Double; let delay: Double }
    private let spots = [
        Spot(skin: "102", size: 58, x: -118, y: -18, tilt: -10, delay: 0.0),
        Spot(skin: "305", size: 46, x: 112, y: -44, tilt: 12, delay: 0.7),
        Spot(skin: "103", size: 52, x: 128, y: 40, tilt: -6, delay: 1.3),
        Spot(skin: "304", size: 42, x: -96, y: 56, tilt: 8, delay: 0.4),
    ]

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { t in
            let time = t.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(spots.enumerated()), id: \.offset) { _, s in
                    StoredImage(key: "skin:\(s.skin)", path: "skin:\(s.skin)") { Color.clear }
                        .frame(width: s.size, height: s.size)
                        .rotationEffect(.degrees(s.tilt))
                        .offset(x: s.x, y: s.y + (reduceMotion ? 0 : sin(time * 1.1 + s.delay * 2) * 5))
                }
                ConnectFace(state: state, size: 104, skin: "902")
                    .offset(y: reduceMotion ? 0 : sin(time * 0.9) * 3)
            }
        }
        .frame(height: 170)
        .accessibilityHidden(true)
    }
}
