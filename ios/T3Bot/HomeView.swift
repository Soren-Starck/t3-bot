import SwiftUI

/// Home: the lead bot on top with a field to ask it anything, the other bots right under it. A bot with something
/// urgent says it in orange under its name; a floating Review button swipes through everything that needs you.
/// The bots sit in three sections by state, Needs you, Working and Idle, and move between them as their state
/// changes. The lead bot (`store.chiefId`) stays on top whatever its state.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var ask = ""
    @State private var showNew = false
    @State private var query = ""
    @State private var showSettings = false
    /// A bot's own list of what needs you, opened from its row's menu.
    @State private var needsOf: String?
    /// The "Hidden bots" row is open.
    @State private var showHidden = false
    /// The screen on top is a plain list (Needs you, Done without you) with nothing at its bottom to clear.
    @State private var plainListOnTop = false
    /// The search and what it found. Held here so one task on the list asks the server, not one per row.
    @StateObject private var search = SearchModel()
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var asking: Bool

    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if searching {
                    SearchResults(query: query, model: search)
                } else if store.home == nil {
                    // Nothing saved and no answer: say why and what to do. Before that, the shape of the screen.
                    if store.error != nil { unreachable } else { loadingRows }
                } else {
                    if let problem = t3Problem {
                        Section {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your bots cannot work right now").font(.subheadline.weight(.semibold))
                                    Text(problem).font(.footnote).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    if let chief = lead {
                        Section {
                            NavigationLink(value: Route.agent(chief.id)) { AgentRow(agent: chief, prominent: true) }
                                .botMenu(chief, needsOf: $needsOf)
                            askField(chief)
                        } footer: {
                            if onlyLead { Text("This is your only bot. Tap + to add one for a project, or a group chat.") }
                        }
                    }
                    if store.home?.agents.isEmpty == true { noBots }
                    ForEach(shelves) { group in
                        Section {
                            ForEach(group.bots) { a in
                                NavigationLink(value: Route.agent(a.id)) { AgentRow(agent: a) }
                                    .botMenu(a, needsOf: $needsOf)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            }
                        } header: {
                            ShelfHeader(shelf: group.shelf, count: group.bots.count)
                        }
                    }
                    if let hidden = store.home?.agents.filter(\.hidden), !hidden.isEmpty {
                        Section {
                            // A row of its own, not a DisclosureGroup: that one indents its rows and draws a heavier
                            // chevron than the rest of the list.
                            Button {
                                withAnimation(.spring(duration: 0.3)) { showHidden.toggle() }
                            } label: {
                                HStack {
                                    Text("Hidden bots · \(hidden.count)").foregroundStyle(Color.primary)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color(.tertiaryLabel))
                                        .rotationEffect(.degrees(showHidden ? 90 : 0))
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Hidden bots · \(hidden.count)")
                            .accessibilityValue(showHidden ? "Open" : "Closed")
                            if showHidden {
                                ForEach(hidden) { a in
                                    NavigationLink(value: Route.agent(a.id)) { AgentRow(agent: a) }
                                        .botMenu(a, needsOf: $needsOf)
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                }
                            }
                        }
                    }
                    if let home = store.home, !home.agents.isEmpty {
                        Section {
                            NavigationLink(value: Route.know) {
                                HStack {
                                    Label("Done without you today", systemImage: "checkmark.seal")
                                    Spacer()
                                    Text("\(home.doneToday)").foregroundStyle(home.doneToday > 0 ? Color.green : Color.secondary).monospacedDigit().contentTransition(.numericText())
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            // A bot whose state changes slides into its new section.
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: shelves.map { "\($0.shelf.rawValue):\($0.bots.map(\.id))" })
            .contentMargins(.bottom, store.needs.isEmpty ? 0 : 84, for: .scrollContent)
            .overlay(alignment: .bottom) {
                if !store.needs.isEmpty && query.isEmpty && !asking { reviewButton }
            }
            // With nothing to show, the list itself says the server is away; the pill is for when old data is on screen.
            .overlay(alignment: .top) { if store.home != nil { OfflinePill().padding(.top, 6) } }
            .animation(.spring(duration: 0.35), value: store.online)
            .animation(.spring(duration: 0.35), value: store.needs.isEmpty)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats and cards")
            // One search per query for the whole list. Typing on restarts it, which cancels the one before.
            .task(id: searching ? "\(search.attempt) \(query)" : "") {
                if searching { await search.run(query) } else { search.clear() }
            }
            // The server is back: ask again what could not be asked.
            .onChange(of: store.online) { _, online in
                if online && searching { search.retry() }
            }
            // A card acted on from the results leaves them (they were fetched before the action).
            .onChange(of: store.doneLocally) { _, ids in search.noteActed(ids) }
            .navigationTitle("T3 Bot")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New bot or group")
                        // Nothing loaded from the server yet: a new bot could not be made.
                        .disabled(store.home == nil)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("T3 Bot").font(.headline)
                        Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.default, value: statusLine)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .agent(id): AgentView(agentId: id)
                case .allNeeds:
                    AllNeedsView()
                        .onAppear { plainListOnTop = true }
                        .onDisappear { plainListOnTop = false }
                case .know:
                    KnowView()
                        .onAppear { plainListOnTop = true }
                        .onDisappear { plainListOnTop = false }
                }
            }
            .refreshable { await store.refreshAll() }
            // The store keeps everything fresh (one loop for the whole app); settings load once.
            .task { await store.loadSettings() }
            #if DEBUG
            .onChange(of: store.debugSheet) { _, w in
                guard let w else { return }
                if w == "settings" { showSettings = true }
                if w == "new" { showNew = true }
                if w.hasPrefix("search-") { query = String(w.dropFirst(7)) }
                if w.hasPrefix("needs-") { needsOf = String(w.dropFirst(6)) }
                if !w.hasPrefix("edit-") { store.debugSheet = nil }
            }
            #endif
        }
        .sheet(item: $store.selectedCard) { CardSheet(card: $0).environmentObject(store) }
        .sheet(isPresented: $showNew) { NewBotSheet().environmentObject(store) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(store) }
        .sheet(item: Binding(get: { needsOf.map { AgentRef(id: $0) } }, set: { needsOf = $0?.id })) { BotNeedsSheet(agentId: $0.id).environmentObject(store) }
        .fullScreenCover(isPresented: $store.showReview) { ReviewView().environmentObject(store) }
        // On the two plain lists nothing sits at the bottom, so the bar does not float over their rows.
        // An open chat draws the bar itself, in the flow above its composer.
        .overlay(alignment: .bottom) { ToastBar(bottom: plainListOnTop ? 20 : nil, yieldsToChat: true).environmentObject(store) }
    }

    /// Two characters or more in the search field: the list shows what was found instead of the bots.
    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    /// The bot on top: the one the server names as chief, unless it is hidden or the server has no bot yet.
    private var lead: Agent? {
        guard let a = store.agent(store.chiefId), !a.hidden else { return nil }
        return a
    }

    /// What stops the bots on the server side (T3 Code not running, not installed), in the server's own words.
    private var t3Problem: String? {
        guard let t3 = store.home?.t3, t3.ok == false else { return nil }
        return t3.error ?? "The server cannot reach T3 Code."
    }

    /// One bot and nothing else to show under it.
    private var onlyLead: Bool {
        guard let agents = store.home?.agents else { return false }
        return lead != nil && agents.count == 1
    }

    /// Under the title: what needs you and who is working, at a glance.
    private var statusLine: String {
        guard let h = store.home else { return store.refused ? "Not paired" : store.online ? "Connecting" : "Offline" }
        // The card under it already says there is no bot yet.
        if h.agents.isEmpty { return store.online ? "Connected" : "Offline" }
        let urgent = store.needs.filter { $0.rank <= 1 }.count
        let working = h.agents.filter { Shelf.of($0, store) == .working }.count
        var parts: [String] = []
        if urgent > 0 { parts.append("\(urgent) urgent") }
        // Alone under the title it starts with a capital, like "Connected" and "Offline".
        parts.append(working == 0 ? (parts.isEmpty ? "All quiet" : "all quiet") : "\(working) working")
        return parts.joined(separator: " · ")
    }

    /// First launch with nothing saved yet: the shape of the screen while the server answers.
    private var loadingRows: some View {
        Section {
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 12) {
                    Circle().fill(Color(.secondarySystemFill)).frame(width: i == 0 ? 54 : 44, height: i == 0 ? 54 : 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color(.secondarySystemFill)).frame(width: 110, height: 12)
                        Capsule().fill(Color(.tertiarySystemFill)).frame(width: 200, height: 10)
                    }
                }
                .padding(.vertical, 4)
                // One spoken line for the whole placeholder, not five silent rows.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading your bots")
                .accessibilityHidden(i != 0)
            }
        }
        .phaseAnimator([0.45, 1]) { content, o in content.opacity(o) } animation: { _ in .easeInOut(duration: 0.9) }
    }

    /// Nothing saved on the phone and the server did not answer (or refused the token): what happened, and the
    /// ways out. Pull to refresh works here too.
    @ViewBuilder private var unreachable: some View {
        let server = Connection.current?.label ?? "the server"
        Section {
            VStack(spacing: 8) {
                Image(systemName: store.refused ? "lock.slash" : "wifi.slash")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(store.refused ? "This phone is not paired any more" : "Can't reach \(server)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(store.refused
                     ? "\(server) answered, but refused this phone's token. Pair again with the link or the QR code from t3bot pair."
                     : "T3 Bot keeps trying. Check that the server is running and that this phone is on the same network or VPN as it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        Section {
            if store.refused {
                Button { store.showConnect = true } label: { Label("Pair again", systemImage: "qrcode.viewfinder") }
            }
            Button { Haptics.tap(); Task { await store.refreshAll() } } label: { Label("Try again", systemImage: "arrow.clockwise") }
            Button { showSettings = true } label: { Label("Connection settings", systemImage: "gearshape") }
        }
    }

    /// The server answered and has no bot yet.
    private var noBots: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No bots yet").font(.headline)
                Text("A bot is one of your agent threads with a name, a face and a job. Create the first one and it shows up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create a bot") { showNew = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.primary)
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    /// The bots under the lead, grouped by state; empty sections are left out.
    private var shelves: [ShelfGroup] {
        let top = lead?.id
        let agents = store.home?.agents.filter { $0.id != top && !$0.hidden } ?? []
        return Shelf.allCases.compactMap { shelf in
            var bots = agents.filter { Shelf.of($0, store) == shelf }
            // Most urgent first among those that need you; the others keep their usual order, so they are easy to find.
            if shelf == .needsYou {
                let rank = { (a: Agent) in store.needs.filter { $0.agent == a.id }.map(\.rank).min() ?? 9 }
                bots = bots.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            }
            return bots.isEmpty ? nil : ShelfGroup(shelf: shelf, bots: bots)
        }
    }

    /// Everything that needs you, one tap away: swipe through it (long press: the list).
    private var reviewButton: some View {
        let n = store.needs.count
        let urgent = store.needs.filter { $0.rank <= 1 }.count
        return Button { Haptics.tap(); store.showReview = true } label: {
            // Always one line: when the full label is too wide (very large text), the urgent count goes and its
            // dot stays.
            ViewThatFits(in: .horizontal) {
                reviewLabel(n, urgent: urgent, spelled: true)
                reviewLabel(n, urgent: urgent, spelled: false)
            }
            .font(.subheadline)
            .foregroundStyle(Color(.systemBackground))
            .padding(.horizontal, 20).padding(.vertical, 13)
            .glassEffect(.regular.tint(Color.primary.opacity(0.88)).interactive(), in: .capsule)
            // The urgent dot is drawn over the glass, in the same place: inside it, the glass turned the
            // orange dark red in the light appearance and pale yellow in the dark one.
            .overlay {
                ViewThatFits(in: .horizontal) {
                    reviewLabel(n, urgent: urgent, spelled: true, dotOnly: true)
                    reviewLabel(n, urgent: urgent, spelled: false, dotOnly: true)
                }
                .font(.subheadline)
                .padding(.horizontal, 20).padding(.vertical, 13)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { store.path.append(Route.allNeeds) } label: { Label("See as a list", systemImage: "list.bullet") }
        }
        .accessibilityLabel(urgent > 0 ? "Review \(n), \(urgent) urgent" : "Review \(n)")
        // A floating bar: past this size it would cover the list it floats over.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// `dotOnly` is the same row with everything but the dot invisible: it lays the dot over the glass.
    private func reviewLabel(_ n: Int, urgent: Int, spelled: Bool, dotOnly: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.stack.fill").opacity(dotOnly ? 0 : 1)
            Text("Review \(n)").fontWeight(.semibold).contentTransition(.numericText()).opacity(dotOnly ? 0 : 1)
            if urgent > 0 {
                // An orange dot keeps the urgency visible on the pill in light and dark mode alike.
                Circle().fill(dotOnly ? Color.orange : Color.clear).frame(width: 7, height: 7).padding(.leading, 2)
                if spelled { Text("\(urgent) urgent").opacity(dotOnly ? 0 : 0.75) }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func askField(_ chief: Agent) -> some View {
        let empty = ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The short form at the largest text sizes, where the long one is cut.
        let prompt: String = typeSize.isAccessibilitySize ? "Ask \(chief.name)" : "Ask \(chief.name) anything"
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(prompt, text: $ask, axis: .vertical)
                .lineLimit(1...4)
                .submitLabel(.send)
                .focused($asking)
                .onSubmit { send(chief) }
                .padding(.vertical, 2)
            if !empty {
                Button { send(chief) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Send to \(chief.name)")
            }
        }
        .animation(.spring(duration: 0.25), value: empty)
    }

    /// Opens the lead bot's chat at once with the message in it; it is sent behind.
    private func send(_ chief: Agent) {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ask = ""
        asking = false
        store.send(text, to: chief.id)
        store.open(agent: chief.id)
    }
}

struct AgentRef: Identifiable { let id: String }

/// "Needs you · 2" with the section's own mark.
struct ShelfHeader: View {
    let shelf: Shelf
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(shelf.color).frame(width: 7, height: 7)
            Text(shelf.title)
            Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .textCase(nil)
    }
}

extension View {
    /// Long press on a bot: a peek at its chat, and what can be done without opening it.
    func botMenu(_ a: Agent, needsOf: Binding<String?>) -> some View {
        modifier(BotMenu(agent: a, needsOf: needsOf))
    }
}

struct BotMenu: ViewModifier {
    let agent: Agent
    @Binding var needsOf: String?
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { store.open(agent: agent.id) } label: { Label("Open chat", systemImage: "bubble.left.and.bubble.right") }
            if agent.needs > 0 {
                Button { needsOf = agent.id } label: { Label("What needs you (\(agent.needs))", systemImage: "tray.full") }
            }
            if let link = agent.t3Link, let url = URL(string: link) {
                Button { openURL(url) } label: { Label("Open in T3 Code", systemImage: "arrow.up.right.square") }
            }
        } preview: {
            ChatPeek(agentId: agent.id).environmentObject(store)
        }
    }
}

/// The last few messages of a chat, for the long-press preview on home.
struct ChatPeek: View {
    let agentId: String
    @EnvironmentObject var store: Store

    var body: some View {
        let a = store.agent(agentId)
        let entries = (store.timelines[agentId]?.entries ?? []).filter { !$0.isAutomatic && !$0.text.isEmpty }.suffix(4)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let a { LiveFace(face: a.face, size: 40, state: store.faceState(a)) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(a?.name ?? "").font(.headline)
                    Text(a?.activityText ?? a?.role ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if entries.isEmpty {
                Text((a?.last?.text).map { EntryView.previewWithoutImages($0) } ?? "No messages yet.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(entries)) { e in
                HStack {
                    if e.type == "me" { Spacer(minLength: 40) }
                    Text(Markdown.render(EntryView.withoutImageLines(e.text)))
                        .font(.subheadline)
                        .lineLimit(4)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 15).fill(e.type == "me" ? Color.primary : Color(.secondarySystemBackground)))
                        .foregroundStyle(e.type == "me" ? Color(.systemBackground) : Color.primary)
                    if e.type != "me" { Spacer(minLength: 40) }
                }
            }
        }
        .padding(16)
        // Never wider than the phone (a small screen with Display Zoom is 320 points wide).
        .frame(width: min(330, ScreenSize.width - 32), alignment: .leading)
        .background(Color(.systemBackground))
    }
}

// MARK: - Rows

struct ShelfGroup: Identifiable {
    let shelf: Shelf
    let bots: [Agent]
    var id: Int { shelf.rawValue }
}

/// The section a bot sits in on home.
enum Shelf: Int, CaseIterable {
    case needsYou, working, idle

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: .orange
        case .working: .blue
        case .idle: Color(.tertiaryLabel)
        }
    }

    @MainActor static func of(_ a: Agent, _ store: Store) -> Shelf {
        // Just sent it a message: it is working, before the server has seen the run start.
        if store.outgoing[a.id] != nil { return .working }
        switch a.mood {
        case "waiting", "failed": return .needsYou
        case "working", "watching": return .working
        default: return .idle
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    var prominent = false
    @EnvironmentObject var store: Store
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The largest text sizes: the status gets two lines, the count moves up beside the name and the time goes
    /// under, so the row still says something.
    private var big: Bool { typeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            let s: CGFloat = prominent ? 54 : 44
            if agent.kind == "group" {
                AvatarView(agent: agent.id, size: s)
            } else {
                LiveFace(face: agent.face, size: s, state: store.faceState(agent))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.name).font(prominent ? .title3.weight(unread ? .bold : .semibold) : .body.weight(unread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if big {
                        needsBadge
                    } else if let last = agent.last {
                        Text(Ago.short(last.at)).font(.caption.weight(unread ? .semibold : .regular))
                            .foregroundStyle(unread ? Color.blue : Color.secondary).monospacedDigit()
                    }
                    if unread { Circle().fill(Color.blue).frame(width: 9, height: 9).transition(.scale.combined(with: .opacity)) }
                }
                .animation(.spring(duration: 0.3), value: unread)
                // One line only: the rows stay short so every bot fits on screen (two at the largest text sizes).
                HStack(spacing: 6) {
                    if let u = urgentLine {
                        Text(u).foregroundStyle(Color.orange)
                    } else if let doing = agent.activityText, Shelf.of(agent, store) == .working {
                        Image(systemName: activitySymbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                            .symbolEffect(.pulse, options: .repeating)
                        Text(agent.mood == "watching" ? "\(doing) · \(agent.watching.first ?? "")" : doing).foregroundStyle(.secondary)
                    } else if let d = store.drafts[agent.id] {
                        Text("\(Text("Draft: ").fontWeight(.semibold))\(Text(verbatim: d))").foregroundStyle(.secondary)
                    } else {
                        Text(subtitle).foregroundStyle(unread ? Color.primary : Color.secondary)
                    }
                    Spacer(minLength: 4)
                    if !big { needsBadge }
                }
                .font(.subheadline)
                .lineLimit(big ? 2 : 1)
                if big, let last = agent.last {
                    Text(Ago.short(last.at)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
        }
        .padding(.vertical, prominent ? 4 : 1)
        .accessibilityElement(children: .combine)
    }

    /// How many things this bot needs from you.
    @ViewBuilder private var needsBadge: some View {
        if agent.needs > 0 {
            Text("\(agent.needs)")
                .font(.caption.weight(.bold)).monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary))
                .foregroundStyle(Color(.systemBackground))
                .contentTransition(.numericText())
        }
    }

    /// A reply that has not been opened yet.
    private var unread: Bool { store.unread(agent) }

    /// Its most urgent card, said plainly (a question, a customer waiting, money, an alarm).
    private var urgentLine: String? {
        guard let c = store.needs.first(where: { $0.agent == agent.id && $0.rank <= 1 }) else { return nil }
        let prefix = c.isApproval ? "" : c.isQuestion ? "Asks: " : c.customer == true ? "Customer waiting: " : c.kind == "alarm" ? "Alarm: " : ""
        return "● " + prefix + c.title
    }

    private var activitySymbol: String {
        if agent.mood == "watching" { return "eye" }
        switch agent.activity {
        case "reading": return "doc.text.magnifyingglass"
        case "running": return "terminal"
        case "writing": return "pencil"
        case "web": return "globe"
        case "delegating": return "person.2"
        default: return "sparkles"
        }
    }

    private var subtitle: String {
        if store.outgoing[agent.id] != nil { return "Sending" }
        if let last = agent.last { return (last.from == "me" ? "You: " : "") + EntryView.previewWithoutImages(last.text) }
        return agent.role
    }
}

struct CardRow: View {
    @EnvironmentObject var store: Store
    let card: Card
    /// Where the full card opens; the home screen's sheet when nil.
    var onTap: ((Card) -> Void)? = nil

    var body: some View {
        Button { if let onTap { onTap(card) } else { store.selectedCard = card } } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(agent: card.agent, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    // Hyphens that do not break: "--only" was cut after its dashes, with room left on the line.
                    Text(card.title.unbroken).font(.subheadline).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if card.rank <= 1 {
                            Circle().fill(card.rank == 0 ? Color.orange : Color.red).frame(width: 6, height: 6)
                        }
                        Text(CardText.meta(card, store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !card.isQuestion {
                Button("Done") { store.act(card, "done") }.tint(.green)
            }
            Button("Not now") { store.act(card, "snooze") }.tint(.gray)
        }
    }
}

enum CardText {
    @MainActor
    static func meta(_ c: Card, _ store: Store) -> String {
        let bot = store.agent(c.agent)
        let who = bot?.name ?? c.agent
        var parts: [String] = []
        if c.isQuestion {
            // A row has no name beside its face, so the line starts with the bot. Its own thread is titled
            // "%BOT <name>" on the server, which nobody says: only another thread is named.
            let thread = CardHeader.threadName(c.threadTitle ?? "")
            let own = thread.isEmpty || thread == who || (c.threadId != nil && c.threadId == bot?.threadId)
            parts.append(who)
            if c.isApproval { parts.append(own ? "approval" : "approval in \(thread)") }
            else { parts.append(own ? "question" : "asks in \(thread)") }
        } else {
            parts.append(c.deskName ?? who)
            if c.customer == true { parts.append("customer waiting") }
            if let m = c.minutes, m > 0 { parts.append("\(Int(m.rounded()))\u{00A0}min") }
            if c.kind == "alarm" { parts.append("alarm") }
        }
        parts.append(Ago.short(c.at))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct AllNeedsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            let needs = store.needs
            ForEach(groups, id: \.0) { title, ranks in
                // A rank outside the known ones still shows, in the nearest group.
                let items = needs.filter { ranks.contains(min(max($0.rank, 0), 4)) }
                if !items.isEmpty {
                    Section("\(title) · \(items.count)") { ForEach(items) { CardRow(card: $0) } }
                }
            }
        }
        .overlay {
            if store.needs.isEmpty {
                ContentUnavailableView {
                    Label("Nothing needs you", systemImage: "checkmark.circle")
                } description: {
                    Text(store.online
                         ? "When a bot needs an answer, an approval or a look, its card shows up here."
                         : "The server cannot be reached right now, so this list may be out of date.")
                }
            }
        }
        .navigationTitle("Needs you")
        .refreshable { await store.refresh() }
    }

    private var groups: [(String, Set<Int>)] {
        [("Questions and alarms", [0]), ("Now", [1]), ("Today", [2]), ("This week", [3]), ("Later", [4])]
    }
}

struct KnowView: View {
    @State private var notes: [Note] = []
    /// Nothing has come back yet: the list says it is loading instead of "nothing today".
    @State private var loaded = false
    @State private var failed = false
    @State private var wrong: Note?
    @State private var wrongText = ""
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            if failed && notes.isEmpty {
                Label("Could not load this list. Pull down to try again.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            } else if !loaded {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading").foregroundStyle(.secondary)
                }
            } else if notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing reported yet today.")
                    Text("What your bots finish on their own is listed here, so you can check it or say it was wrong.")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(notes) { n in
                HStack(alignment: .top, spacing: 10) {
                    AvatarView(agent: n.agent, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.subheadline)
                        if let b = n.body { Text(b).font(.caption).foregroundStyle(.secondary) }
                        // The time and the button share the last line, so the title and the text keep the row's
                        // width: beside them the button took a third of it and they wrapped early. Under each
                        // other when one line is too narrow (the largest text sizes).
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                clock(n)
                                Spacer(minLength: 8)
                                wrongButton(n)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                clock(n)
                                wrongButton(n)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Done without you")
        .task { await load() }
        .refreshable { await load() }
        .alert("What was wrong?", isPresented: Binding(get: { wrong != nil }, set: { if !$0 { wrong = nil } })) {
            TextField("Optional", text: $wrongText)
            Button("Send to \(wrong.flatMap { store.agent($0.agent)?.name } ?? "the bot")") {
                if let n = wrong {
                    let text = wrongText
                    let at = notes.firstIndex { $0.id == n.id }
                    notes.removeAll { $0.id == n.id }
                    // Not sent: the line comes back where it was, so it can be reported again.
                    store.perform("Sent: it will undo it and learn from it", undo: {
                        if let at, !notes.contains(where: { $0.id == n.id }) { notes.insert(n, at: min(at, notes.count)) }
                    }) {
                        try await API.post("v1/notes/wrong", ["id": n.id, "text": text])
                    }
                }
                wrong = nil
            }
            Button("Cancel", role: .cancel) { wrong = nil }
        } message: {
            Text(wrong?.title ?? "")
        }
    }

    private func clock(_ n: Note) -> some View {
        Text(Ago.clock(n.created_at)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
    }

    /// Neutral, like the rest of the app: blue buttons took over a list that is only read. Small on screen and
    /// 44 points to the finger: the padding that makes the target is taken back from the layout.
    private func wrongButton(_ n: Note) -> some View {
        Button { wrong = n; wrongText = "" } label: {
            Text("That's wrong")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -8)
    }

    private func load() async {
        do {
            notes = try await API.get("v1/know", as: KnowList.self).notes
            failed = false
        } catch {
            // A refresh that fails keeps what is on screen.
            failed = true
        }
        loaded = true
    }
}

/// The width the app has on screen: its window, else the screen it is on.
@MainActor
enum ScreenSize {
    static var width: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.keyWindow?.bounds.width ?? scene?.screen.bounds.width ?? 390
    }
}

/// "Sending", then "Done" (or what failed), at the bottom of every screen; Undo for Done and Not now.
struct ToastBar: View {
    @EnvironmentObject var store: Store
    /// How far it sits above the bottom when something is under it: the Review button on home, the buttons in
    /// Review. It grows with the text size, as those do.
    @ScaledMetric(relativeTo: .subheadline) private var lift: CGFloat = 74
    /// A screen that knows what is under the bar passes its own distance: `ToastBar(bottom: 12)`.
    private let fixedBottom: CGFloat?
    /// The app-wide bar draws nothing while a chat is open: the chat has its own, placed above its composer,
    /// where it pushes the last lines up instead of covering the quick replies or the working line.
    private let yieldsToChat: Bool

    init(bottom: CGFloat? = nil, yieldsToChat: Bool = false) { fixedBottom = bottom; self.yieldsToChat = yieldsToChat }

    private var shown: Store.Toast? {
        if yieldsToChat, store.currentAgent != nil, !store.path.isEmpty { return nil }
        return store.toast
    }

    /// Home with no Review button has nothing to clear, so the bar sits near the bottom there.
    private var bottom: CGFloat {
        if let fixedBottom { return fixedBottom }
        return store.path.isEmpty && store.needs.isEmpty && !store.showReview ? 20 : lift
    }

    var body: some View {
        Group {
            if let t = shown {
                HStack(spacing: 10) {
                    if t.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: t.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(t.failed ? .red : .green) }
                    Text(t.text).font(.subheadline.weight(.medium)).lineLimit(3)
                    if let id = t.undo {
                        Button("Undo") { store.undoAction(id) }
                            .font(.subheadline.weight(.semibold))
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
                // Frosted enough that the rows under it never compete with its text.
                .glassEffect(.regular.tint(Color(.systemBackground).opacity(0.72)).interactive(), in: .capsule)
                .padding(.horizontal, 16)
                .padding(.bottom, bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: shown)
    }
}

/// While the server cannot be reached: the screens keep the last data and say how old it is. When the server
/// answers but refuses the token, waiting will not help, so the pill says so and opens the connect screen.
struct OfflinePill: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if !store.online {
            Group {
                if store.refused {
                    Button { store.showConnect = true } label: {
                        Label("Token refused · pair again", systemImage: "lock.slash")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Label(Self.text(since: store.lastSync, now: context.date), systemImage: "wifi.slash")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// "Offline · updated just now", "Offline · updated 5m ago", or "reconnecting" when nothing came since launch.
    static func text(since last: Date?, now: Date) -> String {
        guard let last else { return "Offline · reconnecting" }
        let s = max(0, Int(now.timeIntervalSince(last)))
        if s < 60 { return "Offline · updated just now" }
        if s < 3600 { return "Offline · updated \(s / 60)m ago" }
        if s < 86400 { return "Offline · updated \(s / 3600)h ago" }
        return "Offline · updated \(s / 86400)d ago"
    }
}

/// Search across every bot's chat and every card (server: /v1/search). The rows only show what `SearchModel`
/// holds; home runs the search.
struct SearchResults: View {
    let query: String
    @ObservedObject var model: SearchModel
    @EnvironmentObject var store: Store

    struct Hit: Codable, Identifiable, Hashable { let id: String; let agent: String?; let role: String; let at: String; let snippet: String }
    struct Result: Codable { let messages: [Hit]; let cards: [Card] }

    /// The cards found, without the ones acted on since: hidden while the action is on its way, and for good once
    /// home no longer lists them. A card whose action failed is back in home's list, and so back here.
    private var cards: [Card] {
        model.cards.filter { c in
            !store.doneLocally.contains(c.id) && !(model.acted.contains(c.id) && !(store.home?.needs.contains { $0.id == c.id } ?? false))
        }
    }

    var body: some View {
        // One row while it loads, so the list is never empty during a search.
        if model.loading && model.cards.isEmpty && model.messages.isEmpty {
            Section {
                HStack(spacing: 10) {
                    // A new spinner per search: one kept from an earlier row stays still.
                    ProgressView().id(query)
                    Text("Searching").foregroundStyle(.secondary)
                }
            }
        }
        if !cards.isEmpty {
            Section("Cards") { ForEach(cards) { CardRow(card: $0) } }
        }
        if !model.messages.isEmpty {
            Section("Messages") {
                ForEach(model.messages) { m in
                    Button { if let a = m.agent { store.open(agent: a) } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            AvatarView(agent: m.agent ?? store.chiefId, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(m.role == "user" ? "You to \(store.agent(m.agent ?? "")?.name ?? "")" : store.agent(m.agent ?? "")?.name ?? "")
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Ago.short(m.at)).font(.caption2).foregroundStyle(.tertiary)
                                }
                                Text(m.snippet).font(.subheadline).foregroundStyle(.primary).lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                        // The whole row opens the chat, its empty parts too, like a card row.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !model.loading && cards.isEmpty && model.messages.isEmpty {
            if model.failed {
                Label(store.online ? "Search did not answer. Try again in a moment." : "Search needs the server, and it cannot be reached right now.",
                      systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing found for \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
            }
        }
    }
}

/// One search for the whole list. It used to be a task on the rows themselves, and a modifier on a group in a
/// list goes to each of its rows: every row on screen sent its own copy of the request each time the query
/// changed, and a search with no result once went round forever between "Searching" and "Nothing found".
@MainActor
final class SearchModel: ObservableObject {
    @Published private(set) var messages: [SearchResults.Hit] = []
    @Published private(set) var cards: [Card] = []
    @Published private(set) var loading = true
    /// The search request did not get an answer: said plainly, never shown as "nothing found".
    @Published private(set) var failed = false
    /// Counts the tries after a failure, so the search runs again when the server is back.
    @Published private(set) var attempt = 0
    /// The query the results on screen answer.
    private var answered: String?
    /// Cards acted on (Done, Not now, an answer) since these results came: see `SearchResults.cards`.
    @Published private(set) var acted: Set<String> = []

    func noteActed(_ ids: Set<String>) {
        if !ids.isSubset(of: acted) { acted.formUnion(ids) }
    }

    /// Called from one task on home's list, restarted when the query changes.
    func run(_ query: String) async {
        // Back on the query already answered (typed on, then deleted): what is held is the answer.
        guard answered != query else {
            if loading { loading = false }
            return
        }
        loading = true
        // Typing on cancels this one before it asks.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // Spaces, "&" and "+" in what was typed must not end or change the query string.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        do {
            let r: SearchResults.Result = try await API.get("v1/search?q=\(q)")
            // An answer that comes after the query changed is not shown: the next one is on its way.
            guard !Task.isCancelled else { return }
            messages = r.messages; cards = r.cards
            // Only what is still on its way counts against these fresh results.
            acted = Store.shared.doneLocally
            failed = false
        } catch {
            // Typing on cancels the request: the next one answers.
            if Task.isCancelled { return }
            failed = true
            messages = []; cards = []
        }
        answered = query
        loading = false
    }

    /// The search field was emptied: the next search starts from an empty list.
    func clear() {
        guard answered != nil || !loading else { return }
        messages = []; cards = []
        failed = false
        loading = true
        answered = nil
    }

    /// The server is back: ask again what could not be asked.
    func retry() {
        guard failed, answered != nil else { return }
        answered = nil
        attempt += 1
    }
}
