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

enum WAPI {
    /// What the widget shows now. The connection is read fresh every time, so the widget follows a pairing
    /// made in the app. When the server does not answer, its last answer is shown again, with its age.
    static func entry() async -> NeedsEntry {
        guard let c = Connection.load() else { return NeedsEntry(date: .now, home: nil, link: .notPaired) }
        let kept = FaceCache.folder.appendingPathComponent("home-\(FaceCache.clean(c.label)).json")
        // Paired with T3 Code itself: Home is built here from T3 Code (over HTTP; a widget keeps no connection open).
        // The faces are the ones the app mirrored (SharedFaces), so nothing else is fetched.
        if c.isDirect {
            if let full = try? await DirectLink.backend(c).home(), let data = try? JSONEncoder().encode(full),
               let home = try? JSONDecoder().decode(WHome.self, from: data) {
                try? data.write(to: kept, options: .atomic)
                return NeedsEntry(date: .now, home: home, fetched: .now)
            }
        } else if var r = c.request("v1/home", timeout: 10) {
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

struct NeedsProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsEntry { NeedsEntry(date: .now, home: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NeedsEntry) -> Void) {
        Task { completion(await WAPI.entry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (WidgetKit.Timeline<NeedsEntry>) -> Void) {
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
            completion(WidgetKit.Timeline(entries: entries, policy: .after(.now.addingTimeInterval(wait))))
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

// MARK: - Live Activity

struct BotWorkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BotWorkAttributes.self) { ctx in
            BotWorkLockView(attributes: ctx.attributes, state: ctx.state)
                .widgetURL(URL(string: "t3bot://agent/\(ctx.attributes.agentId)"))
                // A dark, nearly solid card: on the translucent default, grey text over a bright wallpaper
                // could not be read.
                .activityBackgroundTint(BotWorkLockView.background)
                .activitySystemActionForegroundColor(.white)
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
