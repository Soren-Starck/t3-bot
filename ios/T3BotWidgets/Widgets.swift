import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// T3 Bot widgets: what needs you (home and lock screen) and the Live Activity of a bot at work.

@main
struct T3BotWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NeedsWidget()
        BotWorkLiveActivity()
    }
}

// MARK: - Data

struct WHome: Decodable {
    struct C: Decodable { let id: String; let title: String; let agent: String; let rank: Int }
    struct A: Decodable {
        let id: String
        let name: String
        let status: String
        /// The bot's color (hex), for the face drawn when there is no picture of it.
        var color: String? = nil
    }
    let needs: [C]
    let agents: [A]
    let badge: Int

    func bot(_ id: String) -> A? { agents.first(where: { $0.id == id }) }
}

struct NeedsEntry: TimelineEntry {
    /// `live`: the server answered now, or it did earlier and that answer is still shown.
    enum Link { case live, notPaired, unreachable }

    let date: Date
    let home: WHome?
    var link: Link = .live
    /// When the server gave this answer. Nil when there is no answer to date.
    var fetched: Date? = nil
    /// The server did not answer this time: what is shown is its last answer, kept.
    var kept = false

    /// How old an answer may be before the widget says so.
    static let freshFor: TimeInterval = 15 * 60

    /// "updated 14:32" once the answer is more than 15 minutes old at the time this entry is shown (with the
    /// day when it is not from today), else nil.
    var updated: String? {
        guard home != nil, let fetched, date.timeIntervalSince(fetched) > Self.freshFor else { return nil }
        let today = Calendar.current.isDate(fetched, inSameDayAs: date)
        return "updated " + fetched.formatted(date: today ? .omitted : .abbreviated, time: .shortened)
    }

    /// The same answer as it is shown at a later time.
    func shown(at later: Date) -> NeedsEntry {
        NeedsEntry(date: later, home: home, link: link, fetched: fetched, kept: kept)
    }

    /// What to say in place of the list when there is nothing to list.
    var notice: String? {
        switch link {
        case .live: return nil
        case .notPaired: return "Open T3 Bot to pair it with your server."
        case .unreachable: return "Can't reach your server."
        }
    }
}

enum WAPI {
    /// What the widget shows now. The connection is read fresh every time, so the widget follows a pairing
    /// made in the app. When the server does not answer, its last answer is shown again, with its age.
    static func entry() async -> NeedsEntry {
        guard let c = Connection.load() else { return NeedsEntry(date: .now, home: nil, link: .notPaired) }
        let kept = FaceCache.folder.appendingPathComponent("home-\(FaceCache.clean(c.label)).json")
        if var r = c.request("v1/home", timeout: 10) {
            r.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
               let home = try? JSONDecoder().decode(WHome.self, from: data) {
                try? data.write(to: kept, options: .atomic)
                await FaceCache.fetch(Array(Set(home.needs.prefix(8).map(\.agent))), from: c)
                return NeedsEntry(date: .now, home: home, fetched: .now)
            }
        }
        if let data = try? Data(contentsOf: kept), let home = try? JSONDecoder().decode(WHome.self, from: data) {
            // The kept file was written when the server last answered.
            let written = (try? FileManager.default.attributesOfItem(atPath: kept.path))?[.modificationDate] as? Date
            return NeedsEntry(date: .now, home: home, fetched: written, kept: true)
        }
        return NeedsEntry(date: .now, home: nil, link: .unreachable)
    }
}

/// The bots' faces, fetched from the server by the timeline and kept small in this extension's caches. The
/// views (which cannot wait for the network) read what is there, after what the app mirrored (SharedFaces).
enum FaceCache {
    static var folder: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// Only what is safe in a file name.
    static func clean(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    private static func file(_ agent: String) -> URL { folder.appendingPathComponent("face-\(clean(agent)).png") }

    static func stored(_ agent: String) -> UIImage? { UIImage(contentsOfFile: file(agent).path) }

    /// Fetches these bots' faces, a few at once, and keeps each at the size a widget draws.
    static func fetch(_ agents: [String], from c: Connection) async {
        await withTaskGroup(of: Void.self) { group in
            for agent in agents {
                group.addTask { await fetchOne(agent, from: c) }
            }
        }
    }

    private static func fetchOne(_ agent: String, from c: Connection) async {
        // Bot ids are lowercase letters, digits and dashes; anything else has no face to ask for.
        guard !agent.isEmpty, clean(agent) == agent, var r = c.request("v1/avatars/\(agent).png", timeout: 5) else { return }
        r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let face = UIImage(data: data) else { return }
        // A widget may only hold small pictures: 132 pixels is twice the largest face it draws at 3x.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let side: CGFloat = 132
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            face.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        try? small.pngData()?.write(to: file(agent), options: .atomic)
    }
}

/// A bot's face: its picture from the server, else the bot's initial on its color. No build carries any
/// bot's picture. The picture is the one the app mirrored for its extensions (it follows a new skin at
/// once, and it is all the Live Activity has, which cannot fetch), else the one this extension fetched for
/// the widget.
struct BotFace: View {
    let agent: String
    var name: String = ""
    var color: String? = nil
    let size: CGFloat

    var body: some View {
        if let img = picture {
            Image(uiImage: img).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            let tint = BotFace.tint(color ?? SharedFaces.color(agent))
            Circle().fill(tint.color)
                .frame(width: size, height: size)
                .overlay(
                    Text(initial)
                        .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint.light ? Color.black.opacity(0.75) : Color.white)
                )
                .accessibilityHidden(true)
        }
    }

    private var picture: UIImage? {
        if let data = SharedFaces.picture(agent), let img = UIImage(data: data) { return img }
        return FaceCache.stored(agent)
    }

    private var initial: String {
        let source = name.trimmingCharacters(in: .whitespaces).isEmpty ? agent : name.trimmingCharacters(in: .whitespaces)
        return String(source.prefix(1)).uppercased()
    }

    /// "#RRGGBB" as a color, and whether it is light enough to need dark lettering. Gray when there is none.
    static func tint(_ hex: String?) -> (color: Color, light: Bool) {
        let digits = (hex ?? "").filter { $0.isHexDigit }
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return (Color(white: 0.55), false) }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        return (Color(red: r, green: g, blue: b), 0.299 * r + 0.587 * g + 0.114 * b > 0.7)
    }
}

struct NeedsProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsEntry { NeedsEntry(date: .now, home: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NeedsEntry) -> Void) {
        Task { completion(await WAPI.entry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsEntry>) -> Void) {
        Task {
            let e = await WAPI.entry()
            var entries = [e]
            // iOS decides when the next refresh really runs, and it can be late. So the same answer is
            // lined up again for when it turns 15 minutes old, where it says "updated <time>"; a refresh
            // that comes in time replaces it before it shows.
            if e.home != nil, e.updated == nil, let fetched = e.fetched {
                let turnsOld = fetched.addingTimeInterval(NeedsEntry.freshFor + 60)
                if turnsOld > e.date { entries.append(e.shown(at: turnsOld)) }
            }
            // Sooner when the server did not answer, so the widget is not stuck on that for long.
            let wait: TimeInterval = e.link == .unreachable || e.kept ? 5 * 60 : 15 * 60
            completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(wait))))
        }
    }
}

// MARK: - Needs widget

struct NeedsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "needs", provider: NeedsProvider()) { e in
            NeedsView(entry: e).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("What needs you, most urgent first.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NeedsView: View {
    let entry: NeedsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let needs = entry.home?.needs ?? []
        let top = needs.first
        let notice = entry.notice
        // "updated 14:32" when what is shown is more than 15 minutes old.
        let updated = entry.updated
        // One card "needs you", two "need you".
        let noun = needs.count == 1 ? "needs you" : "need you"
        let spoken: String = notice ?? ("\(needs.count) \(noun)" + (updated.map { ", " + $0 } ?? ""))
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if notice != nil {
                    Image(systemName: entry.link == .notPaired ? "qrcode" : "wifi.slash").font(.title3)
                } else {
                    VStack(spacing: 0) {
                        Text("\(needs.count)").font(.title2.weight(.bold)).monospacedDigit()
                        Text(needs.count == 1 ? "needs" : "need").font(.caption2)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .widgetURL(URL(string: "t3bot://home"))
        case .accessoryInline:
            Text(notice ?? top.map { "\(needs.count) · \($0.title)" } ?? "Nothing needs you")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(notice == nil ? "T3 Bot · \(needs.count)" : "T3 Bot").font(.headline)
                Text(notice ?? top?.title ?? "Nothing needs you").font(.caption).lineLimit(updated == nil ? 2 : 1)
                if let updated { Text(updated).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .widgetURL(URL(string: top.map { "t3bot://card/\($0.id)" } ?? "t3bot://home"))
        case .systemMedium, .systemLarge:
            VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 6) {
                HStack {
                    Text("Needs you").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let updated { Text(updated).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    if notice == nil { Text("\(needs.count)").font(.caption.weight(.bold)).monospacedDigit() }
                }
                if let notice {
                    Spacer()
                    Text(notice).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                } else if needs.isEmpty {
                    Spacer()
                    Text("Nothing needs you.").font(.subheadline)
                    Spacer()
                }
                ForEach(Array(needs.prefix(family == .systemLarge ? 8 : 3).enumerated()), id: \.offset) { _, c in
                    Link(destination: URL(string: "t3bot://card/\(c.id)") ?? URL(string: "t3bot://home")!) {
                        HStack(spacing: 8) {
                            BotFace(agent: c.agent, name: entry.home?.bot(c.agent)?.name ?? "", color: entry.home?.bot(c.agent)?.color, size: 22)
                            Text(c.title).font(.footnote).lineLimit(1)
                            Spacer(minLength: 0)
                            if c.rank <= 1 { Circle().fill(c.rank == 0 ? .orange : .red).frame(width: 6, height: 6) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                if let notice {
                    Text("T3 Bot").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(needs.count)").font(.system(size: 34, weight: .bold)).monospacedDigit()
                        Text(noun).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let top {
                        HStack(alignment: .top, spacing: 6) {
                            BotFace(agent: top.agent, name: entry.home?.bot(top.agent)?.name ?? "", color: entry.home?.bot(top.agent)?.color, size: 22)
                            Text(top.title).font(.caption).lineLimit(updated == nil ? 3 : 2)
                        }
                    }
                    if let updated { Text(updated).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .widgetURL(URL(string: top.map { "t3bot://card/\($0.id)" } ?? "t3bot://home"))
        }
    }
}

// MARK: - Live Activity

struct BotWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BotWorkAttributes.self) { ctx in
            HStack(spacing: 12) {
                BotFace(agent: ctx.attributes.agentId, name: ctx.attributes.agentName, color: ctx.attributes.agentColor, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(ctx.attributes.agentName).font(.headline)
                        Spacer()
                        if ctx.state.status == "working" {
                            Text(Date(timeIntervalSince1970: ctx.state.startedAt), style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(ctx.state.status == "working" ? (ctx.state.text.isEmpty ? "Working on your message" : ctx.state.text) : ctx.state.text)
                        .font(.subheadline).lineLimit(2).foregroundStyle(ctx.state.status == "working" ? .secondary : .primary)
                        .contentTransition(.opacity)
                }
            }
            .padding(14)
            .widgetURL(URL(string: "t3bot://agent/\(ctx.attributes.agentId)"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BotFace(agent: ctx.attributes.agentId, name: ctx.attributes.agentName, color: ctx.attributes.agentColor, size: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ctx.attributes.agentName).font(.headline)
                        Text(ctx.state.status == "working" ? (ctx.state.text.isEmpty ? "Working on your message" : ctx.state.text) : ctx.state.text).font(.caption).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if ctx.state.status == "working" {
                        Text(Date(timeIntervalSince1970: ctx.state.startedAt), style: .timer).font(.caption.monospacedDigit()).frame(width: 44)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            } compactLeading: {
                BotFace(agent: ctx.attributes.agentId, name: ctx.attributes.agentName, color: ctx.attributes.agentColor, size: 22)
            } compactTrailing: {
                if ctx.state.status == "working" {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.green)
                }
            } minimal: {
                BotFace(agent: ctx.attributes.agentId, name: ctx.attributes.agentName, color: ctx.attributes.agentColor, size: 20)
            }
            .widgetURL(URL(string: "t3bot://agent/\(ctx.attributes.agentId)"))
        }
    }
}
