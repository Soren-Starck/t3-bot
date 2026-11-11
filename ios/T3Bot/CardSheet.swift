import MessageUI
import SwiftUI

/// One thing that needs the person, in full, with the actions that fit it.
struct CardSheet: View {
    let card: Card
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var composer: String?
    @State private var editText = ""
    @State private var editLoaded = false
    /// The card's height, for a sheet that fits it; nil until measured, or when it needs the whole screen.
    @State private var fitted: CGFloat?
    /// The sheet's height, changed in the same step as the heights it may take, so it is never one that is gone.
    @State private var detent: PresentationDetent = .medium
    @State private var measured = false
    @StateObject private var bar = AnswerBar()
    private var pinsSend: Bool { card.isQuestion && !card.isApproval && !(card.questions ?? []).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if card.isQuestion {
                    QuestionForm(card: card, bar: pinsSend ? bar : nil) { dismiss() }
                } else {
                    Text(card.title.unbroken).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    CardDetails(card: card)
                    if let edit = card.edit {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(edit.label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            TextEditor(text: $editText)
                                .frame(minHeight: 88)
                                .padding(8)
                                .scrollContentBackground(.hidden)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                                .accessibilityLabel(edit.label)
                        }
                    }
                    if let link = card.link, let url = URL(string: link) {
                        Button { openURL(url) } label: { Label("Open link", systemImage: "link") }
                    }
                    if let d = card.draft { draftActions(d) } else { CardButtons(card: card, text: card.edit == nil ? nil : editText) { dismiss() } }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                // The card's own height plus its header row, within what a sheet may take.
                // (Measured on the approval card: +96 left an empty band of about 45 points under the buttons.)
                let want = h + 60
                let next: CGFloat? = want > ScreenSize.height * 0.86 ? nil : max(220, want)
                guard !measured || next != fitted else { return }
                measured = true
                fitted = next
                // Pulled up to the whole screen stays there; otherwise the sheet takes the card's height.
                // A card taller than a fitted sheet opens on the whole screen: half a form with its Send button out
                // of sight read as broken.
                if detent != .large { detent = next.map { .height($0) } ?? .large }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // A question's Send stays in sight at the foot, however long the form.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pinsSend {
                Button { bar.send() } label: {
                    Text(bar.busy ? "Sending" : bar.ready ? "Send answer" : bar.missing.map { "Pick at least one \($0.lowercased())" } ?? "Answer every question")
                        .frame(maxWidth: .infinity)
                }
                    .mainButton()
                    .controlSize(.large)
                    .disabled(!bar.ready || bar.busy)
                    .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
                    .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
            }
        }
        // Who asks and Close share one row that stays put while the card scrolls. A navigation bar holding
        // only Close left an empty band the height of a title above the bot's name.
        .safeAreaBar(edge: .top, spacing: 0) { header }
        // As tall as the card (two buttons do not get half a screen), and opaque: the list behind it blurred
        // through the options.
        .presentationDetents(fitted == nil ? [.medium, .large] : [.height(fitted!), .large], selection: $detent)
        .presentationBackground(Color(.systemBackground))
        .presentationDragIndicator(.visible)
        .onAppear {
            // Once: coming back from Mail or Messages must not undo what was typed here.
            if !editLoaded { editText = card.edit?.text ?? ""; editLoaded = true }
        }
        .sheet(item: Binding(get: { composer.map { ComposerKind(id: $0) } }, set: { composer = $0?.id })) { k in
            if let d = card.draft {
                switch k.id {
                case "mail": MailComposer(to: d.to ?? "", subject: d.subject ?? "", text: d.text ?? "") { sent in if sent { run("done") } }
                case "event": EventComposer(draft: d) { saved in if saved { run("done") } }
                default: MessageComposer(to: d.to ?? "", text: d.text ?? "") { sent in if sent { run("done") } }
                }
            }
        }
    }

    struct ComposerKind: Identifiable { let id: String }

    /// The bot, what kind of card this is and how old, and Close.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                if let a = store.agent(card.agent), a.kind != "group" { LiveFace(face: a.face, size: 38, state: store.faceState(a), calm: true) }
                else { AvatarView(agent: card.agent, size: 32) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.agent(card.agent)?.name ?? card.agent).font(.subheadline.weight(.semibold))
                    Text(CardHeader.meta(card, store)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            // The same close button as Review's: one way to leave every card.
            Button { dismiss() } label: {
                // A plain filled circle: glass on the white sheet drew a smudged halo around it.
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        // Clear of the grabber.
        .padding(.top, 22).padding(.bottom, 8)
    }

    @ViewBuilder
    private func draftActions(_ d: Draft) -> some View {
        // A phone with no mail account (or no Messages) cannot open the composer: say so and offer the text.
        let blocked: String? = d.event != nil ? nil
            : d.via == "mail" ? (MFMailComposeViewController.canSendMail() ? nil : "Mail is not set up on this iPhone.")
            : (MFMessageComposeViewController.canSendText() ? nil : "This device cannot send messages.")
        VStack(spacing: 10) {
            if d.event != nil {
                Button { composer = "event" } label: { Text("Review and add to Calendar").frame(maxWidth: .infinity) }
                    .mainButton()
            } else if d.via == "mail" {
                Button { composer = "mail" } label: { Text("Open in Mail").frame(maxWidth: .infinity) }
                    .mainButton()
                    .disabled(blocked != nil)
            } else {
                Button { composer = "message" } label: { Text("Open in Messages").frame(maxWidth: .infinity) }
                    .mainButton()
                    .disabled(blocked != nil)
            }
            if blocked != nil, let text = d.text, !text.isEmpty {
                Button { ChatCopy.text(text, store) } label: {
                    Label("Copy the text", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .quietButton()
            }
            HStack(spacing: 10) {
                Button { run("done") } label: { Text("Discard").frame(maxWidth: .infinity) }.quietButton()
                Button { run("snooze") } label: { Text("Not now").frame(maxWidth: .infinity) }.quietButton()
            }
            // An event is added, not sent; Calendar's own screen says "Add".
            Text(blocked ?? (d.event != nil ? "Nothing is added until you press Add." : "Nothing is sent until you press Send."))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .controlSize(.large)
    }

    /// Closes at once; the store hides the card and sends the action behind it.
    private func run(_ action: String) {
        dismiss()
        store.act(card, action)
    }
}

/// The line under the bot's name on a card's own screen (the sheet, Review). The lists start that line with the
/// bot or its thread; here the name stands right above it, so it is not said twice, and a bot's own thread is
/// never shown by its T3 title ("%BOT API").
enum CardHeader {
    /// A thread's title as a person would say it: the server titles a bot's own thread "%BOT <name>".
    static func threadName(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        for mark in ["%BOT Group: ", "%BOT "] where t.hasPrefix(mark) { t = String(t.dropFirst(mark.count)) }
        return t
    }

    static func kindWord(_ c: Card) -> String {
        switch c.kind {
        case "alarm": return "Alarm"
        case "approve": return "Decision"
        case "draft": return "Draft to send"
        case "do": return "To do"
        default: return c.source == "desk" ? "To do" : "Needs you"
        }
    }

    @MainActor
    static func meta(_ c: Card, _ store: Store) -> String {
        let bot = store.agent(c.agent)
        let who = bot?.name ?? c.agent
        var parts: [String] = []
        if c.isQuestion {
            let thread = threadName(c.threadTitle ?? "")
            let own = thread.isEmpty || thread == who || (c.threadId != nil && c.threadId == bot?.threadId)
            if c.isApproval { parts.append(own ? "Approval" : "Approval in \(thread)") }
            else { parts.append(own ? "Question" : "Asks in \(thread)") }
        } else {
            // Every card says what kind it is first, then how old: "Alarm · 5h", "Decision · 4h".
            parts.append(kindWord(c))
            if c.customer == true { parts.append("customer waiting") }
            if let desk = c.deskName, !desk.isEmpty, desk != who { parts.append("from \(desk)") }
        }
        parts.append(Ago.short(c.at))
        if !c.isQuestion, let m = c.minutes, m > 0 { parts.append("takes \(Int(m.rounded()))\u{00A0}min") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The app's main button: filled with the label colour, its text in the background colour. Disabled, the system
/// greys the fill but would keep that text colour (white on light grey, black on dark grey), so the text greys too.
private struct MainButton: ViewModifier {
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(enabled ? Color(.systemBackground) : Color.secondary)
    }
}

private struct QuietButton: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // A plain filled capsule in the text colour's tint: the glass button on a faint fill vanished on the white
        // sheet (white pills on white).
        content.buttonStyle(.bordered).tint(Color.primary).foregroundStyle(Color.primary)
    }
}

extension View {
    func mainButton() -> some View { modifier(MainButton()) }
    /// The quieter choices beside it (Done, Not now, Decline, Discard): the system's glass button, on a faint fill.
    /// On a half-height sheet in the dark appearance the glass alone had no visible edge, so they read as loose text.
    func quietButton() -> some View { modifier(QuietButton()) }
}

/// What was picked in a question form, kept while the answer travels. The form leaves the screen as soon as the
/// answer is sent; if the answer does not go through and the card comes back, the picks come back with it.
@MainActor
private enum AnswerStash {
    struct Kept {
        var picked: [String: Set<String>]
        var custom: [String: String]
        var at: Date
    }

    private static var kept: [String: Kept] = [:]

    static func keep(_ id: String, picked: [String: Set<String>], custom: [String: String]) {
        let now = Date()
        kept = kept.filter { now.timeIntervalSince($0.value.at) < 600 }
        kept[id] = Kept(picked: picked, custom: custom, at: now)
    }

    /// The picks of the last answer sent for this card. They stay until a newer answer replaces them: a card
    /// whose answer went through never comes back, so nothing reads them again.
    static func last(_ id: String) -> Kept? {
        guard let k = kept[id], Date().timeIntervalSince(k.at) < 600 else { return nil }
        return k
    }
}

/// Lets a sheet pin the form's Send button under the form, where it stays in sight however long the form is.
@MainActor
final class AnswerBar: ObservableObject {
    @Published var ready = false
    @Published var busy = false
    /// What is still to answer, said on the button while it cannot send.
    @Published var missing: String?
    var send: () -> Void = {}
}

/// An agent's question (AskUserQuestion) or a command approval, answered from the phone. The form does not
/// say where it was asked: the sheet and Review name the thread on the line above it, and the chat is the thread.
struct QuestionForm: View {
    let card: Card
    /// Set by a sheet that shows Send in a bar of its own.
    var bar: AnswerBar? = nil
    var onDone: () -> Void
    @EnvironmentObject var store: Store
    @State private var picked: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?

    private static let notSent = "That answer did not go through. Check it and send again."
    private var questions: [Question] { card.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if card.isApproval {
                Text(card.title.unbroken).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let command = card.detail, !command.isEmpty {
                    Text(command)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                        .textSelection(.enabled)
                        .accessibilityLabel("Command: \(command)")
                }
                // Stacked full width, like every other card: the main choice, the other one under it.
                VStack(spacing: 6) {
                    Button { decide("accept") } label: { Text("Approve").frame(maxWidth: .infinity) }
                        .mainButton()
                    // Quieter than Approve: two equal slabs on a production deploy read as a coin toss.
                    Button(role: .destructive) { decide("decline") } label: { Text("Decline").frame(maxWidth: .infinity) }
                        .quietButton()
                }
                .controlSize(.large)
                .disabled(busy)
            } else if questions.isEmpty {
                Text(card.title.unbroken).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text("This question came with nothing to pick here. Answer it in its thread.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(questions) { q in question(q) }
                if bar == nil {
                    Button { submit() } label: {
                        Text(busy ? "Sending" : "Send answer").frame(maxWidth: .infinity)
                    }
                    .mainButton()
                    .controlSize(.large)
                    .disabled(!complete || busy)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            defer { tellBar() }
            // Back after an answer that failed: what was picked is still here. Only a card the server still lists
            // counts (a chat that has not caught up with an answer that did go through must not say it failed).
            guard !busy, store.needs.contains(where: { $0.id == card.id }), let k = AnswerStash.last(card.id) else {
                // A fresh form starts on the recommended choice of each single-choice question: one tap to send.
                for q in questions where !q.multiSelect && (picked[q.id] ?? []).isEmpty {
                    if let o = q.options.first(where: { Self.withoutRecommended($0.label) != $0.label }) { picked[q.id] = [o.label] }
                }
                return
            }
            picked = k.picked
            custom = k.custom
            error = Self.notSent
        }
        .onChange(of: complete) { _, _ in tellBar() }
        .onChange(of: missing) { _, _ in tellBar() }
        .onChange(of: busy) { _, _ in tellBar() }
        .onChange(of: store.doneLocally.contains(card.id)) { _, hidden in
            // Still on screen when the card is no longer held back: the form works again, and says so when the
            // server still lists the card (the answer failed).
            if !hidden, busy {
                busy = false
                if store.needs.contains(where: { $0.id == card.id }) { error = Self.notSent }
            }
        }
    }

    private func question(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = q.header, !h.isEmpty, h != q.question {
                Text(h).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(q.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            if q.multiSelect, !q.options.isEmpty {
                Text("Pick any that apply").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(q.options, id: \.label) { o in
                let on = picked[q.id, default: []].contains(o.label)
                Button { toggle(q, o.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: on ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                             : (q.multiSelect ? "square" : "circle"))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            let shown = Self.withoutRecommended(o.label)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(shown).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                // "(recommended)" in the label becomes a quiet tag; the answer sent keeps the label as is.
                                if shown != o.label {
                                    Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green.opacity(0.14)))
                                }
                            }
                            if let d = o.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 44)
                    // Picked: a tinted fill and a thin edge, not a heavy black border.
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.primary.opacity(0.07) : Color(.tertiarySystemFill)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Color.primary : Color.clear, lineWidth: 1.5))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            TextField(q.options.isEmpty ? "Your answer" : "Or write your own answer", text: Binding(
                get: { custom[q.id] ?? "" },
                set: { custom[q.id] = $0; if !$0.isEmpty { picked[q.id] = [] } }
            ), axis: .vertical)
            .font(.subheadline)
            .lineLimit(1...6)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
        }
        .disabled(busy)
    }

    static func withoutRecommended(_ label: String) -> String {
        let r = label.replacingOccurrences(of: "\\s*[(\\[]recommended[)\\]]\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        return r.isEmpty ? label : r
    }

    /// The first question still without an answer, named as the form names it ("Scope").
    private var missing: String? {
        questions.first { q in
            (picked[q.id] ?? []).isEmpty && (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map { q in (q.header?.isEmpty == false ? q.header! : "the last question") }
    }

    private var complete: Bool {
        questions.allSatisfy { q in
            !(picked[q.id] ?? []).isEmpty || !(custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func toggle(_ q: Question, _ label: String) {
        Haptics.select()
        error = nil
        custom[q.id] = ""
        var s = picked[q.id] ?? []
        if q.multiSelect { if s.contains(label) { s.remove(label) } else { s.insert(label) } } else { s = [label] }
        picked[q.id] = s
    }

    /// What the pinned Send button needs to know, and what it does.
    private func tellBar() {
        guard let bar else { return }
        bar.ready = complete
        bar.busy = busy
        bar.missing = missing
        bar.send = { submit() }
    }

    private func submit() {
        guard let (threadId, requestId) = target() else { return }
        var answers: [String: Any] = [:]
        for q in questions {
            let text = (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { answers[q.id] = text; continue }
            let labels = q.options.map(\.label).filter { (picked[q.id] ?? []).contains($0) }
            answers[q.id] = q.multiSelect ? labels : (labels.first ?? "")
        }
        AnswerStash.keep(card.id, picked: picked, custom: custom)
        send(["threadId": threadId, "requestId": requestId, "answers": answers])
    }

    private func decide(_ d: String) {
        guard let (threadId, requestId) = target() else { return }
        AnswerStash.keep(card.id, picked: [:], custom: [:])
        send(["threadId": threadId, "requestId": requestId, "decision": d])
    }

    /// Where the answer goes. A card that lost its thread or request cannot be answered from here: say so
    /// instead of a button that does nothing.
    private func target() -> (String, String)? {
        guard let threadId = card.threadId, let requestId = card.requestId else {
            Haptics.error()
            error = "This question can no longer be answered from here. Open its thread to answer."
            return nil
        }
        return (threadId, requestId)
    }

    /// The answer leaves at once: the form closes and the store sends it behind, with a retry.
    private func send(_ body: [String: Any]) {
        busy = true
        error = nil
        onDone()
        store.answer(card, body: body)
    }
}

/// Body, fields and checks of a card, as any source sent them.
struct CardDetails: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = card.detail, !d.isEmpty { MarkdownView(text: d) }
            if let fields = card.fields, !fields.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline) {
                            Text(f.label).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(f.value).multilineTextAlignment(.trailing)
                        }
                        .font(.subheadline)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
            }
            if let checks = card.checks, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: c.state == "pass" ? "checkmark.circle.fill" : c.state == "fail" ? "xmark.circle.fill" : "clock")
                                .foregroundStyle(c.state == "pass" ? Color.green : c.state == "fail" ? Color.red : Color.secondary)
                                .accessibilityHidden(true)
                            Text(c.label).font(.subheadline)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(c.state == "pass" ? "Passed" : c.state == "fail" ? "Failed" : "Pending")
                    }
                }
            }
            if let why = card.why, !why.isEmpty { block("Why it is yours", why) }
            if let steps = card.steps, !steps.isEmpty { block("Steps", steps) }
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            MarkdownView(text: text).font(.subheadline)
        }
    }
}

/// The card's own buttons (from its source), with "Not now" as a menu of times.
struct CardButtons: View {
    let card: Card
    var text: String?
    var onAct: () -> Void
    @EnvironmentObject var store: Store

    /// What a card can do: its own actions, or Handle it, Done and Not now when its source named none.
    /// The sheet and the swiping view both read this, so a card offers the same things in both.
    static func actions(for card: Card) -> [CardAction] {
        if let own = card.actions, !own.isEmpty { return own }
        return [
            CardAction(id: "handle", label: "Handle it", kind: "handle", style: "primary", faceId: false),
            CardAction(id: "done", label: "Done", kind: "done", style: nil, faceId: false),
            CardAction(id: "snooze", label: "Not now", kind: "snooze", style: nil, faceId: false),
        ]
    }

    private var actions: [CardAction] { Self.actions(for: card) }

    /// What a button says. The stock "Handle it" says who does what: the card goes to its bot to be done now.
    @MainActor
    static func shown(_ a: CardAction, _ card: Card, _ store: Store) -> String {
        guard a.kind == "handle", a.label == "Handle it" else { return a.label }
        return "Ask \(store.agent(card.agent)?.name ?? "the bot") to handle this"
    }

    var body: some View {
        let main = actions.filter { $0.kind != "done" && $0.kind != "snooze" && $0.style != "destructive" }
        let destructive = actions.filter { $0.style == "destructive" }
        // One filled button: the one the source marked primary, else the first. The others are outlined, and a
        // destructive one is red text at the bottom, so the loudest button is never the one that cancels.
        let failed = (card.checks ?? []).filter { $0.state == "fail" }
        // While a check fails, the other way (wait, keep, fix) is the loud button, and going ahead says "anyway"
        // in orange.
        let wanted = main.first(where: { $0.style == "primary" })?.id ?? main.first?.id
        let primaryId = failed.isEmpty ? wanted : main.first(where: { $0.id != wanted })?.id
        VStack(spacing: 10) {
            if !failed.isEmpty {
                Label(failed.count == 1 ? "One check failed: \(failed[0].label)" : "\(failed.count) checks failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The loud button first, then the others in their own order.
            let ordered = main.enumerated().sorted { ($0.element.id == primaryId ? 0 : 1, $0.offset) < ($1.element.id == primaryId ? 0 : 1, $1.offset) }.map(\.element)
            ForEach(ordered) { a in
                Button { tap(a) } label: {
                    HStack(spacing: 6) {
                        if a.id == wanted && !failed.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                        } else if a.faceId == true {
                            Image(systemName: "faceid").accessibilityHidden(true)
                        }
                        Text(Self.shown(a, card, store) + (a.id == wanted && !failed.isEmpty ? " anyway" : ""))
                    }
                    .frame(maxWidth: .infinity)
                }
                .modifier(CardButtonLook(primary: a.id == primaryId, warn: !failed.isEmpty && a.id == wanted))
                .accessibilityHint(a.faceId == true ? "Asks for Face ID first" : "")
            }
            let done = actions.first(where: { $0.kind == "done" })
            let snooze = actions.contains(where: { $0.kind == "snooze" })
            if main.count > 1 || !destructive.isEmpty {
                // A real decision (its own choices): those are the buttons. Done, Not now and a destructive choice
                // wait in one quiet menu under them, instead of five buttons stacked.
                Menu {
                    if let done { Button { tap(done) } label: { Label(done.label, systemImage: "checkmark") } }
                    if snooze {
                        Menu {
                            ForEach(Snooze.options(store.settings)) { o in
                                Button(o.label) { onAct(); store.act(card, "snooze", until: o.until, label: "Snoozed: \(o.label.lowercased())") }
                            }
                        } label: { Label("Not now", systemImage: "moon.zzz") }
                    }
                    ForEach(destructive) { a in
                        Button(role: .destructive) { tap(a) } label: { Text(a.label) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis").font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity).frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                ForEach(destructive) { a in
                    Button(role: .destructive) { tap(a) } label: { Text(a.label).frame(maxWidth: .infinity).frame(minHeight: 44) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.body.weight(.medium))
                }
                HStack(spacing: 10) {
                    if let done {
                        Button { tap(done) } label: { Text(done.label).frame(maxWidth: .infinity) }.quietButton()
                    }
                    if snooze {
                        Menu {
                            ForEach(Snooze.options(store.settings)) { o in
                                Button(o.label) { onAct(); store.act(card, "snooze", until: o.until, label: "Snoozed: \(o.label.lowercased())") }
                            }
                        } label: { Text("Not now").frame(maxWidth: .infinity) }
                        .quietButton()
                    }
                }
            }
        }
        .controlSize(.large)
    }

    private func tap(_ a: CardAction) {
        onAct()
        store.act(card, a.id, text: text)
    }
}

/// The filled main button, or an outlined one beside it.
private struct CardButtonLook: ViewModifier {
    let primary: Bool
    /// Going ahead although a check failed: orange, so it never passes for the safe choice.
    var warn = false
    func body(content: Content) -> some View {
        if primary { content.mainButton() } else { content.quietButton() }
    }
}
