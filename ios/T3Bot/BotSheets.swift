import SwiftUI

/// Edit a bot: name, one-line description, what it does (sent to the bot so it updates its own instructions),
/// face colors with a live preview, hidden or not, group members, and its routines (T3 scheduled tasks).
struct EditBotSheet: View {
    let agent: Agent
    var routines: [Routine]
    var onSaved: () async -> Void
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var job = ""
    @State private var skin = ""
    @State private var hidden = false
    @State private var members: Set<String> = []
    @State private var rows: [Routine] = []
    @State private var loaded = false
    @State private var error: String?

    private var isGroup: Bool { agent.kind == "group" }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanJob: String { job.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something here differs from the bot as saved: a swipe down must not throw it away.
    private var changed: Bool {
        loaded && (name != agent.name || role != agent.role || !cleanJob.isEmpty || skin != agent.face.skin
                   || hidden != agent.hidden || members != Set(agent.members))
    }

    private var canSave: Bool { !cleanName.isEmpty && (!isGroup || members.count >= 2) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        // The face at rest, as in New bot: this is where the skin is chosen. A bot that is
                        // writing shows a blinking caret instead of eyes, which hides half of what a skin changes.
                        LiveFace(face: Face(skin: skin.isEmpty ? agent.face.skin : skin), size: 120, blinks: false)
                            .frame(width: 120, height: 120)
                            .accessibilityHidden(true)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                // The faces right here, as in New bot, instead of a row that opens a list.
                Section {
                    SkinStrip(selection: $skin, suggested: agent.face.skin)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } header: { ListHeader(text: "Face") }
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } header: { ListHeader(text: "Name") }
                Section {
                    TextField("One line under its name", text: $role, axis: .vertical).lineLimit(1...3)
                        // A rounded rectangle, not the row's capsule: wrapped text crowded its round ends.
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } header: { ListHeader(text: "Role") }
                Section {
                    TextField("Tell it what it should do from now on", text: $job, axis: .vertical).lineLimit(2...8)
                        // A rounded rectangle, not the row's capsule: wrapped text crowded its round ends.
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } header: {
                    ListHeader(text: "New instruction")
                } footer: {
                    Text("Sent to \(agent.name) in its thread; it updates its own instructions so the change lasts.")
                }
                if isGroup {
                    Section {
                        ForEach(store.home?.agents.filter { $0.kind != "group" && $0.id != agent.id } ?? []) { a in
                            MemberRow(agent: a, on: members.contains(a.id)) {
                                if members.contains(a.id) { members.remove(a.id) } else { members.insert(a.id) }
                            }
                        }
                    } header: {
                        Text("Members")
                    } footer: {
                        if members.count < 2 { Text("A group needs at least two bots.") }
                    }
                }
                if !rows.isEmpty {
                    Section {
                        ForEach($rows) { $r in
                            Toggle(isOn: Binding(get: { r.enabled }, set: { v in r.enabled = v; toggle(r.id, v) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.subheadline)
                                    Text(r.when + (r.lastRunStatus.map { " · last run \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        ListHeader(text: "Routines")
                    } footer: {
                        Text("These are T3 scheduled tasks. To add one, ask \(agent.name) in the chat, for example \"every Sunday at 18:00, tell me...\".")
                    }
                }
                if agent.id != store.chiefId {
                    Section { Toggle("Hide from the home screen", isOn: $hidden) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!canSave) }
            }
            .onAppear {
                // Once: this also runs when coming back from the skin list, and must not undo what was picked there.
                guard !loaded else { return }
                name = agent.name; role = agent.role; hidden = agent.hidden; members = Set(agent.members); rows = routines
                skin = agent.face.skin
                loaded = true
            }
            .task {
                // Opened before the chat had loaded (or from a place that has no chat): fetch the routines here.
                guard routines.isEmpty else { return }
                await store.loadTimeline(agent.id)
                if rows.isEmpty { rows = store.timelines[agent.id]?.routines ?? [] }
            }
        }
        .interactiveDismissDisabled(changed)
    }

    private func toggle(_ id: String, _ on: Bool) {
        Haptics.select()
        error = nil
        Task {
            do { try await API.post("v1/routines/enabled", ["id": id, "enabled": on]) }
            catch {
                Haptics.error()
                self.error = "The routine was not changed: \(error.localizedDescription)"
                if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].enabled = !on }
            }
        }
    }

    private func save() {
        let name = cleanName
        var body: [String: Any] = [
            "name": name, "role": role.trimmingCharacters(in: .whitespacesAndNewlines), "hidden": hidden,
            "face": ["skin": skin.isEmpty ? agent.face.skin : skin],
        ]
        if !cleanJob.isEmpty { body["job"] = cleanJob }
        if isGroup { body["members"] = Array(members) }
        let id = agent.id
        let onSaved = self.onSaved
        dismiss()
        store.perform("Saved \(name)", undo: {}) {
            try await API.post("v1/agents/\(id)/edit", body, patient: true)
            URLCache.shared.removeAllCachedResponses()
            await onSaved()
        }
    }
}

/// A bot that can be in a group: tap to put it in or take it out.
private struct MemberRow: View {
    let agent: Agent
    let on: Bool
    var dimmed = false
    let tap: () -> Void

    var body: some View {
        Button {
            Haptics.select()
            tap()
        } label: {
            HStack {
                AvatarView(agent: agent.id, size: 28)
                // The colour itself: inside a button, the `.primary` style means the button's tint, and the
                // names came out blue, like links.
                Text(agent.name).foregroundStyle(Color.primary)
                Spacer()
                if on { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.4 : 1)
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// What was typed for a bot whose creation failed. The sheet closes as soon as Create is pressed; if the
/// server then says no, the next time the sheet opens it is filled in again, with the reason.
@MainActor
private enum NewBotStash {
    struct Kept {
        var kind: String
        var name: String
        var job: String
        var skin: String
        var members: Set<String>
        var reason: String
    }

    static var failed: Kept?
}

/// A new bot (its own T3 thread with a job) or a group chat between bots.
struct NewBotSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "bot"
    @State private var name = ""
    @State private var job = ""
    @State private var skin = ""
    @State private var members: Set<String> = []
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var field: Field?
    enum Field { case name, job }

    private static let most = 6
    /// Typing a name or a job: the face looks like it is writing it down.
    private var typing: Bool { field != nil && !(field == .name ? cleanName : cleanJob).isEmpty }
    /// A face no other bot wears, shown until one is picked (and what the bot gets if none is).
    private var suggested: String { BotBook.freeSkin(used: (store.home?.agents ?? []).map(\.face.skin)) }
    private var shownSkin: String { skin.isEmpty ? suggested : skin }
    private var bots: [Agent] { store.home?.agents.filter { $0.kind != "group" } ?? [] }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanJob: String { job.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    Text("Bot").tag("bot")
                    Text("Group chat").tag("group")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                if kind == "bot" {
                    // The bot appears as it is made: its face, alive, with its name under it as you type.
                    Section {
                        // The name is typed once, in its field; the face watches you type it.
                        // Large enough to be the bot, small enough that the fields sit above the Create bar.
                        LiveFace(face: Face(skin: shownSkin), size: 76, state: typing ? .typing : .idle, blinks: false)
                            .frame(width: 76, height: 76)
                            .id(shownSkin)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            .frame(maxWidth: .infinity)
                            .animation(.spring(duration: 0.35, bounce: 0.3), value: shownSkin)
                            .accessibilityHidden(true)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                        SkinStrip(selection: $skin, suggested: suggested)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    } header: { ListHeader(text: "Face") }
                }
                Section {
                    TextField(kind == "bot" ? "e.g. Research" : "e.g. Launch week", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($field, equals: .name)
                } header: { ListHeader(text: "Name") }
                Section {
                    TextField(kind == "bot" ? "e.g. Watches my inbox and tells me what needs a reply" : "Optional", text: $job, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($field, equals: .job)
                        // A rounded rectangle, not the row's capsule: wrapped text crowded its round ends.
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } header: {
                    ListHeader(text: kind == "bot" ? "What it does" : "What the group is for")
                } footer: {
                    if kind == "bot" { Text("Its first instructions. You can change them later from its chat.") }
                }
                if kind == "group" {
                    Section {
                        if bots.count < 2 {
                            Text("A group needs at least two bots. Create them first.").foregroundStyle(.secondary)
                        }
                        ForEach(bots) { a in
                            let on = members.contains(a.id)
                            MemberRow(agent: a, on: on, dimmed: !on && members.count >= Self.most) {
                                if on { members.remove(a.id) } else if members.count < Self.most { members.insert(a.id) }
                            }
                        }
                    } header: {
                        Text("Members")
                    } footer: {
                        Text("Two to six bots.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .scrollDismissesKeyboard(.interactively)
            // The Bot / Group chat switch right under the title, not a band lower; the last hint clears Create.
            .contentMargins(.top, 4, for: .scrollContent)
            .contentMargins(.bottom, 28, for: .scrollContent)
            // Create within thumb reach, on its own bar: the form scrolls under it, never through it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button { create() } label: {
                    // Says what is missing while it cannot create.
                    Text(ready ? (kind == "bot" ? "Create bot" : "Create group")
                         : cleanName.isEmpty ? "Add a name to create"
                         : kind == "bot" ? "Say what it does to create" : "Pick at least two bots")
                        .frame(maxWidth: .infinity)
                }
                    .mainButton()
                    .controlSize(.large)
                    .disabled(!ready)
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGroupedBackground).ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .top) { Divider().opacity(0.5) }
            }
            .navigationTitle(kind == "bot" ? "New bot" : "New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                // The last one did not get created: here it is again, nothing to type twice.
                if let f = NewBotStash.failed {
                    NewBotStash.failed = nil
                    kind = f.kind; name = f.name; job = f.job; skin = f.skin; members = f.members
                    error = "\(f.name) was not created: \(f.reason)"
                }
            }
        }
        .interactiveDismissDisabled(!cleanName.isEmpty || !cleanJob.isEmpty)
    }

    private var ready: Bool {
        !cleanName.isEmpty && (kind == "bot" ? !cleanJob.isEmpty : members.count >= 2)
    }

    /// The sheet closes at once and the bar at the bottom follows the creation (a new T3 thread takes a moment).
    private func create() {
        let name = cleanName
        let kept = NewBotStash.Kept(kind: kind, name: name, job: cleanJob, skin: skin, members: members, reason: "")
        var body: [String: Any] = ["kind": kind, "name": name, "job": cleanJob]
        if kind == "group" { body["members"] = Array(members) } else { body["face"] = ["skin": shownSkin] }
        let store = self.store
        let server = Connection.current?.url
        let before = Set(store.home?.agents.map(\.id) ?? [])
        dismiss()
        Haptics.tap()
        store.toast = Store.Toast(text: "Creating \(name)", busy: true)
        Task {
            var failed = false
            do {
                var made: String?
                do {
                    made = try await API.post("v1/agents", body, patient: true).id
                } catch let cut as URLError where cut.code == .timedOut || cut.code == .networkConnectionLost {
                    // The line dropped while the server was at work: it finishes the bot anyway. Look for it before
                    // saying it failed, or a second Create would make the same bot twice.
                    for round in 0..<3 where made == nil && server == Connection.current?.url {
                        if round > 0 { try? await Task.sleep(for: .seconds(3)) }
                        await store.refresh()
                        // The server may have shortened the name: a bot that was not there before and carries it.
                        made = store.home?.agents.first { !before.contains($0.id) && !$0.name.isEmpty && name.hasPrefix($0.name) }?.id
                        if !store.online { break }
                    }
                    if made == nil { throw cut }
                }
                // Paired with another server meanwhile: this bot is not on it.
                guard server == Connection.current?.url else { return }
                await store.refresh()
                Haptics.success()
                store.toast = Store.Toast(text: "\(name) is ready")
                if let made { store.open(agent: made) }
            } catch {
                guard server == Connection.current?.url else { return }
                failed = true
                var k = kept
                k.reason = error.localizedDescription
                NewBotStash.failed = k
                Haptics.error()
                store.toast = Store.Toast(text: "Not created: \(error.localizedDescription)", failed: true)
            }
            // Only this message: a newer one in the bar (a send, an Undo) stays.
            let shown = store.toast
            try? await Task.sleep(for: .seconds(failed ? 5 : 2))
            if store.toast == shown { store.toast = nil }
        }
    }
}

/// The skin list as the server last gave it, so a row can name its skin without asking again.
@MainActor
private enum SkinCatalog {
    private(set) static var last: SkinList?

    static func load() async throws -> SkinList {
        let l = try await API.get("v1/skins", as: SkinList.self)
        last = l
        return l
    }

    static func title(_ n: String) -> String? { last?.skins.first { $0.n == n }?.title }
}

/// "Skin: Titanium Gold ›", opening the full catalogue.
struct SkinRow: View {
    @Binding var selection: String
    /// A new bot can go back to "let T3 Bot pick".
    var allowsAutomatic = false
    @State private var title = ""

    var body: some View {
        NavigationLink {
            SkinPicker(selection: $selection, allowsAutomatic: allowsAutomatic)
        } label: {
            HStack {
                Text("Look")
                Spacer()
                if !selection.isEmpty {
                    StoredImage(key: "skin:\(selection)", path: "skin:\(selection)") { Color.clear }
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
                // The colour in plain words ("Blue"), not the series name ("Glaze · Blue").
                Text(selection.isEmpty ? (allowsAutomatic ? "Automatic" : "Choose") : (title.components(separatedBy: " · ").last ?? title))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: selection) {
            guard !selection.isEmpty else { title = ""; return }
            if let t = SkinCatalog.title(selection) { title = t; return }
            _ = try? await SkinCatalog.load()
            title = SkinCatalog.title(selection) ?? ""
        }
    }
}

/// Every BoopFace skin, searchable and filtered by series. Skins other bots already wear are dimmed,
/// so each bot stays easy to tell apart.
struct SkinPicker: View {
    @Binding var selection: String
    var allowsAutomatic = false
    @Environment(\.dismiss) private var dismiss
    @State private var skins: [Skin] = []
    @State private var used: Set<String> = []
    @State private var query = ""
    @State private var series = "All"
    @State private var failed = false

    private var seriesList: [String] {
        var seen: [String] = []
        for s in skins where !seen.contains(s.series) { seen.append(s.series) }
        return seen
    }

    private var shown: [Skin] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return skins.filter { s in
            (series == "All" || s.series == series) &&
            (q.isEmpty || s.title.localizedCaseInsensitiveContains(q) || s.n.hasPrefix(q))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if skins.isEmpty {
                    if failed {
                        VStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark").font(.system(size: 32)).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text("Can't load the skins").font(.headline)
                            Text("The server did not answer.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }.buttonStyle(.glass).padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 64)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 64)
                    }
                } else {
                    chips
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 24)
                    } else {
                        grid
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .searchable(text: $query, prompt: "Search skins")
        .navigationTitle(skins.isEmpty ? "Skins" : "Skins · \(skins.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsAutomatic, !selection.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Automatic") { selection = ""; dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["All"] + seriesList, id: \.self) { name in
                    Button {
                        Haptics.select()
                        series = name
                    } label: {
                        Text(name)
                            .font(.footnote.weight(series == name ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(series == name ? Color(.label) : Color(.secondarySystemFill)))
                            .foregroundStyle(series == name ? Color(.systemBackground) : Color.primary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(series == name ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 12) {
            ForEach(shown) { s in
                let worn = used.contains(s.n) && selection != s.n
                Button {
                    Haptics.select()
                    selection = s.n
                    dismiss()
                } label: {
                    VStack(spacing: 4) {
                        StoredImage(key: "skin:\(s.n)", path: "skin:\(s.n)") {
                            Color(.secondarySystemFill).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .frame(width: 64, height: 64)
                        Text(s.title.components(separatedBy: " · ").last ?? s.title)
                            .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selection == s.n ? Color.primary : Color.clear, lineWidth: 2))
                    .opacity(worn ? 0.4 : 1)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.title)
                .accessibilityValue(worn ? "Worn by another bot" : "")
                .accessibilityAddTraits(selection == s.n ? .isSelected : [])
            }
        }
    }

    private func load() async {
        failed = false
        // What the last visit got shows at once; the fresh list (who wears what) replaces it.
        if skins.isEmpty, let l = SkinCatalog.last { skins = l.skins; used = Set(l.used.compactMap { $0 }) }
        if let l = try? await SkinCatalog.load() {
            skins = l.skins
            used = Set(l.used.compactMap { $0 })
        } else if skins.isEmpty {
            failed = true
        }
    }
}

/// A row of faces to pick from, right under the preview: a dozen that read well small, the suggested one first,
/// and More for all of them.
struct SkinStrip: View {
    @Binding var selection: String
    let suggested: String
    @State private var showAll = false

    private var choices: [String] {
        // Eight that look nothing alike (one each of black, blue, jade, amber, red, lilac, berry, white).
        // One fixed order, the same on New bot and Edit bot; a face outside it goes first.
        var list = ["101", "102", "103", "105", "402", "106", "104", "206"]
        for extra in [selection, suggested] where !extra.isEmpty && !list.contains(extra) { list.insert(extra, at: 0) }
        return Array(list.prefix(8))
    }

    var body: some View {
        let current = selection.isEmpty ? suggested : selection
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(choices, id: \.self) { n in
                    Button {
                        Haptics.select()
                        selection = n
                    } label: {
                        StoredImage(key: "skin:\(n)", path: "skin:\(n)") { Color.clear }
                            .frame(width: 50, height: 50)
                            .padding(4)
                            // Picked: a thin ring in the face's own colour and a small check, not a heavy black ring.
                            // A ring in the text colour: one in the face's own colour vanished on a pale face.
                            .overlay(Circle().strokeBorder(n == current ? Color.primary.opacity(0.75) : Color.clear, lineWidth: 1.5))
                            .overlay(alignment: .bottomTrailing) {
                                if n == current {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 17))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(Color(.systemBackground), Color.primary)
                                        .background(Circle().fill(Color(.systemBackground)).padding(1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Skins.all.first { $0.n == n }?.title ?? "Face \(n)")
                    .accessibilityAddTraits(n == current ? .isSelected : [])
                }
            }
            Button { showAll = true } label: {
                HStack(spacing: 3) {
                    Text("More faces")
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .sheet(isPresented: $showAll) {
            NavigationStack { SkinPicker(selection: $selection, allowsAutomatic: false) }
        }
    }
}
