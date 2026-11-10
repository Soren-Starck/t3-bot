import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// T3 Bot in the share sheet: send a link, text or images from any app to one of your bots, with a note.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    struct Bot: Decodable, Identifiable {
        let id: String
        let name: String
        var kind: String? = nil
        var hidden: Bool? = nil
        /// The bot's color (hex) and the path of its face on the server.
        var color: String? = nil
        var avatar: String? = nil
    }

    /// Where the list of bots stands.
    enum Phase: Equatable { case loading, ready, notPaired, refused, unreachable, noBots }

    let context: NSExtensionContext?
    @Published var phase: Phase = .loading
    @Published var bots: [Bot] = []
    /// The bot that gets what is shared. Empty until the server has said which bots exist.
    @Published var bot = ""
    @Published var note = ""
    @Published var url: String?
    @Published var text: String?
    @Published var images: [Data] = []
    @Published var sending = false
    @Published var error: String?

    init(context: NSExtensionContext?) { self.context = context }

    var canSend: Bool { phase == .ready && !bot.isEmpty && !sending }

    func load() async {
        for item in (context?.inputItems as? [NSExtensionItem]) ?? [] {
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    url = u.absoluteString
                } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier) {
                        let img = (data as? UIImage) ?? (data as? URL).flatMap { UIImage(contentsOfFile: $0.path) } ?? (data as? Data).flatMap(UIImage.init(data:))
                        if let jpg = img?.uploadJPEG(), images.count < 4 { images.append(jpg) }
                    }
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text = t
                }
            }
        }
        await loadBots()
    }

    /// Asks the server which bots exist and which one leads. The connection is read fresh, so a pairing made
    /// in the app a moment ago is the one used.
    func loadBots() async {
        phase = .loading
        guard let r = Connection.load()?.request("v1/home", timeout: 10) else {
            phase = .notPaired
            return
        }
        struct H: Decodable {
            let agents: [Bot]
            var chief: String? = nil
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: r) else {
            phase = .unreachable
            return
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            phase = .refused
            return
        }
        guard code == 200, let h = try? JSONDecoder().decode(H.self, from: data) else {
            phase = .unreachable
            return
        }
        bots = h.agents.filter { $0.hidden != true }
        if bots.isEmpty {
            phase = .noBots
            return
        }
        // The bot the server names as its chief, else the one called "chief", else the first bot.
        let ids = bots.map(\.id)
        if !ids.contains(bot) {
            if let chief = h.chief, ids.contains(chief) {
                bot = chief
            } else if ids.contains("chief") {
                bot = "chief"
            } else {
                bot = (bots.first(where: { $0.kind != "group" }) ?? bots[0]).id
            }
        }
        phase = .ready
    }

    func send() {
        guard canSend else { return }
        sending = true
        error = nil
        var body: [String: Any] = ["agent": bot, "note": note]
        if let url { body["url"] = url }
        if let text { body["text"] = text }
        if !images.isEmpty { body["images"] = images.map { $0.base64EncodedString() } }
        Task {
            do {
                guard var r = Connection.load()?.request("v1/share", timeout: 30) else { throw URLError(.badURL) }
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, resp) = try await URLSession.shared.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 {
                    self.error = "The server refused this phone's token. Open T3 Bot and pair it again."
                    sending = false
                } else if code != 200 {
                    self.error = "The server could not take it (error \(code)). Nothing was sent."
                    sending = false
                } else {
                    context?.completeRequest(returningItems: nil)
                }
            } catch {
                self.error = "Could not reach your T3 Bot server, so nothing was sent. Check that this phone can reach it, then try again."
                sending = false
            }
        }
    }

    func cancel() { context?.cancelRequest(withError: NSError(domain: "T3Bot", code: 0)) }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Send to") { target }
                Section("What you share") {
                    if let url = model.url { Label(url, systemImage: "link").lineLimit(2) }
                    if let text = model.text { Text(text).lineLimit(4).font(.subheadline) }
                    if !model.images.isEmpty { Label("\(model.images.count) image\(model.images.count == 1 ? "" : "s")", systemImage: "photo") }
                    TextField("Add a note (optional)", text: $model.note, axis: .vertical).lineLimit(1...4)
                }
                if let e = model.error { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("T3 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.sending ? "Sending" : "Send") { model.send() }.disabled(!model.canSend)
                }
            }
        }
    }

    /// The bots to choose from, or why there are none to show.
    @ViewBuilder private var target: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading your bots").foregroundStyle(.secondary)
            }
        case .ready:
            picker
        case .notPaired:
            Text("This phone is not paired with a T3 Bot server yet. Open T3 Bot, pair it, then share again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .refused:
            Text("The server refused this phone's token. Open T3 Bot and pair it again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .unreachable:
            Text("Could not reach your T3 Bot server. Check that this phone can reach it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try again") { Task { await model.loadBots() } }
        case .noBots:
            Text("The server has no bot yet. Open T3 Bot and create one first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(model.bots) { b in
                    Button { model.bot = b.id } label: {
                        VStack(spacing: 4) {
                            ShareFace(bot: b)
                                .frame(width: 48, height: 48)
                                .padding(3)
                                .background(Circle().stroke(model.bot == b.id ? Color.primary : Color.clear, lineWidth: 2))
                            Text(b.name).font(.caption2).lineLimit(1).foregroundStyle(model.bot == b.id ? Color.primary : Color.secondary)
                        }
                        .frame(width: 64)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(b.name)
                    .accessibilityAddTraits(model.bot == b.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A bot's face in the picker: its picture from the server, and until that has loaded (or when there is
/// none) the copy the app mirrored for its extensions, else the bot's initial on its color. No build carries
/// any bot's picture.
struct ShareFace: View {
    let bot: ShareModel.Bot

    var body: some View {
        AsyncImage(url: remote) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                fallback
            }
        }
    }

    private var remote: URL? {
        let path = bot.avatar ?? "v1/avatars/\(bot.id).png"
        return Connection.load()?.endpoint(path)
    }

    @ViewBuilder private var fallback: some View {
        if let data = SharedFaces.picture(bot.id), let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            let tint = ShareFace.tint(bot.color ?? SharedFaces.color(bot.id))
            GeometryReader { geo in
                Circle().fill(tint.color)
                    .overlay(
                        Text(String(bot.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                            .font(.system(size: geo.size.width * 0.46, weight: .semibold, design: .rounded))
                            .foregroundStyle(tint.light ? Color.black.opacity(0.75) : Color.white)
                    )
            }
        }
    }

    /// "#RRGGBB" as a color, and whether it is light enough to need dark lettering. Gray when there is none.
    static func tint(_ hex: String?) -> (color: Color, light: Bool) {
        let digits = (hex ?? "").filter { $0.isHexDigit }
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return (Color(white: 0.55), false) }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        return (Color(red: r, green: g, blue: b), 0.299 * r + 0.587 * g + 0.114 * b > 0.7)
    }
}

extension UIImage {
    func uploadJPEG() -> Data? {
        let longest = max(size.width, size.height)
        let k = longest > 1600 ? 1600 / longest : 1
        let target = CGSize(width: size.width * k, height: size.height * k)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }.jpegData(compressionQuality: 0.8)
    }
}
