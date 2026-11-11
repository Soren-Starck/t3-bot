import SwiftUI
import UIKit

/// Card swiping: the needs list one card at a time, full screen.
/// Right: the card's main action. Left: not now (until quiet hours end). Up: done.
/// A question is answered with its options on the card; it can only be swiped left.
struct ReviewView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGSize = .zero
    /// True while a finger drags the card. It falls back to false by itself when the system cancels the drag (a call
    /// coming in, the app switcher), which is the only sign SwiftUI gives of a cancelled drag.
    @GestureState private var dragging = false
    /// Where the drag in hand began, and whether it belongs to a strip under the finger (a code block, a table)
    /// and not to the card.
    @State private var judged: (start: CGPoint, strip: Bool)?
    /// Cards acted on in this sitting. One that is no longer in the list counts as handled; one that came back
    /// (Undo, or an action that failed) counts as still to do, so the counter never runs ahead.
    @State private var handled: Set<String> = []
    /// The card on its way out, so a second tap during the fly-out cannot act twice.
    @State private var leaving: String?
    /// Which way the card would go if let go now; a tick under the finger each time it changes.
    @State private var armed: String?

    /// A card picked from the list (or from "Also from" on a card): it goes on top of the deck.
    @State private var focus: String?
    /// The same cards as a list, grouped by how soon they need you: one place for the whole queue, two ways to see it.
    @State private var listMode = false

    private var cards: [Card] {
        let all = store.needs
        guard let focus, let i = all.firstIndex(where: { $0.id == focus }) else { return all }
        var out = all
        out.insert(out.remove(at: i), at: 0)
        return out
    }
    /// The top card's height, for the blank edge of the one behind it.
    @State private var topHeight: CGFloat = 0
    private var gone: Int { handled.filter { id in !cards.contains { $0.id == id } }.count }
    private var total: Int { gone + cards.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        // The circle stays 40 pt; the finger gets 44.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                if listMode {
                    Text(cards.count == 1 ? "1 needs you" : "\(cards.count) need you")
                        .font(.subheadline.weight(.semibold))
                } else if !cards.isEmpty {
                    Text("\(gone + 1) of \(total)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.3), value: gone)
                        .accessibilityLabel("Card \(gone + 1) of \(total)")
                }
                Spacer()
                // Cards or list: the same queue.
                Button {
                    Haptics.tap()
                    withAnimation(.spring(duration: 0.3)) { listMode.toggle() }
                } label: {
                    Image(systemName: listMode ? "rectangle.stack" : "list.bullet").font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(cards.isEmpty ? 0 : 1)
                .accessibilityLabel(listMode ? "Show as cards" : "Show as a list")
            }
            .padding(.horizontal, 10)
            if listMode {
                ReviewList { id in
                    focus = id
                    withAnimation(.spring(duration: 0.3)) { listMode = false }
                }
            } else {
            // How far through the stack this sitting is.
            if total > 0 {
                // Where this card sits in the stack: the first of thirteen already shows a little progress.
                ProgressView(value: Double(min(gone + 1, total)), total: Double(max(total, 1)))
                    .tint(.primary)
                    .padding(.horizontal, 20).padding(.top, 4)
                    .animation(.spring(duration: 0.4), value: gone)
                    .accessibilityHidden(true)
            }

            // Top-aligned under the progress line: a short card no longer floats in the middle of the screen.
            ZStack(alignment: .top) {
                if let next = cards.dropFirst().first {
                    // The card behind comes forward as the top one is pulled away, so it is already in place
                    // when it becomes the top card. At rest only its edge shows under the top card (a stack), as a
                    // blank card of the top one's height: its own content peeking out read as a glitch.
                    ReviewCard(card: next).opacity(Double(pull))
                        .offset(y: 18 * (1 - pull))
                        .scaleEffect(0.95 + 0.05 * pull)
                        .opacity(0.6 + 0.4 * Double(pull))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let top = cards.first {
                    // An answered question counts as handled too, so the counter and the line move on with it.
                    ReviewCard(card: top, onAnswer: { handled.insert(top.id) }, onJump: { id in
                        withAnimation(.spring(duration: 0.35)) { focus = id }
                    })
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
                        .overlay(alignment: .top) { hint(for: top) }
                        .offset(drag)
                        .rotationEffect(.degrees(Double(drag.width / 22)))
                        .gesture(swipe(top))
                        .id(top.id)
                        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("All clear").font(.title2.weight(.semibold))
                        Text("Nothing else needs you right now.").foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Close") { dismiss() }.buttonStyle(.glass).padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: cards.isEmpty ? .infinity : nil, alignment: .top)
            // Room between the progress line and the card.
            .padding(.top, 12)

            if let top = cards.first {
                // The buttons right under the card (past the deck's edges), and under them what comes next: the
                // screen holds the queue, not an empty band.
                buttons(top).padding(.horizontal, 16).padding(.top, 40)
                upNext.padding(.horizontal, 16).padding(.top, 20)
                Spacer(minLength: 8)
            }
            }
        }
        // "Marked done · Undo" at the foot of the screen.
        .overlay(alignment: .bottom) { ToastBar(bottom: 12).environmentObject(store) }
        .background(Color(.systemGroupedBackground))
        .onAppear { if store.reviewAsList { listMode = true; store.reviewAsList = false } }
        .onChange(of: dragging) { _, now in
            // The drag is over. When it ended the usual way, onEnded has dealt with the card. When the system
            // cancelled it, nothing has, and the card would stay where the finger left it: it goes back to the centre.
            guard !now, leaving == nil, drag != .zero else { return }
            armed = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = .zero }
        }
    }

    /// 0 at rest, 1 once the top card is far enough to go.
    private var pull: CGFloat {
        min(1, max(abs(drag.width) / 120, -drag.height / 140, 0))
    }

    /// The card's main action: the first that is neither Done nor Not now ("Handle it" when its source named none).
    private func primary(_ c: Card) -> CardAction? {
        c.isQuestion ? nil : CardButtons.actions(for: c).first { $0.kind != "done" && $0.kind != "snooze" }
    }

    private func done(_ c: Card) -> CardAction? {
        c.isQuestion ? nil : CardButtons.actions(for: c).first { $0.kind == "done" }
    }

    private func way(_ t: CGSize, _ c: Card) -> String? {
        if t.width > 120, primary(c) != nil { return "right" }
        if t.width < -120 { return "left" }
        if t.height < -140, done(c) != nil { return "up" }
        return nil
    }

    /// A sideways drag that began on a code block or a table holding more than fits scrolls that block, and the card
    /// stays put. Judged once, at the drag's first move, and kept for the rest of it.
    private func onStrip(_ v: DragGesture.Value) -> Bool {
        if let judged, judged.start == v.startLocation { return judged.strip }
        let t = v.translation
        let strip = abs(t.width) > abs(t.height) && Self.strip(at: v.startLocation)
        judged = (start: v.startLocation, strip: strip)
        return strip
    }

    /// `point` is in the screen's coordinates, which are the window's: this view covers the whole screen.
    private static func strip(at point: CGPoint) -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return false }
        return SwipeBack.sideScroller(at: point, in: window) != nil
    }

    private func swipe(_ c: Card) -> some Gesture {
        // Global coordinates, so that where the drag began can be looked up in the window. The distances read below
        // are the same in any coordinates.
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { v in
                guard leaving == nil, !onStrip(v) else { return }
                drag = v.translation
                let now = way(v.translation, c)
                if now != armed { armed = now; if now != nil { Haptics.select() } }
            }
            .onEnded { v in
                let strip = onStrip(v)
                judged = nil
                guard leaving == nil, !strip else { return }
                armed = nil
                let t = v.translation
                let w = way(t, c)
                if w == "right", let p = primary(c) { finish(c, p, out: CGSize(width: 700, height: t.height)) }
                else if w == "left" { snooze(c, out: CGSize(width: -700, height: t.height)) }
                else if w == "up", let d = done(c) { finish(c, d, out: CGSize(width: t.width, height: -900)) }
                else { withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = .zero } }
            }
    }

    /// The card flies out, then the store acts (it gives the tap under the finger and the Undo bar).
    private func finish(_ c: Card, _ action: CardAction, out: CGSize) {
        guard leaving == nil else { return }
        // Face ID comes first and can be refused: the card stays where it is until the answer is yes.
        if action.faceId == true {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = .zero }
            handled.insert(c.id)
            store.act(c, action.id, text: c.edit?.text)
            return
        }
        fly(c, out: out) { store.act(c, action.id, text: c.edit?.text) }
    }

    private func snooze(_ c: Card, out: CGSize) {
        guard leaving == nil else { return }
        fly(c, out: out) {
            let morning = Snooze.options(store.settings).first { $0.id == "morning" }
            store.act(c, "snooze", until: morning?.until, label: "Snoozed until \(Self.morningWords(morning))")
        }
    }

    /// "this morning" after midnight and before the morning hour, "tomorrow morning" the rest of the day:
    /// the same words as the Not now menu on a card.
    private static func morningWords(_ o: Snooze.Option?) -> String {
        o?.label.lowercased() ?? "tomorrow morning"
    }

    private func fly(_ c: Card, out: CGSize, then act: @escaping () -> Void) {
        leaving = c.id
        // Reduce Motion: the card leaves without flying across the screen.
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.22)) { drag = out }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { drag = .zero }
            handled.insert(c.id)
            leaving = nil
            act()
        }
    }

    @ViewBuilder
    private func hint(for c: Card) -> some View {
        let right = drag.width > 40
        let left = drag.width < -40
        let up = !right && !left && drag.height < -50
        let label: String? = right ? primary(c).map { CardButtons.shown($0, c, store) } : left ? "Not now" : up ? done(c)?.label : nil
        if let label {
            Label(label, systemImage: right ? "arrow.right" : left ? "moon.zzz.fill" : "checkmark")
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(right ? Color.green : left ? Color.gray : Color.blue))
                .foregroundStyle(.white)
                // Full strength once letting go would act.
                .opacity(armed != nil ? 1 : 0.7)
                .scaleEffect(armed != nil ? 1.06 : 1)
                .animation(.spring(duration: 0.2), value: armed)
                .padding(.top, 18)
                .padding(.horizontal, 16)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    /// The next few cards, quietly, under the buttons; a tap brings one to the top.
    @ViewBuilder
    private var upNext: some View {
        let next = Array(cards.dropFirst().prefix(3))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Up next").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
                ForEach(next) { c in
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(duration: 0.35)) { focus = c.id }
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(agent: c.agent, size: 24)
                            Text(c.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 6)
                            KindTag(card: c)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(CardText.spoken(c, store))
                    .accessibilityHint("Brings this card to the top")
                    if c.id != next.last?.id { Divider().padding(.leading, 34) }
                }
            }
        }
    }

    /// The card's main action on its own full-width row (its label never gets cut), Not now and Done under it.
    private func buttons(_ c: Card) -> some View {
        VStack(spacing: 10) {
            if let p = primary(c) {
                Button { finish(c, p, out: CGSize(width: 700, height: 0)) } label: {
                    Label(CardButtons.shown(p, c, store), systemImage: p.faceId == true ? "faceid" : "arrow.right")
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.primary).foregroundStyle(Color(.systemBackground))
                .accessibilityHint(p.faceId == true ? "Asks for Face ID first" : "")
            }
            HStack(spacing: 10) {
                Button { snooze(c, out: CGSize(width: -700, height: 0)) } label: {
                    Label("Not now", systemImage: "moon.zzz").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityHint("Comes back \(Self.morningWords(Snooze.options(store.settings).first { $0.id == "morning" }))")
                if let d = done(c) {
                    Button { finish(c, d, out: CGSize(width: 0, height: -900)) } label: {
                        // "Done" read as "close this screen".
                        Label(d.label == "Done" ? "Mark handled" : d.label, systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .lineLimit(1)
        }
        .controlSize(.large)
    }
}

/// One card as it looks in the swiping view.
struct ReviewCard: View {
    let card: Card
    /// The question on this card was answered from its form.
    var onAnswer: () -> Void = {}
    /// One of the bot's other cards was tapped: it comes to the top of the deck.
    var onJump: (String) -> Void = { _ in }
    @EnvironmentObject var store: Store

    var body: some View {
        // As tall as what it says; it scrolls only when that does not fit. (ViewThatFits measured the text on
        // one line and cut it short.)
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: height > 0 ? height : .infinity)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    @State private var height: CGFloat = 0

    private var content: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if let a = store.agent(card.agent), a.kind != "group" {
                        LiveFace(face: a.face, size: 44, state: store.faceState(a), calm: true)
                    } else {
                        AvatarView(agent: card.agent, size: 40)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.agent(card.agent)?.name ?? card.agent).font(.subheadline.weight(.semibold))
                        Text(CardHeader.meta(card, store)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }

                }
                .accessibilityElement(children: .combine)
                if card.isQuestion {
                    // The form shows the question itself, so the card does not say it twice.
                    QuestionForm(card: card) { onAnswer() }
                } else {
                    Text(card.title.unbroken).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    CardDetails(card: card)
                    if let edit = card.edit {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(edit.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            Text(edit.text).font(.subheadline)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemBackground)))
                        }
                    }
                }
                // What else this bot waits on you for: often the other half of the same story (the alarm and the
                // fix waiting to ship). At the card's foot.
                let more = store.needs.filter { $0.agent == card.agent && $0.id != card.id }
                if !more.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Also from \(store.agent(card.agent)?.name ?? "this bot")").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(more.prefix(3)) { m in
                            Button { Haptics.tap(); onJump(m.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: CardText.mark(m)?.symbol ?? "checklist").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                                    Text(m.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}


/// The queue as a list inside Review, grouped by how soon each card needs you; a tap puts that card on top of the deck.
struct ReviewList: View {
    @EnvironmentObject var store: Store
    var onPick: (String) -> Void

    var body: some View {
        List {
            ForEach(AllNeedsView.groups, id: \.0) { title, ranks in
                let items = store.needs.filter { ranks.contains(min(max($0.rank, 0), 4)) }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { c in CardRow(card: c) { onPick($0.id) } }
                    } header: {
                        ListHeader(text: "\(title) · \(items.count)")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
