import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

// What T3 Bot shows outside the app: the Needs widget and the Live Activity's lock screen view, with the bot faces
// they draw. Compiled into the widgets and into the app, whose debug gallery draws the same views for screen checks.

// MARK: - Data

struct WHome: Decodable {
    struct C: Decodable {
        let id: String; let title: String; let agent: String; let rank: Int
        // What kind of answer it wants and since when (older homes sent none of these).
        var kind: String? = nil
        var source: String? = nil
        var requestKind: String? = nil
        var at: String? = nil

        /// The same quiet mark the app's rows use: an alarm (red), an approval, a question.
        /// A mark on every row: red alarm, orange approve, blue answer, grey to do (the app's four kinds).
        var mark: (symbol: String, alarm: Bool)? {
            if kind == "alarm" { return ("exclamationmark.triangle.fill", true) }
            if source == "question" { return (requestKind == "command" ? "checkmark.shield.fill" : "questionmark.bubble.fill", false) }
            if kind == "approve" { return ("checkmark.shield.fill", false) }
            return ("checklist", false)
        }
    }
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
        case .notPaired: return "Open T3 Bot to connect it."
        case .unreachable: return "Can't reach T3 Code right now."
        }
    }
}

/// The bots' faces, fetched from the server by the timeline and kept small in this extension's caches. The
/// views (which cannot wait for the network) read what is there, after what the app mirrored (SharedFaces).
enum FaceCache {
    static var folder: URL { (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory) }

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

struct NeedsView: View {
    let entry: NeedsEntry
    /// Set to draw one size inside the app (the debug gallery); a widget reads its own.
    var size: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { size ?? widgetFamily }

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
                Label(notice == nil ? "\(needs.count) \(noun)" : "T3 Bot", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                    .font(.headline)
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
                            BotFace(agent: c.agent, name: entry.home?.bot(c.agent)?.name ?? "", color: entry.home?.bot(c.agent)?.color, size: family == .systemLarge ? 30 : 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.title).font(.footnote.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                // Who and how long ago, quietly: the row says whose it is without a second look.
                                Text([entry.home?.bot(c.agent)?.name, c.at.map { Ago.short($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let mark = c.mark {
                                // The app's colours for the kinds: red alarm, orange approve, blue answer.
                                Image(systemName: mark.symbol).font(.caption2.weight(.bold))
                                    // The app's colours for the kinds: red alarm, orange approve, blue answer, grey to do.
                                    .foregroundStyle(mark.alarm ? Color.red : mark.symbol.hasPrefix("checkmark") ? Color.orange
                                                     : mark.symbol == "checklist" ? Color.secondary : Color.blue)
                            }
                        }
                    }
                    // Rows, not web links: no accent colour on them.
                    .tint(Color.primary)
                }
                if needs.count > (family == .systemLarge ? 8 : 3), notice == nil {
                    Text("and \(needs.count - (family == .systemLarge ? 8 : 3)) more").font(.caption2).foregroundStyle(.secondary)
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
                    // The one that matters most, large enough to read at a glance.
                    if let c = top {
                        // The face beside its words, one block (alone above them it looked stranded).
                        HStack(alignment: .top, spacing: 6) {
                            BotFace(agent: c.agent, name: entry.home?.bot(c.agent)?.name ?? "", color: entry.home?.bot(c.agent)?.color, size: 24)
                            Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(updated == nil ? 3 : 2)
                                .foregroundStyle(c.mark?.alarm == true ? Color.red : Color.primary)
                        }
                    }
                    if let updated { Text(updated).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .widgetURL(URL(string: top.map { "t3bot://card/\($0.id)" } ?? "t3bot://home"))
        }
    }
}

/// A bot at work, on the lock screen (the Live Activity's main view).
struct BotWorkLockView: View {
    let attributes: BotWorkAttributes
    let state: BotWorkAttributes.ContentState
    /// The card behind it on the lock screen (set on the activity; the debug gallery draws the same).
    static let background = Color(white: 0.09).opacity(0.86)

    var body: some View {
            HStack(spacing: 12) {
                BotFace(agent: attributes.agentId, name: attributes.agentName, color: attributes.agentColor, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(attributes.agentName).font(.headline)
                        Spacer()
                        if state.status == "working" {
                            HStack(spacing: 4) {
                                Circle().fill(BotFace.tint(attributes.agentColor).color).frame(width: 6, height: 6)
                                Text("Working").foregroundStyle(.primary)
                                Text(Date(timeIntervalSince1970: state.startedAt), style: .timer).monospacedDigit()
                                    .frame(maxWidth: 44, alignment: .trailing)
                            }
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        } else {
                            // The word in the text colour, the check in green: green text on the tinted glass was hard to read.
                            Label {
                                Text("Answered").foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                    Text(state.status == "working" ? (state.text.isEmpty ? "Working on your message" : state.text) : state.text)
                        .font(.subheadline).lineLimit(2).foregroundStyle(state.status == "working" ? .secondary : .primary)
                        .contentTransition(.opacity)
                    // The rest of the crew, in a line: what waits on you while this bot works.
                    if let n = state.needs, n > 0 {
                        Label(n == 1 ? "1 needs you" : "\(n) need you", systemImage: "tray.full.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(14)
    }
}
