#if DEBUG
import SwiftUI
import WidgetKit

/// Screen checks only (t3bot://debug/gallery/widgets, /lock): the real widget and Live Activity views
/// (Shared/GlanceViews.swift) drawn at their sizes on a wallpaper, with the app's data, because a simulator cannot be
/// told to add a widget or to lock its screen.
struct GlanceGallery: View {
    let what: String
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private var entry: NeedsEntry {
        let home = store.home.flatMap { h -> WHome? in
            guard let data = try? JSONEncoder().encode(h) else { return nil }
            return try? JSONDecoder().decode(WHome.self, from: data)
        }
        return NeedsEntry(date: .now, home: home, fetched: .now)
    }

    /// Faces fetched into the widget's own cache, as the widget does before it draws.
    @State private var faces = 0

    var body: some View {
        ZStack {
            wallpaper.ignoresSafeArea()
            if what == "lock" { lock } else { widgets }
        }
        .id(faces)
        .onTapGesture { dismiss() }
        .task {
            guard let c = Connection.current, let ids = store.home?.agents.map(\.id) else { return }
            await FaceCache.fetch(ids, from: c)
            faces += 1
        }
    }

    private var wallpaper: some View {
        LinearGradient(colors: scheme == .dark ? [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.22, green: 0.10, blue: 0.24)]
                                                : [Color(red: 0.62, green: 0.74, blue: 0.93), Color(red: 0.93, green: 0.76, blue: 0.82)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var widgets: some View {
        VStack(spacing: 22) {
            HStack(spacing: 22) {
                tile(.systemSmall, w: 170, h: 170)
                VStack(spacing: 10) {
                    appIcon
                    Text("T3 Bot").font(.caption2).foregroundStyle(.white)
                }
                .frame(width: 170, height: 170)
            }
            tile(.systemMedium, w: 362, h: 170)
            tile(.systemLarge, w: 362, h: 382)
        }
        .padding(.top, 40)
    }

    private func tile(_ family: WidgetFamily, w: CGFloat, h: CGFloat) -> some View {
        NeedsView(entry: entry, size: family)
            .padding(16)
            .frame(width: w, height: h, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var appIcon: some View {
        Image(uiImage: UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon") ?? UIImage())
            .resizable().frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var lock: some View {
        let a = store.home?.agents.first { $0.id == store.chiefId } ?? store.home?.agents.first
        let attrs = BotWorkAttributes(agentId: a?.id ?? "chief", agentName: a?.name ?? "Chief", agentColor: a?.color)
        let started = Date().addingTimeInterval(-74).timeIntervalSince1970
        return VStack(spacing: 10) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                .padding(.top, 70)
            Text("9:41").font(.system(size: 96, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            // Lock screen widgets sit under the time.
            // One lock screen widget: the circular one beside it only said the same count again.
            NeedsView(entry: entry, size: .accessoryRectangular).frame(width: 172, height: 76, alignment: .leading)
                .foregroundStyle(.white)
            Spacer()
            // Live Activities sit at the bottom: one at work, one that just answered.
            BotWorkLockView(attributes: attrs, state: .init(status: "working", text: "Reading the crash reports", startedAt: started, needs: store.needs.count))
                .background(BotWorkLockView.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 12)
            Color.clear.frame(height: 60)
        }
        .environment(\.colorScheme, .dark)
    }
}
#endif
