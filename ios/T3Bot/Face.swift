import SwiftUI
import WebKit

/// A bot's face: BoopFace (MIT, CX ArtLab, ios/T3Bot/BoopFace) wearing one of its 188 skins, chosen per bot.
/// `LiveFace` is the animated component; `AvatarView` is the still picture the server renders.

enum FaceState: String {
    case idle, working, watching, waiting, failed, asleep, success, affirm, typing
    // What a working bot is doing right now (server: t3.activity)
    case thinking, reading, running, writing, web, delegating
}

/// The live, animated face. Its state says what the bot is doing:
/// working (eyes bob in a wave, or the animation of what it is doing), watching one of its autopilots run (scans every
/// few seconds), waiting on something important from you (surprise every few seconds),
/// failed (droops), asleep (12 quiet hours, eyes closed), and short reactions: success when an answer lands,
/// a nod when you send, typing cursors while you write.
///
/// Never blank: the saved still picture of the same skin shows at once, and the animated face fades in over it as
/// soon as its web view has drawn (it reports "ready"). Every face shares one copy of the library.
struct LiveFace: View {
    let face: Face
    var size: CGFloat
    var state: FaceState = .idle
    @State private var ready = false

    var body: some View {
        ZStack {
            if !ready {
                StoredImage(key: "skin:\(face.skin)", path: "v1/avatars/skins/\(face.skin).png") {
                    Circle().fill(Color(.secondarySystemFill)).padding(size * 0.12)
                }
                .padding(size * 0.07)
                .transition(.opacity)
            }
            FaceWebView(face: face, size: size, state: state) { withAnimation(.easeOut(duration: 0.25)) { ready = true } }
                .opacity(ready ? 1 : 0.011)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The BoopFace web component in a transparent web view.
struct FaceWebView: UIViewRepresentable {
    let face: Face
    var size: CGFloat
    var state: FaceState
    var onReady: () -> Void

    /// The library, read once and injected into every face (the pages themselves stay tiny).
    static let librarySource: String = Bundle.main.url(forResource: "boopface.iife", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    private static let library = WKUserScript(source: librarySource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(Self.library)
        config.userContentController.add(WeakHandler(context.coordinator), name: "ready")
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: size, height: size), configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        web.navigationDelegate = context.coordinator
        context.coordinator.onReady = onReady
        context.coordinator.html = page()
        context.coordinator.last = state
        context.coordinator.skin = face.skin
        web.loadHTMLString(context.coordinator.html, baseURL: nil)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        if context.coordinator.skin != face.skin {
            context.coordinator.skin = face.skin
            web.evaluateJavaScript("window.t3botSkin && window.t3botSkin('\(face.skin)')")
        }
        guard context.coordinator.last != state else { return }
        context.coordinator.last = state
        web.evaluateJavaScript("window.t3botState && window.t3botState('\(state.rawValue)')")
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "ready")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var last: FaceState?
        var skin: String?
        var html = ""
        var onReady: () -> Void = {}

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async { self.onReady() }
        }

        /// Belt and braces: if the injected library did not run in this page, evaluate it directly; and if the page
        /// never says it is ready, show it anyway after a moment rather than keep the still forever.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("!!(window.customElements && customElements.get('boop-face'))") { defined, _ in
                if (defined as? Bool) != true { webView.evaluateJavaScript(FaceWebView.librarySource) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.onReady() }
        }

        /// iOS can kill a web view's process while the app sleeps; the face would come back blank. Reload it.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.loadHTMLString(html, baseURL: nil)
            let state = last
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let state { webView.evaluateJavaScript("window.t3botState && window.t3botState('\(state.rawValue)')") }
            }
        }
    }

    /// The content controller keeps its handler strongly; this breaks the cycle with the coordinator.
    final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ t: WKScriptMessageHandler) { target = t }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }

    private func page() -> String {
        let px = Int(size)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=\(px),initial-scale=1,user-scalable=no">
        <style>html,body{margin:0;background:transparent;overflow:hidden}
        body{display:flex;align-items:center;justify-content:center;width:\(px)px;height:\(px)px}</style></head><body>
        <boop-face id="f" size="\(Int(size * 0.86))" skin="\(face.skin)" auto-sleep="0" wake-on="manual" press-squeeze="false" antenna-drag="false"></boop-face>
        <script>
        (function boot() {
          const f = document.getElementById('f');
          if (!customElements.get('boop-face')) { return setTimeout(boot, 30); }
          f.setPointerFollow && f.setPointerFollow(false);
          let loop = null, cur = null;
          const quiet = () => {
            clearInterval(loop); loop = null;
            try { f.stopWaiting(); } catch (e) {}
            try { f.input(false); } catch (e) {}
          };
          window.t3botSkin = (n) => { try { f.setSkin(n); } catch (e) {} };
          window.t3botState = async (s) => {
            if (s === cur) return;
            const was = cur; cur = s; quiet();
            if (was === 'asleep') { try { await f.wake(); } catch (e) {} }
            switch (s) {
              case 'working': case 'thinking': f.startWaiting({ variant: 'wave' }); break;
              case 'reading': f.play('inspect'); loop = setInterval(() => f.play('inspect'), 3200); break;
              case 'running': f.startWaiting({ variant: 'spin' }); break;
              case 'writing': f.input(true); break;
              case 'web': f.startWaiting({ variant: 'wrap' }); break;
              case 'delegating': f.play('affirm'); loop = setInterval(() => f.play('affirm'), 2400); break;
              case 'watching': f.play('inspect'); loop = setInterval(() => f.play('inspect'), 5000); break;
              // Waiting on something important from you: wide-open eyes every few seconds.
              case 'waiting': f.play('surprise'); loop = setInterval(() => f.play('surprise'), 5000); break;
              case 'failed': f.play('failure'); loop = setInterval(() => f.play('failure'), 20000); break;
              case 'asleep': f.sleep(); break;
              case 'success': f.play('success'); break;
              case 'affirm': f.play('affirm'); break;
              case 'typing': f.input(true); break;
              default: f.reset();
            }
          };
          t3botState('\(state.rawValue)');
          // Drawn: let the still picture underneath go (after two frames, or a short timer if frames are throttled).
          let told = false;
          const tell = () => { if (told) return; told = true; try { window.webkit.messageHandlers.ready.postMessage(1); } catch (e) {} };
          requestAnimationFrame(() => requestAnimationFrame(tell));
          setTimeout(tell, 250);
        })();
        </script></body></html>
        """
    }
}

/// The still face from the server (rendered by tools/faces/render.ts), with a dot while the bot works.
struct AvatarView: View {
    let agent: String
    var size: CGFloat = 40
    var status: String? = nil
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if let a = store.agent(agent), a.kind == "group", !a.members.isEmpty {
                GroupFace(members: Array(a.members.prefix(3)), size: size)
            } else {
                StoredImage(key: Self.avatarKey(agent), path: Self.avatarPath(agent)) {
                    InitialFace(name: store.agent(agent)?.name ?? agent, color: store.agent(agent)?.color, size: size)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if status == "working" {
                Circle().fill(Color.blue)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            } else if status == "waiting" {
                Circle().fill(Color.orange)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
        }
    }
}

extension AvatarView {
    /// The server's avatar path carries a version (?v=), so a new skin is a new cache entry.
    static func avatarPath(_ agent: String) -> String {
        Store.cache.withLock { $0[agent] }?.avatar.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "v1/avatars/\(agent).png"
    }
    static func avatarKey(_ agent: String) -> String { "face:" + avatarPath(agent) }
}

/// A bot the server has no picture of (or whose picture has not arrived yet): its initial on its color.
/// The widgets, the notifications and the share sheet draw the same thing, so no build carries any bot's picture.
struct InitialFace: View {
    let name: String
    var color: String? = nil
    let size: CGFloat

    var body: some View {
        let tint = Self.tint(color)
        Circle().fill(tint.color)
            .padding(size * 0.08)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint.light ? Color.black.opacity(0.75) : Color.white)
            )
            .accessibilityHidden(true)
    }

    /// "#RRGGBB" as a color, and whether it is light enough to need dark lettering. Gray when there is none.
    static func tint(_ hex: String?) -> (color: Color, light: Bool) {
        let digits = (hex ?? "").filter { $0.isHexDigit }
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return (Color(white: 0.55), false) }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        return (Color(red: r, green: g, blue: b), 0.299 * r + 0.587 * g + 0.114 * b > 0.7)
    }
}

/// Up to three member faces, overlapped, for a group chat.
struct GroupFace: View {
    let members: [String]
    let size: CGFloat
    @EnvironmentObject var store: Store

    var body: some View {
        let s = size * 0.62
        ZStack {
            ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                StoredImage(key: AvatarView.avatarKey(m), path: AvatarView.avatarPath(m)) {
                    InitialFace(name: store.agent(m)?.name ?? m, color: store.agent(m)?.color, size: s)
                }
                .frame(width: s, height: s)
                .offset(x: CGFloat(i - (members.count - 1) / 2) * s * 0.5 - (members.count == 2 ? s * 0.25 : 0),
                        y: i % 2 == 0 ? -s * 0.12 : s * 0.12)
            }
        }
        .frame(width: size, height: size)
    }
}

extension Agent {
    /// Sleeping when idle; while working, the animation of what it is doing (reading, running, writing...).
    var faceState: FaceState {
        if mood == "working" || mood == "watching", let a = activity, a != "asking", let s = FaceState(rawValue: a) { return s }
        if activity == "asking" { return .waiting }
        return FaceState(rawValue: mood ?? "") ?? (status == "working" ? .working : status == "waiting" ? .waiting : .asleep)
    }

    /// The same in words, for the row under its name.
    var activityText: String? {
        guard mood == "working" || mood == "watching" else { return nil }
        switch activity {
        case "reading": return "Reading"
        case "running": return "Running a command"
        case "writing": return "Writing"
        case "web": return "On the web"
        case "delegating": return "Asking another agent"
        case "asking": return "Waiting for your answer"
        default: return "Thinking"
        }
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var hex: String {
        let c = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(round(max(0, min(1, r)) * 255)), Int(round(max(0, min(1, g)) * 255)), Int(round(max(0, min(1, b)) * 255)))
    }
}
