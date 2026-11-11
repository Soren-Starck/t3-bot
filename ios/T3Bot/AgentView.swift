import PhotosUI
import SwiftUI

/// One agent's conversation: its T3 thread as a chat, its runs folded on top, its question answered inline.
///
/// The bot's face is one live view that moves: it sits in the top bar, and when a message is sent it drops
/// down into the chat where the "Working" line is, works there, and springs back up once its answer has landed.
/// Two invisible slots (top bar, working line) report where they are; the face is drawn over both and slides
/// between them, so it never reloads or flickers.
struct AgentView: View {
    let agentId: String
    @EnvironmentObject var store: Store
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drawn from the store at once (memory or the disk cache); the network only updates it.
    private var tl: Timeline? { store.timelines[agentId] }
    @State private var draft = ""
    @State private var picked: [PhotosPickerItem] = []
    /// The photos waiting in the composer, each with its own id (see `syncAttachments`).
    @State private var attachments: [ChatAttachment] = []
    @State private var showRuns = false
    /// The bot whose details sheet is open. An item, not a flag, so the sheet always has a bot to show.
    @State private var editing: Agent?
    /// The first read of this chat failed and nothing is cached: say so instead of spinning forever.
    @State private var loadFailed = false
    /// Questions answered in this chat a moment ago. The chat's own copy of the cards can lag a few seconds
    /// behind home's, and without this the answered form would flash back until the next read.
    @State private var answeredHere: [String: Date] = [:]
    @State private var showNeeds = false
    @FocusState private var typing: Bool
    @State private var faceFlash: FaceState?
    /// Where the face is: false in the top bar, true down in the chat while the bot works.
    @State private var faceInChat = false
    @State private var returnTask: Task<Void, Never>?
    // Where things are on screen, each measured by the view itself (in the "agentchat" space).
    @State private var headerSlot: CGRect = .zero
    @State private var chatSlot: CGRect?
    @State private var topEdge: CGFloat = 0
    @State private var composerEdge: CGFloat = .infinity
    @State private var bottomEdge: CGFloat = 0
    /// Parked in the top bar because the working line was scrolled away. Set only after it has been out of
    /// view for a moment, so the keyboard sliding in (which moves everything for a quarter second) never bounces it.
    @State private var parked = false
    @State private var parkTask: Task<Void, Never>?
    /// Until the first fresh read of the chat is in: a bot found already working is placed in the chat directly,
    /// with no drop from the top bar. The drop plays only when it starts working while the chat is being watched.
    @State private var opening = true
    /// The next move of the face happens without animation.
    @State private var instantFace = false
    @State private var instantTask: Task<Void, Never>?
    /// Group chat: members seen answering this round, and those that have finished.
    @State private var seenWorking: Set<String> = []
    /// Messages that arrived while the chat was scrolled up; the jump button shows how many.
    @State private var unseen = 0
    /// The chat was scrolled by hand: the opening passes stop pinning it to the bottom.
    @State private var userScrolled = false
    @State private var answered: Set<String> = []
    /// The newest message of the person's own that was in the chat when the last send from this screen began
    /// ("" when there was none, nil when nothing was sent from here). A message counts as landed only after it:
    /// the same words sent twice ("Yes", a quick reply) got no pending bubble the second time.
    @State private var sentAfter: String?
    /// The bot message a quick reply has just answered. Its replies are not offered again while that answer
    /// travels, so a second tap cannot send it twice. Cleared if the send fails.
    @State private var repliedTo: String?

    private static let move = Animation.spring(response: 0.55, dampingFraction: 0.8)
    private static let smallFace: CGFloat = 40
    // The size of a group's working faces: twice the header's read as a different bot.
    private static let bigFace: CGFloat = 48
    private static let space = "agentchat"
    private static let workingId = "working"

    private var bot: Agent? { tl?.agent ?? store.agent(agentId) }
    private var isGroup: Bool { bot?.kind == "group" }

    /// The message just sent, shown once, and only until the real one is in the thread.
    private var outgoing: String? {
        guard let out = store.outgoing[agentId] else { return nil }
        var recent = (tl?.entries ?? [])[...]
        if let mark = sentAfter, let i = recent.lastIndex(where: { $0.id == mark }) { recent = recent[(i + 1)...] }
        let withPhotos = !(store.outgoingImages[agentId] ?? []).isEmpty
        let landed = recent.suffix(8).contains { $0.type == "me" && $0.text == out && (!withPhotos || !($0.images ?? []).isEmpty) }
        return landed ? nil : out
    }

    /// Every send from this screen: notes what was already in the chat, so `outgoing` can tell the new message
    /// from an older one with the same words.
    private func post(_ text: String, images: [Data] = [], onFail: @escaping () -> Void = {}) {
        sentAfter = tl?.entries.last(where: { $0.type == "me" })?.id ?? ""
        store.send(text, to: agentId, images: images, onFail: onFail)
    }
    private var workingNow: Bool { tl?.working == true || outgoing != nil }

    /// The working line is on screen between the two bars.
    private var chatVisible: Bool {
        guard let c = chatSlot else { return false }
        return c.minY >= topEdge - 2 && c.maxY <= composerEdge + 2
    }

    /// Near enough to the bottom that new messages should scroll into view.
    private var atBottom: Bool { bottomEdge <= composerEdge + 80 }

    private var faceState: FaceState {
        if let faceFlash { return faceFlash }
        if faceInChat {
            // What it is doing right now (reading, running, writing...), else its usual working wave.
            let s = bot?.faceState ?? .working
            return [.thinking, .reading, .running, .writing, .web, .delegating].contains(s) ? s : .working
        }
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { return .typing }
        // A sleeping bot wakes up while its chat is open.
        let s = bot?.faceState ?? .idle
        return s == .asleep ? .idle : s
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            messages
                .safeAreaBar(edge: .top, spacing: 0) { topBar }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    // "Sending", "Sent", Undo or what failed: in the flow above the composer, so the chat moves up
                    // for it and the quick replies and the working line stay in view.
                    VStack(spacing: 0) {
                        ToastBar(bottom: 2)
                        composer
                    }
                }
                // No edge effect at the top: the bar itself is opaque, with a hairline under it (a soft edge let text
                // show through, a hard one sliced it).
                .scrollEdgeEffectHidden(true, for: .top)
            faceLayer
        }
        .coordinateSpace(.named(Self.space))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showNeeds) { BotNeedsSheet(agentId: agentId).environmentObject(store) }
        .onChange(of: workingNow) { _, working in
            returnTask?.cancel()
            if isGroup && working { seenWorking = []; answered = [] }
            if opening && outgoing == nil { place(inChat: working); return }
            if working {
                withAnimation(Self.move) { faceInChat = true }
            } else {
                // Wait a moment before going back up, so a run that is only queued does not make it bounce.
                returnTask = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled, !workingNow else { return }
                    withAnimation(Self.move) { faceInChat = false }
                }
            }
        }
        .onChange(of: memberKey) { _, _ in
            guard isGroup else { return }
            for m in memberStates {
                if m.mood == "working" { seenWorking.insert(m.id); answered.remove(m.id) }
                else if seenWorking.contains(m.id) { answered.insert(m.id) }
            }
        }
        .onChange(of: chatVisible) { _, visible in
            parkTask?.cancel()
            if visible {
                if parked { withAnimation(Self.move) { parked = false } }
            } else {
                parkIfHidden()
            }
        }
        .onChange(of: tl?.entries.last?.id) { old, _ in
            // The answer landed (however it was fetched): smile once, and close the Live Activity with its first line.
            guard old != nil, let last = tl?.entries.last, last.type == "agent", tl?.working != true else { return }
            store.endLive(agentId, text: last.text)
            Haptics.soft()
            // VoiceOver says the answer as it lands (nothing is posted when it is off).
            if UIAccessibility.isVoiceOverRunning {
                let said = Markdown.plain(EntryView.withoutImageLines(last.text)).prefix(400)
                AccessibilityNotification.Announcement("\(bot?.name ?? "Bot"): \(said)").post()
            }
            faceFlash = .success
            Task { try? await Task.sleep(for: .seconds(2.5)); if faceFlash == .success { faceFlash = nil } }
        }
        .onChange(of: draft) { _, d in store.saveDraft(d, for: agentId) }

        .onChange(of: store.focusComposer) { _, id in
            if id == agentId { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { typing = true; store.focusComposer = nil } }
        }
        .onAppear {
            if draft.isEmpty, let d = store.drafts[agentId] { draft = d }
            if store.focusComposer == agentId { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { typing = true; store.focusComposer = nil } }
            // Opened while the bot works (cached chat, or home says so): it is already down in the chat.
            if workingNow || store.agent(agentId)?.mood == "working" { place(inChat: true); parkIfHidden(after: 0.6) }
        }
        .task {
            // The store's loop keeps this chat fresh while it is open; this is the first read.
            store.currentAgent = agentId
            store.markSeen(agentId)
            await load()
            if tl == nil { loadFailed = true }
            // The fresh read decides where the face starts, still without a drop.
            if workingNow != faceInChat { place(inChat: workingNow) }
            opening = false
            // A chat that opens with the working line out of view (a long question under it) never sees that
            // line leave the screen, so nothing else would park the face: it would be in neither place.
            parkIfHidden(after: 0.6)
            #if DEBUG
            if store.debugSheet == "edit-\(agentId)" { store.debugSheet = nil; editing = bot }
            #endif
        }
        #if DEBUG
        // Screen checks: the edit sheet asked for by a debug link, whenever it arrives (not only after the first load).
        .onChange(of: store.debugSheet) { _, w in
            if w == "edit-\(agentId)" { store.debugSheet = nil; editing = bot }
        }
        .onAppear {
            if store.debugSheet == "edit-\(agentId)" {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    if store.debugSheet == "edit-\(agentId)" { store.debugSheet = nil; editing = bot }
                }
            }
        }
        #endif
        .onChange(of: tl == nil) { _, missing in if !missing { loadFailed = false } }
        .onChange(of: store.doneLocally) { old, new in
            // An answer that did not go through brings its card back (the store undoes it and says why):
            // show the form again at once, with what was picked.
            for id in old.subtracting(new) where answeredHere[id] != nil {
                if store.toast?.failed == true { answeredHere[id] = nil }
            }
        }
        .onDisappear {
            store.markSeen(agentId)
            if store.currentAgent == agentId { store.currentAgent = nil }
        }
        .sheet(item: $editing) { a in
            EditBotSheet(agent: a, routines: tl?.routines ?? []) { await load() }.environmentObject(store)
        }
    }

    /// Puts the face in the chat or the top bar at once, with no drop or climb (used while the chat opens).
    private func place(inChat: Bool) {
        instantFace = true
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { faceInChat = inChat; parked = false }
        // Long enough for the working line to be measured and the face to sit on it, then moves animate again.
        instantTask?.cancel()
        instantTask = Task { try? await Task.sleep(for: .seconds(0.8)); if !Task.isCancelled { instantFace = false } }
    }

    /// Parks the face in the top bar once the working line has been out of view for a moment.
    private func parkIfHidden(after delay: Double = 0.35) {
        parkTask?.cancel()
        parkTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, faceInChat, !parked, chatSlot != nil, !chatVisible else { return }
            withAnimation(Self.move) { parked = true }
        }
    }

    /// Where the chat rests when it opens: on its last message, or, when the bot's own question waits there,
    /// on the top of that question. A form taller than the screen would otherwise open on its Send button,
    /// with the question itself hidden above the top bar. A form that fits ends at the bottom either way.
    private func settle(_ proxy: ScrollViewProxy) {
        if let q = ownQuestions.first {
            proxy.scrollTo(faceInChat && !isGroup ? Self.workingId : Self.formId(q), anchor: .top)
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private static func formId(_ card: Card) -> String { "question-" + card.id }

    /// The one live face, drawn over everything at the slot it belongs to. In the chat only while the working
    /// line is on screen between the two bars; scrolled away, it waits in the top bar.
    @ViewBuilder
    private var faceLayer: some View {
        if let bot, !isGroup, headerSlot.width > 0 {
            let inView = faceInChat && chatSlot != nil && !parked
            let r = (inView ? chatSlot : nil) ?? headerSlot
            // Drawn at the chat size and scaled down in the top bar, so it stays sharp; it grows as it lands.
            // Held expressions here too: in a still, the looping ones (one eye, no eyes) looked broken; the dots
            // beside it say it is working.
            LiveFace(face: bot.face, size: Self.bigFace, state: faceState, calm: true)
                .frame(width: Self.bigFace, height: Self.bigFace)
                .scaleEffect(inView ? 1 : Self.smallFace / Self.bigFace)
                .position(x: r.midX, y: r.midY)
                // Reduce Motion: the face changes place without the drop and the climb.
                .animation(instantFace || reduceMotion ? nil : Self.move, value: inView)
                .allowsHitTesting(false)
        }
    }

    private var topBar: some View {
        VStack(spacing: 0) {
            header
            needsBar
        }
        // An opaque bar with a hairline under it, like a classic navigation bar: messages pass cleanly behind it
        // (a fade, or a hard scroll edge, left half-visible lines that read as broken).
        .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Divider() }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { topEdge = $0 }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack, not lazy: a lazy stack anchored at the bottom guesses the height of long
                // messages wrong and could open on an empty screen. A chat holds at most its last 60 messages.
                VStack(alignment: .leading, spacing: 12) {
                    if let runs = tl?.runs, !runs.isEmpty { runsBlock(runs) }
                    ForEach(Self.fold(tl?.entries ?? [])) { item in
                        switch item {
                        case let .entry(e): EntryView(entry: e, group: isGroup ? bot?.members ?? [] : [])
                            // A sent message is already on screen (the pending bubble): it swaps in place.
                            .transition(e.type == "me" ? AnyTransition.identity
                                        : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        case let .reply(e, autos): EntryView(entry: e, group: isGroup ? bot?.members ?? [] : [], autos: autos)
                        case let .automatic(list): AutomaticGroup(entries: list)
                        case let .day(label): DaySeparator(label: label)
                        }
                    }
                    if let out = outgoing {
                        // The photos being sent show at once, from this phone, instead of "[1 photo]".
                        let photos = (store.outgoingImages[agentId] ?? []).map { EntryImage(path: "local:\($0)", alt: "") }
                        EntryView(entry: Entry(id: "pending", type: "me", text: out, at: "", steps: [], working: nil, images: photos.isEmpty ? nil : photos))
                            .opacity(0.75)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .identity))
                    }
                    ForEach(store.failed[agentId] ?? [], id: \.clientId) { f in failedBubble(f) }
                    if faceInChat || (isGroup && workingNow) {
                        workingLine.id(Self.workingId).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }
                    if !workingNow, !faceInChat, let last = tl?.entries.last, last.type == "agent", last.id != repliedTo, !replies(for: last).isEmpty { quickReplies(replies(for: last)) }
                    // Only the question this bot is asking in this conversation stays in the chat; everything else
                    // that needs an answer lives in the bar on top. Straight on the chat, as in the card sheet:
                    // its options are tiles already, and a panel around them made boxes inside a box.
                    ForEach(ownQuestions) { card in
                        QuestionForm(card: card) { answeredHere[card.id] = Date() }
                            .padding(.horizontal, 2).padding(.top, 4)
                            .id(Self.formId(card))
                    }
                    if tl == nil {
                        if loadFailed {
                            ChatLoadFailed(online: store.online) {
                                loadFailed = false
                                Task { await load(); if tl == nil { loadFailed = true } }
                            }
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 40)
                        }
                    }
                    if let tl, tl.agent.threadMissing == true {
                        // The bot's thread was deleted in T3 Code: said once, plainly, instead of an empty chat.
                        Text("\(tl.agent.name)'s thread no longer exists in T3 Code. Hide this bot, or make a new one.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if let tl, tl.entries.isEmpty, outgoing == nil, (store.failed[agentId] ?? []).isEmpty, !workingNow { welcome(tl.agent) }
                    Color.clear.frame(height: 1).id("bottom")
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { bottomEdge = $0 }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // A new message slides in; the first read of the chat just appears.
                .animation(opening ? nil : .spring(duration: 0.35, bounce: 0.15), value: tl?.entries.last?.id)
            }
            .scrollDismissesKeyboard(.interactively)
            // Like Messages: the chat opens at its last message and stays pinned to the bottom when the keyboard
            // (or anything else) changes the space it has.
            // A long chat opens on its end; a short one sits under the header (at the foot it left an empty band).
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onChange(of: tl?.entries.last?.id) { old, _ in
                // First load: jump. Later messages glide in, unless the chat is scrolled up for reading (then it stays
                // there and the jump button counts them), except a message just sent, which always comes into view.
                if old == nil { settle(proxy); return }
                if atBottom || tl?.entries.last?.type == "me" { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                else { unseen += 1 }
            }
            .onChange(of: atBottom) { _, bottom in if bottom { unseen = 0 } }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && tl != nil && !opening {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(duration: 0.35)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .overlay(alignment: .topTrailing) {
                                if unseen > 0 {
                                    Text("\(unseen)").font(.caption2.weight(.bold)).monospacedDigit()
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.blue)).foregroundStyle(.white)
                                        .offset(x: 4, y: -4)
                                }
                            }
                            // The circle stays 40 pt; the finger gets 44.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12).padding(.bottom, 8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(unseen > 0 ? "\(unseen) new, jump to latest" : "Jump to latest")
                }
            }
            .animation(.spring(duration: 0.3), value: atBottom)
            .onAppear {
                settle(proxy)
                DispatchQueue.main.async { settle(proxy) }
            }
            // The floating bars measure themselves after the first layout, which can leave the last message behind
            // the composer (seen on a real iPhone): settle at the bottom a few times while the chat opens, unless
            // the chat has been scrolled by hand.
            .task {
                for d in [0.05, 0.2, 0.45, 0.9] {
                    try? await Task.sleep(for: .seconds(d))
                    if !userScrolled { settle(proxy) }
                }
            }
            .onScrollPhaseChange { _, phase in if phase == .interacting { userScrolled = true } }
            .onChange(of: outgoing) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: store.toast != nil) { _, on in
                // The bar at the bottom takes its room above the composer: the last line stays in view.
                guard on, atBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation(.spring(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: faceInChat) { _, down in
                guard down else { return }
                parked = false
                if instantFace { settle(proxy) } else { withAnimation(Self.move) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: typing) { _, on in
                guard on else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // Only for the composer. A field of the question form keeps its own place on screen (the
                // scroll view brings it above the keyboard); a jump to the bottom would take it out of view.
                guard typing else { return }
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Back, the face's home slot, the name, the menu.
    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                // The circle stays 40 pt; the finger gets 44 (the bar's padding gives the 2 pt back).
                Image(systemName: "chevron.backward").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            if isGroup {
                AvatarView(agent: agentId, size: 40)
            } else {
                // While the live face works down in the chat, its still picture keeps the bar's place: the top bar
                // always says whose chat this is.
                ZStack {
                    if let bot, faceInChat, chatSlot != nil, !parked {
                        StoredImage(key: "skin:\(bot.face.skin)", path: "skin:\(bot.face.skin)") { Color.clear }
                            .padding(3)
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 40, height: 40)
                .animation(Self.move, value: faceInChat && chatSlot != nil && !parked)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { headerSlot = $0 }
            }
            // Tap the name for the bot's details (like a contact in Messages).
            Button { editing = bot } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot?.name ?? "").font(.headline).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 4) {
                        // At work: a live dot before what it is doing; idle: its role, plain.
                        if faceInChat { Circle().fill(Color.green).frame(width: 6, height: 6) }
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(bot == nil)
            .accessibilityHint("Shows the bot's details")
            Spacer(minLength: 8)
            Menu {
                Button { editing = bot } label: { Label("Edit bot", systemImage: "slider.horizontal.3") }
                    .disabled(bot == nil)
                if let link = bot?.t3Link, let url = URL(string: link) {
                    Button { openURL(url) } label: { Label("Open in T3 Code", systemImage: "arrow.up.right.square") }
                }
                Button { Haptics.tap(); Task { await refreshByHand() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .tint(.primary)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    /// Under the name: what the bot is doing while it works, else its role; "Not connected" while the server
    /// cannot be reached, so a message that will not leave is no surprise.
    private var subtitle: String {
        if faceInChat { return bot?.activityText ?? "Working" }
        if !store.online { return "Not connected" }
        return Self.shortRole(bot?.role ?? "")
    }

    /// The role's first clause ("Owns the marketing site"), so the top bar never ends in "…".
    static func shortRole(_ role: String) -> String {
        let cut = role.firstIndex { ",;:(".contains($0) } ?? role.endIndex
        let head = role[..<cut].replacingOccurrences(of: " - ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? role : head
    }

    /// The replies the server sends for the bot's last message: the bot's own, else the ones saved in
    /// Settings when the message asks something. With none, Yes/No when it ends on a question.
    private func replies(for e: Entry) -> [String] {
        var out = e.suggestions ?? []
        if out.isEmpty, e.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { out = ["Yes", "No"] }
        return out
    }

    /// One-tap answers under the bot's last message.
    private func quickReplies(_ list: [String]) -> some View {
        // One quiet row of whole suggestions: as many as fit, never one cut mid-word.
        ViewThatFits(in: .horizontal) {
            ForEach((1...max(list.count, 1)).reversed(), id: \.self) { n in
                HStack(spacing: 8) { ForEach(Array(list.prefix(n)), id: \.self) { chip($0) } }
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func chip(_ r: String) -> some View {
        Button {
            faceFlash = .affirm
            Task { try? await Task.sleep(for: .seconds(1.2)); if faceFlash == .affirm { faceFlash = nil } }
            repliedTo = tl?.entries.last?.id
            post(r) { repliedTo = nil }
        } label: {
            Text(r).font(.subheadline).lineLimit(1)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
                .foregroundStyle(.primary)
                // 44 points to the finger; the room is taken back from the layout, so nothing moves.
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .padding(.vertical, -5)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Sends this reply")
    }

    /// Where the face sits while the bot works; a group shows each member instead.
    @ViewBuilder
    private var workingLine: some View {
        if isGroup {
            groupWorkingLine
        } else {
            HStack(spacing: 10) {
                Color.clear.frame(width: Self.bigFace, height: Self.bigFace)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { chatSlot = $0 }
                    .onDisappear { chatSlot = nil }
                // The top bar already says what it is doing ("Running a command"): here, what it last said it was
                // doing, else that same word once, beside the dots.
                HStack(spacing: 6) {
                    ChatTypingDots()
                    // The header already says "Working": here only what it last said it was doing, else just the dots.
                    Text(lastStep ?? (outgoing != nil && tl?.working != true ? "Sending" : ""))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: lastStep ?? bot?.activity ?? "")
                }
            }
            .padding(.vertical, 2)
            // One spoken line: who works and on what (the dots and an empty text said nothing).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(workingSpoken)
        }
    }

    /// The working line, as VoiceOver says it.
    private var workingSpoken: String {
        let name = bot?.name ?? "The bot"
        if let step = lastStep { return "\(name) is working. \(step)" }
        return outgoing != nil && tl?.working != true ? "Sending to \(name)" : "\(name) is working"
    }

    /// The first line of the bot's latest note to itself while it works on the answer.
    private var lastStep: String? {
        guard tl?.working == true, let last = tl?.entries.last, last.type == "agent", last.working == true,
              let step = last.steps.last else { return nil }
        let line = step.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let plain = Markdown.plain(line).trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? nil : plain
    }

    /// The members, live (the chat's own read, else home's).
    private var memberStates: [Agent] {
        if let m = tl?.members, !m.isEmpty { return m }
        return (bot?.members ?? []).compactMap { store.agent($0) }
    }

    private var memberKey: String { memberStates.map { "\($0.id):\($0.mood ?? "")" }.joined(separator: ",") }

    /// A group at work: every member's face in the chat. Those answering animate with what they do, those done
    /// get a check, the others wait dimmed.
    private var groupWorkingLine: some View {
        let members = memberStates
        let typing = members.filter { $0.mood == "working" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(members) { m in
                    let on = m.mood == "working"
                    let done = !on && answered.contains(m.id)
                    LiveFace(face: m.face, size: 48, state: on ? Self.working(m) : .idle, calm: true)
                        .frame(width: 48, height: 48)
                        .overlay(alignment: .bottomTrailing) {
                            if done {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white, .green)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .opacity(on || done ? 1 : 0.4)
                        .scaleEffect(on ? 1 : 0.86)
                        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: on)
                        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: done)
                }
            }
            Text(Self.groupStatus(typing: typing, anyDone: !answered.isEmpty))
                .font(.subheadline).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: typing.map(\.id))
        }
        .padding(.vertical, 2)
    }

    /// What a working face shows: its current activity, else the working wave.
    static func working(_ a: Agent) -> FaceState {
        let s = a.faceState
        return [.thinking, .reading, .running, .writing, .web, .delegating].contains(s) ? s : .working
    }

    static func groupStatus(typing: [Agent], anyDone: Bool) -> String {
        let names = typing.map(\.name)
        switch names.count {
        case 0: return anyDone ? "Putting the answers together" : "Asking the group"
        case 1: return "\(names[0]) is typing"
        default: return names.dropLast().joined(separator: ", ") + " and \(names.last ?? "") are typing"
        }
    }

    enum Item: Identifiable {
        case entry(Entry)
        /// A bot's reply with the automatic updates that followed it, said on its own quiet line.
        case reply(Entry, [Entry])
        case automatic([Entry])
        case day(String)
        var id: String {
            switch self {
            case let .entry(e): return e.id
            case let .reply(e, _): return e.id
            case let .automatic(l): return "auto-" + (l.first?.id ?? "")
            case let .day(label): return "day-" + label
            }
        }
    }

    /// Consecutive automated entries become one foldable line, so the chat reads as the person's own conversation;
    /// a quiet line names the day whenever it changes ("Today", "Yesterday", "Sat 7 Nov").
    static func fold(_ entries: [Entry]) -> [Item] {
        var out: [Item] = []
        var run: [Entry] = []
        var lastDay: String?
        func mark(_ e: Entry) {
            guard let d = Ago.date(e.at) else { return }
            let label = DaySeparator.label(d)
            if label != lastDay { out.append(.day(label)); lastDay = label }
        }
        // Right after a finished reply, the run joins that reply's line (time · steps · automatic updates);
        // anywhere else it keeps a line of its own.
        func close() {
            guard !run.isEmpty else { return }
            if case let .entry(last)? = out.last, last.type == "agent", last.working != true,
               Ago.date(run[0].at).map(DaySeparator.label) == lastDay {
                out[out.count - 1] = .reply(last, run)
            } else {
                if let first = run.first { mark(first) }
                out.append(.automatic(run))
            }
            run = []
        }
        for e in entries {
            if e.isAutomatic { run.append(e); continue }
            close()
            mark(e)
            out.append(.entry(e))
        }
        close()
        return out
    }

    /// A chat with nothing in it yet: who this is, and a first thing to say.
    private func welcome(_ a: Agent) -> some View {
        VStack(spacing: 12) {
            if a.kind == "group" { AvatarView(agent: a.id, size: 84) } else { Color.clear.frame(height: 20) }
            Text(a.name).font(.title2.weight(.semibold))
            Text(a.role).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            quickReplies(a.kind == "group" ? ["What is each of you working on?", "What should I focus on today?"]
                         : ["What can you do?", "What needs me today?", "What did you do lately?"])
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// A message that did not leave: marked, tap to send it again. A long press also offers to change it
    /// (back in the composer, photos included) or to drop it.
    private func failedBubble(_ f: Store.FailedSend) -> some View {
        let photos = f.imageIds.map { EntryImage(path: "local:\($0)", alt: "") }
        return Button {
            retry(f)
        } label: {
            VStack(alignment: .trailing, spacing: 4) {
                EntryView(entry: Entry(id: "failed:" + f.clientId, type: "me", text: f.text, at: "", steps: [], working: nil, images: photos.isEmpty ? nil : photos), menu: false)
                    .opacity(0.6)
                Label("Not sent. Tap to try again", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            Button { retry(f) } label: { Label("Try again", systemImage: "arrow.clockwise") }
            Button { edit(f) } label: { Label("Edit", systemImage: "pencil") }
            if !f.text.isEmpty {
                Button { ChatCopy.text(f.text, store) } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            Button(role: .destructive) {
                withAnimation { store.dropFailed(f, in: agentId) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityHint("Sends the message again")
    }

    private func retry(_ f: Store.FailedSend) {
        store.dropFailed(f, in: agentId)
        sentAfter = tl?.entries.last(where: { $0.type == "me" })?.id ?? ""
        // The same id as the first try: if that one did reach the bot, it is not posted a second time.
        store.send(f.text, to: agentId, images: f.images, clientId: f.clientId)
    }

    /// Back in the composer to be changed: the text (after anything already typed) and the photos.
    private func edit(_ f: Store.FailedSend) {
        store.dropFailed(f, in: agentId)
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = typed.isEmpty ? f.text : f.text.isEmpty ? draft : draft + "\n" + f.text
        for d in f.images {
            attachments.append(ChatAttachment(item: nil, data: d, thumb: UIImage(data: d).map(ChatAttachment.thumbnail)))
        }
        typing = true
    }

    private var threadId: String? { tl?.agent.threadId ?? store.agent(agentId)?.threadId }

    private var ownQuestions: [Card] {
        (tl?.cards ?? []).filter { c in
            guard c.isQuestion, c.threadId == threadId, !store.doneLocally.contains(c.id) else { return false }
            if let at = answeredHere[c.id], Date().timeIntervalSince(at) < 20 { return false }
            return true
        }
    }

    /// Everything else this bot needs from its person, most urgent first.
    private var botNeeds: [Card] {
        store.needs.filter { $0.agent == agentId && !($0.isQuestion && $0.threadId == threadId) }
    }

    /// One slim bar: the count and the most urgent item. Tapping it opens the list in a half sheet.
    @ViewBuilder
    private var needsBar: some View {
        let needs = botNeeds
        if let top = needs.first {
            HStack(spacing: 8) {
                Button { showNeeds = true } label: {
                    HStack(spacing: 8) {
                        // What it waits on you for, in the same word as on home (an approval's button says it).
                        if !top.isApproval { KindTag(card: top) }
                        Text(top.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if needs.count > 1 {
                            Text("+\(needs.count - 1) more").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if !top.isApproval {
                            Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(needs.count) need\(needs.count == 1 ? "s" : "") you. \(top.title)")
                .accessibilityHint("Opens the list")
                // An approval opens its sheet (the command, Approve and Decline): one tap must never deploy
                // something without its context.
                if top.isApproval {
                    Button {
                        Haptics.tap()
                        store.selectedCard = top
                    } label: {
                        Text("Approve").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary))
                            .foregroundStyle(Color(.systemBackground))
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .padding(.vertical, -6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the request, with Approve and Decline")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            // A plain filled card: on glass, the black Approve button washed out to grey and read as disabled.
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator).opacity(0.6), lineWidth: 0.5))
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func load() async {
        await store.loadTimeline(agentId)
    }

    /// Refresh from the menu: says so when it did not work, instead of nothing happening.
    private func refreshByHand() async {
        await load()
        if let why = store.chatProblem[agentId] { store.flash("Not refreshed: \(why)", failed: true) }
    }

    private func runsBlock(_ runs: [RunInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showRuns.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("\(runs.count) automated run\(runs.count == 1 ? "" : "s") in the last day")
                    Image(systemName: showRuns ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                }
                .font(.footnote).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showRuns ? "Hides the runs" : "Shows the runs")
            if showRuns {
                // A line between runs, none trailing after the last one.
                ForEach(Array(runs.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.title) · \(Ago.clock(r.at))").font(.caption.weight(.semibold))
                        Text(r.text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var composer: some View {
        // Photos put back from a message that was not sent count toward the four a message can carry.
        let restored = attachments.filter { $0.item == nil }.count
        return VStack(alignment: .leading, spacing: 6) {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { a in
                        Group {
                            if let img = a.thumb {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Color(.tertiarySystemFill).overlay(ProgressView().controlSize(.small))
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel(a.thumb == nil ? "Photo, loading" : "Photo")
                        .overlay(alignment: .topTrailing) {
                            Button { remove(a) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                    .frame(width: 28, height: 28)
                                    // 44 points to the finger, 28 on screen.
                                    .padding(8)
                                    .contentShape(Rectangle())
                                    .padding(-8)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 8, y: -8)
                            .accessibilityLabel("Remove photo")
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                .animation(.spring(duration: 0.25), value: attachments.map(\.id))
            }
        }
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $picked, maxSelectionCount: max(1, 4 - restored), matching: .images) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(2)
                    .contentShape(Rectangle())
                    .padding(-2)
            }
            .tint(.primary)
            .disabled(restored >= 4)
            .accessibilityLabel("Add photos")
            .onChange(of: picked) { _, items in syncAttachments(items) }
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message \(tl?.agent.name ?? store.agent(agentId)?.name ?? "")", text: $draft, axis: .vertical)
                    .focused($typing)
                    .lineLimit(1...6)
                    .padding(.leading, 14).padding(.vertical, 10)
                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 32, height: 32)
                            // A fixed colour, not the hierarchical one: the glass around it washes that out.
                            .background(Circle().fill(Color(.label)))
                            // The room around the circle belongs to the button: 40 pt to press, not 32.
                            .padding(4)
                            // And 2 more that the layout does not see: 44 in all.
                            .padding(2)
                            .contentShape(Rectangle())
                            .padding(-2)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .accessibilityLabel("Send")
                }
            }
            .frame(minHeight: 40)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            .animation(.spring(duration: 0.25, bounce: 0.3), value: canSend)
        }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { composerEdge = $0 }
    }

    /// Something to send, and every photo ready: a photo still loading would otherwise be left behind.
    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !attachments.contains { $0.data == nil }
    }

    /// Keeps the composer's photos in step with the photo picker. Only a photo that was just added is loaded
    /// (the others keep what they have), a photo taken out of the picker leaves, and one that cannot be read
    /// is dropped from both with a word in the bar, so the strip and the picker never disagree.
    private func syncAttachments(_ items: [PhotosPickerItem]) {
        attachments.removeAll { a in a.item.map { !items.contains($0) } ?? false }
        for item in items where !attachments.contains(where: { $0.item == item }) {
            let new = ChatAttachment(item: item)
            attachments.append(new)
            Task {
                var jpg: Data?
                var thumb: UIImage?
                if let data = try? await item.loadTransferable(type: Data.self) {
                    // Decoding, scaling and encoding a 12 MP photo takes a moment: off the main thread, so the
                    // chat keeps scrolling and typing while the photo loads.
                    let made = await Task.detached(priority: .userInitiated) { () -> (Data?, UIImage?) in
                        guard let img = UIImage(data: data) else { return (nil, nil) }
                        let scaled = img.scaledForUpload()
                        return (scaled.jpegData(compressionQuality: 0.8), ChatAttachment.thumbnail(scaled))
                    }.value
                    jpg = made.0
                    thumb = made.1
                }
                // Removed, or the message sent, while it loaded: nothing to fill in.
                guard let i = attachments.firstIndex(where: { $0.id == new.id }) else { return }
                if let jpg {
                    attachments[i].data = jpg
                    attachments[i].thumb = thumb
                } else {
                    attachments.remove(at: i)
                    picked.removeAll { $0 == item }
                    Haptics.error()
                    let shown = Store.Toast(text: "That photo could not be loaded", failed: true)
                    store.toast = shown
                    try? await Task.sleep(for: .seconds(3))
                    if store.toast == shown { store.toast = nil }
                }
            }
        }
    }

    private func remove(_ a: ChatAttachment) {
        attachments.removeAll { $0.id == a.id }
        if let item = a.item { picked.removeAll { $0 == item } }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let images = attachments.compactMap(\.data)
        guard !text.isEmpty || !images.isEmpty else { return }
        attachments = []
        picked = []
        draft = ""
        store.saveDraft("", for: agentId)
        // Cleared while iOS had an autocorrection pending (the suggestion bar was up), the field gets its text back a
        // moment later: it then looked unsent and a second tap posted it twice. Cleared again when that happens.
        let sentDraft = text
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !sentDraft.isEmpty, draft.trimmingCharacters(in: .whitespacesAndNewlines) == sentDraft {
                    draft = ""
                    store.saveDraft("", for: agentId)
                }
            }
        }
        faceFlash = .affirm
        Task { try? await Task.sleep(for: .seconds(1.2)); if faceFlash == .affirm { faceFlash = nil } }
        post(text, images: images)
    }
}

struct EntryView: View {
    let entry: Entry
    var group: [String] = []
    /// The long-press menu (Copy, Share, Select Text). Off for a bubble that has its own menu.
    var menu = true
    /// Automatic updates that came after this reply, folded into its line.
    var autos: [Entry] = []
    @State private var showSteps = false
    @State private var showAutos = false
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch entry.type {
        case "me":
            // The photos are shown above the bubble, so the bubble does not also say "[1 photo]".
            let mine = Self.withoutImageLines(entry.text, count: entry.images?.isEmpty ?? true)
            let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 5, topTrailingRadius: 18)
            VStack(alignment: .trailing, spacing: 6) {
            if let imgs = entry.images, !imgs.isEmpty { ImageStrip(images: imgs, alignment: .trailing) }
            if !mine.isEmpty {
            HStack {
                Spacer(minLength: 56)
                Text(Markdown.render(mine))
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(shape.fill(Color.primary))
                    .foregroundStyle(Color(.systemBackground))
                    .tint(Color(.systemBackground))
                    .contentShape(.contextMenuPreview, shape)
                    .chatMessageMenu(mine, on: menu)
                    // Whose words these are: the side of the screen says it to the eye only.
                    .accessibilityLabel { label in Text("You said"); label }
            }
            }
            }
        case "auto":
            Text("Automatic: \(entry.text)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 2)
        default:
            VStack(alignment: .leading, spacing: 5) {
                if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let parts = group.isEmpty ? [] : GroupSplit.split(entry.text, members: group.compactMap { store.agent($0) })
                    if parts.isEmpty {
                        bubble(entry.text)
                    } else {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                            let m = p.agent.flatMap { store.agent($0) }
                            HStack(alignment: .bottom, spacing: 8) {
                                if let id = p.agent { AvatarView(agent: id, size: 32) } else { Color.clear.frame(width: 32, height: 1) }
                                VStack(alignment: .leading, spacing: 3) {
                                    if let id = p.agent {
                                        Text(m?.name ?? id).font(.caption.weight(.semibold))
                                            .foregroundStyle(m.map { BotColor.label($0, scheme) } ?? Color.secondary)
                                            .padding(.leading, 4)
                                    }
                                    bubble(p.text, tint: m.map { BotColor.fill($0, scheme) })
                                }
                            }
                        }
                    }
                }
                if let imgs = entry.images, !imgs.isEmpty { ImageStrip(images: imgs, alignment: .leading) }
                HStack(spacing: 10) {
                    if !entry.at.isEmpty { Text(Ago.clock(entry.at)).font(.caption2).foregroundStyle(.tertiary) }
                    if !entry.steps.isEmpty {
                        Button {
                            withAnimation { showSteps.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(entry.steps.count == 1 ? "Worked in 1 step" : "Worked in \(entry.steps.count) steps")
                                Image(systemName: showSteps ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                            // Easier to hit than its text, without moving the rows around it.
                            .padding(.vertical, 10).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .padding(.vertical, -10).padding(.horizontal, -6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.steps.count) step\(entry.steps.count == 1 ? "" : "s")")
                        .accessibilityHint(showSteps ? "Hides what the bot did on the way" : "Shows what the bot did on the way")
                    }
                    if !autos.isEmpty {
                        let n = max(1, autos.filter { $0.type == "auto" }.count)
                        Button {
                            withAnimation { showAutos.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Text(n == 1 ? "1 automatic update" : "\(n) automatic updates")
                                Image(systemName: showAutos ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.vertical, 10).padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .padding(.vertical, -10).padding(.horizontal, -6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) automatic update\(n == 1 ? "" : "s") since")
                    }
                }
                .padding(.leading, group.isEmpty ? 6 : 46)
                if showAutos { AutomaticGroup.list(autos).padding(.leading, group.isEmpty ? 6 : 46).transition(.opacity) }
                if showSteps {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.steps.enumerated()), id: \.offset) { _, s in
                            Text(Markdown.render(s)).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, group.isEmpty ? 6 : 46)
                    .transition(.opacity)
                }
            }
        }
    }

    /// What the server writes for each attached photo: a line "[Image from <name>: /path ...]".
    static let imageMark = "[Image from "

    private static func isImageLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(imageMark)
    }

    /// The text without its "[Image from ...]" lines, which are never shown. Any name matches, so messages sent
    /// before the server knew the person's name still read right. With `count`, "[1 photo]" stands in for them;
    /// without it they just go, for a bubble that shows the photos themselves.
    static func withoutImageLines(_ text: String, count: Bool = true) -> String {
        let lines = text.components(separatedBy: "\n")
        let n = lines.filter { isImageLine($0) }.count
        guard n > 0 else { return text }
        let rest = lines.filter { !isImageLine($0) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard count else { return rest }
        return [rest, "[\(n) photo\(n == 1 ? "" : "s")]"].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The same for a one-line preview (Home's rows), where the server has joined the lines of a message: every
    /// "[Image from ...]" note goes, also one that was cut short before its closing bracket, and the photos are
    /// named in plain words.
    static func previewWithoutImages(_ text: String) -> String {
        guard text.contains(imageMark) else { return text }
        var rest = ""
        var n = 0
        var tail = Substring(text)
        while let found = tail.range(of: imageMark) {
            rest.append(contentsOf: tail[..<found.lowerBound])
            rest.append(" ")
            n += 1
            let after = tail[found.upperBound...]
            if let close = after.firstIndex(of: "]") {
                tail = after[after.index(after: close)...]
            } else {
                tail = Substring()
            }
        }
        rest.append(contentsOf: tail)
        let words = rest.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let photos = n == 1 ? "Photo" : "\(n) photos"
        return words.isEmpty ? photos : "\(words) (\(photos.lowercased()))"
    }

    /// A bot's bubble; in a group chat it carries the member's own tint.
    private func bubble(_ text: String, tint: Color? = nil) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 5, bottomTrailingRadius: 18, topTrailingRadius: 18)
        return HStack(spacing: 0) {
            // Laid out block by block: code scrolls sideways with a copy button, lists and tables keep their shape.
            // A long press offers Copy, Share and Select Text (which is how part of a message is copied).
            MarkdownView(text: text)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(shape.fill(Color(.secondarySystemBackground)).overlay(shape.fill(tint ?? .clear)))
                .contentShape(.contextMenuPreview, shape)
                .chatMessageMenu(text, on: menu)
            Spacer(minLength: 40)
        }
    }
}

/// Each bot's own color (its skin's), so a group chat shows who said what at a glance. Adjusted per appearance:
/// a dark skin is lightened in dark mode, a pale one darkened in light mode.
enum BotColor {
    static func label(_ a: Agent, _ scheme: ColorScheme) -> Color {
        guard let hex = a.color else { return .secondary }
        let c = Color(hex: hex), l = luminance(hex)
        if scheme == .dark { return l < 0.3 ? c.mix(with: .white, by: 0.5) : c }
        return l > 0.6 ? c.mix(with: .black, by: 0.55) : l > 0.4 ? c.mix(with: .black, by: 0.2) : c
    }

    static func fill(_ a: Agent, _ scheme: ColorScheme) -> Color {
        guard let hex = a.color else { return .clear }
        let c = Color(hex: hex), l = luminance(hex)
        if scheme == .dark { return (l < 0.3 ? c.mix(with: .white, by: 0.35) : c).opacity(0.18) }
        return (l > 0.6 ? c.mix(with: .black, by: 0.25) : c).opacity(0.13)
    }

    static func luminance(_ hex: String) -> Double {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xff) / 255, g = Double((v >> 8) & 0xff) / 255, b = Double(v & 0xff) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// "Today", "Yesterday", "Sat 7 Nov": where a new day starts in a chat.
struct DaySeparator: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    static func label(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let sameYear = cal.component(.year, from: d) == cal.component(.year, from: Date())
        return d.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }
}

/// A group reply is one paragraph per member, each starting with "**Name:** ". Split it into bubbles.
enum GroupSplit {
    struct Part { let agent: String?; let text: String }

    static func split(_ text: String, members: [Agent]) -> [Part] {
        var parts: [Part] = []
        var current: (String?, [String]) = (nil, [])
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = members.first(where: { t.hasPrefix("**\($0.name):**") || t.hasPrefix("**\($0.name)**:") }) {
                if !current.1.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(Part(agent: current.0, text: current.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
                let rest = t.replacingOccurrences(of: "**\(m.name):**", with: "").replacingOccurrences(of: "**\(m.name)**:", with: "")
                current = (m.id, [rest.trimmingCharacters(in: .whitespaces)])
            } else {
                current.1.append(line)
            }
        }
        if !current.1.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(Part(agent: current.0, text: current.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
        return parts.contains { $0.agent != nil } ? parts : []
    }
}

/// One bot's "needs you" list, as a half sheet over its chat. Swipe a row for Done or Not now; tap it for the card.
struct BotNeedsSheet: View {
    let agentId: String
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Card?

    var body: some View {
        let cards = store.needs.filter { $0.agent == agentId }
        NavigationStack {
            List {
                if cards.isEmpty { Text("Nothing needs you here.").foregroundStyle(.secondary).listRowSeparator(.hidden) }
                // No line above the first card or under the last one: only between two cards.
                ForEach(cards) { card in
                    CardRow(card: card, onTap: { selected = $0 })
                        .listRowSeparator(card.id == cards.first?.id ? .hidden : .automatic, edges: .top)
                        .listRowSeparator(card.id == cards.last?.id ? .hidden : .automatic, edges: .bottom)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Needs you · \(cards.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(item: $selected) { CardSheet(card: $0).environmentObject(store) }
        .onChange(of: store.sheetReset) { _, _ in selected = nil; dismiss() }
    }
}

extension UIImage {
    /// At most 1600 px on the long side, so a photo uploads fast on any connection.
    func scaledForUpload() -> UIImage {
        // Counted in pixels (a screenshot's size is in points, at 2 or 3 pixels each).
        let w = size.width * scale, h = size.height * scale
        let longest = max(w, h)
        guard longest > 1600 else { return self }
        let k = 1600 / longest
        let target = CGSize(width: w * k, height: h * k)
        // One pixel per point: the default format draws at the screen's scale, which made 4800 px of the 1600.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// "4 automatic updates", tap to read them: what automations sent this bot and what it answered them.
struct AutomaticGroup: View {
    let entries: [Entry]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                // As quiet as the time under a message: it is there to be found, not to be read.
                HStack(spacing: 3) {
                    Text("\(updates) automatic update\(updates == 1 ? "" : "s")")
                    if let last = entries.last { Text("· \(Ago.short(last.at))") }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .padding(.vertical, -8)
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides them" : "Shows what automations sent and what the bot answered")
            if open { Self.list(entries) }
        }
        .padding(.vertical, 2)
    }

    private var updates: Int { max(1, entries.filter { $0.type == "auto" }.count) }

    /// What the automations sent and what the bot answered them, opened from a line.
    static func list(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.type == "auto" ? "Sent to the bot" : "Its answer").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    Text(Markdown.render(e.text)).font(.caption).foregroundStyle(.secondary).lineLimit(12)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground).opacity(0.6)))
            }
        }
    }
}

// MARK: - Images in messages (screenshots from bots, photos sent from the phone)

/// Loads an image from the server (GET /v1/file, with the app's token), cached for the session.
@MainActor
final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    func load(_ path: String) async {
        // A picture T3 Code keeps (direct mode): ImageStore asks T3 Code for a short-lived link.
        if path.hasPrefix("t3media:") || path.hasPrefix("t3attachment:") {
            if let img = await ImageStore.shared.load("file:" + path, path: path) { image = img } else { failed = true }
            return
        }
        // A photo still on its way: the bytes on this phone.
        if path.hasPrefix("local:"), let img = Outgoing.image(String(path.dropFirst(6))) { image = img; return }
        // "+" and "&" are allowed in a query but mean a space and the next field to the server: a path holding
        // one came back as "not an image".
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&")
        let q = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        if let img = await ImageStore.shared.load("file:" + path, path: "v1/file?path=\(q)") { image = img } else { failed = true }
    }
}

struct ChatImage: View {
    let item: EntryImage
    @EnvironmentObject var store: Store
    @StateObject private var loader = ImageLoader()
    @Environment(\.scenePhase) private var phase
    @State private var full = false

    var body: some View {
        Group {
            if let img = loader.image {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 440)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator), lineWidth: 0.5))
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { full = true }
                    .contextMenu {
                        Button { ChatCopy.image(img, store) } label: { Label("Copy", systemImage: "doc.on.doc") }
                        ShareLink(item: Image(uiImage: img), preview: SharePreview(item.alt.isEmpty ? "Image" : item.alt, image: Image(uiImage: img))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .accessibilityLabel(item.alt.isEmpty ? "Image" : item.alt)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the image full screen")
            } else if loader.failed {
                // Tap to try again (it also retries by itself when the app comes back to the front).
                Button {
                    loader.failed = false
                    Task { await loader.load(item.path) }
                } label: {
                    Label("Image unavailable. Tap to retry", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground))
                    .frame(width: 220, height: 160).overlay(ProgressView())
            }
        }
        .task(id: item.path) { await loader.load(item.path) }
        .onChange(of: phase) { _, p in
            if p == .active, loader.failed { loader.failed = false; Task { await loader.load(item.path) } }
        }
        .fullScreenCover(isPresented: $full) {
            if let img = loader.image { ImageViewer(image: img, title: item.alt) }
        }
    }
}

struct ImageStrip: View {
    let images: [EntryImage]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(images, id: \.path) { ChatImage(item: $0) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

/// Full screen, pinch to zoom, double tap to zoom in or out, share.
struct ImageViewer: View {
    let image: UIImage
    var title: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// A zoom step asked through VoiceOver, within the pinch's own limits (1 to 6); back at 1 the image is centred again.
    private func zoom(to wanted: CGFloat) {
        let s = max(1, min(6, wanted))
        withAnimation {
            scale = s
            last = s
            if s == 1 { offset = .zero; lastOffset = .zero }
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel(title.isEmpty ? "Image" : title)
                    .accessibilityValue(scale > 1 ? "Zoomed in" : "")
                    // VoiceOver has no pinch here: its zoom gesture and two named actions do the same.
                    .accessibilityZoomAction { action in
                        switch action.direction {
                        case .zoomIn: zoom(to: scale * 1.5)
                        case .zoomOut: zoom(to: scale / 1.5)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: "Zoom in") { zoom(to: scale * 1.5) }
                    .accessibilityAction(named: "Zoom out") { zoom(to: scale / 1.5) }
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(MagnifyGesture()
                        .onChanged { scale = max(1, min(6, last * $0.magnification)) }
                        .onEnded { _ in last = scale; if scale == 1 { withAnimation { offset = .zero; lastOffset = .zero } } })
                    .simultaneousGesture(DragGesture()
                        .onChanged { v in if scale > 1 { offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height) } }
                        .onEnded { v in
                            if scale > 1 { lastOffset = offset } else if v.translation.height > 120 { dismiss() }
                        })
                    .onTapGesture(count: 2) { withAnimation { if scale > 1 { scale = 1; last = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; last = 2.5 } } }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(title.isEmpty ? "Image" : title, image: Image(uiImage: image)))
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Lays its views out in rows, left to right, starting a new row when the next one does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += row + spacing; x = 0; row = 0 }
            x += (x > 0 ? spacing : 0) + s.width
            row = max(row, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}
