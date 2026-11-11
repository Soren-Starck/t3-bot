import Contacts
import EventKit
import EventKitUI
import MessageUI
import SwiftUI

/// The iPhone's calendar and contacts, shared with the bots only when the person turns it on in Settings.
/// The snapshot goes to their own T3 Bot server and nowhere else. Bots never send: they leave drafts, which
/// open in the iPhone's own composer, where the person presses Send.
enum PhoneSync {
    private static var lastPush = Date.distantPast
    static let events = EKEventStore()

    static func enable() async -> Bool {
        let cal = (try? await events.requestFullAccessToEvents()) ?? false
        let con = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        UserDefaults.standard.set(cal || con, forKey: "sharephone")
        if cal || con { await push(force: true) }
        return cal || con
    }

    /// False when the server could not be told to forget its copy: sharing then stays on, so what Settings shows
    /// is what the server holds.
    static func disable() async -> Bool {
        UserDefaults.standard.set(false, forKey: "sharephone")
        if (try? await API.post("v1/phone/forget")) != nil { return true }
        UserDefaults.standard.set(true, forKey: "sharephone")
        return false
    }

    /// At most every 30 minutes, when the app is open.
    static func push(force: Bool = false) async {
        // A T3 Code pairing has no server to keep the snapshot: nothing is read from the phone.
        guard Connection.current?.isDirect != true else { return }
        guard force || Date().timeIntervalSince(lastPush) > 1800 else { return }
        lastPush = Date()
        let iso = ISO8601DateFormatter()
        var calendar: [[String: Any]] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let start = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date().addingTimeInterval(-86400)
            let end = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date().addingTimeInterval(14 * 86400)
            let pred = events.predicateForEvents(withStart: start, end: end, calendars: nil)
            calendar = events.events(matching: pred).prefix(400).compactMap { e -> [String: Any]? in
                // EventKit hands the dates and the calendar over as implicitly unwrapped: an event missing one
                // (seen on broken subscribed calendars) would crash the app here.
                guard let from = e.startDate, let to = e.endDate else { return nil }
                var d: [String: Any] = ["title": e.title ?? "", "start": iso.string(from: from), "end": iso.string(from: to),
                                        "allDay": e.isAllDay, "calendar": e.calendar?.title ?? ""]
                if let l = e.location, !l.isEmpty { d["location"] = l }
                return d
            }
        }
        var contacts: [[String: Any]] = []
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: req) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let phones = c.phoneNumbers.map { $0.value.stringValue }
                let mails = c.emailAddresses.map { String($0.value) }
                if (name.isEmpty && c.organizationName.isEmpty) || (phones.isEmpty && mails.isEmpty) { return }
                contacts.append(["name": name.isEmpty ? c.organizationName : name, "org": c.organizationName, "phones": phones, "emails": mails])
            }
        }
        // Turned off while this was being read: nothing goes up after the server was told to forget.
        guard UserDefaults.standard.bool(forKey: "sharephone") else { return }
        if (try? await API.post("v1/phone/sync", ["calendar": calendar, "contacts": contacts])) == nil {
            // Not received: again in 5 minutes, not 30.
            lastPush = Date().addingTimeInterval(-1500)
        }
    }

    /// A name, number or address from a bot, turned into what the composer needs.
    static func resolve(_ to: String, mail: Bool) -> String {
        let t = to.trimmingCharacters(in: .whitespaces)
        if t.contains("@") || t.rangeOfCharacter(from: .letters) == nil { return t }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return t }
        let keys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let found = (try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: t), keysToFetch: keys)) ?? []
        guard let c = found.first else { return t }
        if mail { return c.emailAddresses.first.map { String($0.value) } ?? t }
        return c.phoneNumbers.first?.value.stringValue ?? c.emailAddresses.first.map { String($0.value) } ?? t
    }
}

// MARK: - The iPhone's own composers

struct MessageComposer: UIViewControllerRepresentable {
    let to: String
    let text: String
    var onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = [PhoneSync.resolve(to, mail: false)]
        vc.body = text
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone) }
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onDone: (Bool) -> Void
        init(_ f: @escaping (Bool) -> Void) { onDone = f }
        func messageComposeViewController(_ c: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            c.dismiss(animated: true); onDone(result == .sent)
        }
    }
}

struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let text: String
    var onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([PhoneSync.resolve(to, mail: true)])
        vc.setSubject(subject)
        vc.setMessageBody(text, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone) }
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDone: (Bool) -> Void
        init(_ f: @escaping (Bool) -> Void) { onDone = f }
        func mailComposeController(_ c: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            c.dismiss(animated: true); onDone(result == .sent)
        }
    }
}

struct EventComposer: UIViewControllerRepresentable {
    let draft: Draft
    var onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.eventStore = PhoneSync.events
        let e = EKEvent(eventStore: PhoneSync.events)
        e.title = draft.event
        let start = draft.start.flatMap(Ago.date) ?? Date()
        e.startDate = start
        e.endDate = draft.end.flatMap(Ago.date) ?? start.addingTimeInterval(3600)
        e.location = draft.location
        e.calendar = PhoneSync.events.defaultCalendarForNewEvents
        vc.event = e
        vc.editViewDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone) }
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: (Bool) -> Void
        init(_ f: @escaping (Bool) -> Void) { onDone = f }
        func eventEditViewController(_ c: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            c.dismiss(animated: true); onDone(action == .saved)
        }
    }
}

// MARK: - Settings

/// Settings. The server, notifications and About sections (SettingsSections.swift) always show; quiet hours,
/// the morning brief and quick replies live on the server and show once it has answered.
struct SettingsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sharephone") private var share = false
    @State private var busy = false
    /// Turning sharing off did not reach the server, so it is still on.
    @State private var shareStuck = false
    @State private var s: AppSettings?
    @State private var newReply = ""
    /// The server did not hand over its settings: said in their place, with a way to try again.
    @State private var loadFailed = false
    @State private var loading = false
    /// Paired with T3 Code itself: no T3 Bot server, so no morning brief and nowhere to share the phone's calendar.
    private var direct: Bool { Connection.current?.isDirect == true }

    var body: some View {
        NavigationStack {
            Form {
                SettingsConnectionSection(close: { dismiss() })
                SettingsNotificationsSection()
                if let binding = Binding($s) {
                    Section {
                        Toggle("Use quiet hours", isOn: binding.quiet.enabled).tint(.green)
                        if binding.wrappedValue.quiet.enabled {
                            DatePicker("From", selection: time(binding.quiet.from), displayedComponents: .hourAndMinute)
                            DatePicker("To", selection: time(binding.quiet.to), displayedComponents: .hourAndMinute)
                            Toggle("Alarms still ring", isOn: binding.quiet.alarms).tint(.green)
                        }
                    } header: {
                        ListHeader(text: "Quiet hours")
                    } footer: {
                        Text("Nothing contacts you in these hours: pushes wait and arrive as one summary when they end. Alarms are money at risk or something down.")
                    }
                    if !direct {
                    Section {
                        Toggle("Send a morning brief", isOn: binding.brief.enabled).tint(.green)
                        if binding.wrappedValue.brief.enabled {
                            Picker("When", selection: Binding(
                                get: { binding.wrappedValue.brief.at == "quiet-end" ? "quiet-end" : "time" },
                                set: { binding.wrappedValue.brief.at = $0 == "quiet-end" ? "quiet-end" : "08:00" })) {
                                Text("After quiet hours").tag("quiet-end")
                                Text("At a set time").tag("time")
                            }
                            if binding.wrappedValue.brief.at != "quiet-end" {
                                DatePicker("Time", selection: time(binding.brief.at), displayedComponents: .hourAndMinute)
                            }
                            Picker("Bot", selection: binding.brief.agent) {
                                // A server default that names no bot here ("chief" with no such bot) means the lead bot.
                                if store.agent(binding.wrappedValue.brief.agent) == nil {
                                    Text(store.agent(store.chiefId)?.name ?? "Lead bot").tag(binding.wrappedValue.brief.agent)
                                }
                                ForEach(briefBots(binding.wrappedValue.brief.agent)) { Text($0.name).tag($0.id) }
                            }
                        }
                    } header: {
                        ListHeader(text: "Morning brief")
                    } footer: {
                        Text("Five short lines: what needs you most today, anything broken, how the night went.")
                    }
                    }
                    Section {
                        ForEach(binding.wrappedValue.quickReplies, id: \.self) { Text($0) }
                            .onDelete { binding.wrappedValue.quickReplies.remove(atOffsets: $0) }
                            .onMove { binding.wrappedValue.quickReplies.move(fromOffsets: $0, toOffset: $1) }
                        if binding.wrappedValue.quickReplies.count < 6 {
                            HStack {
                                TextField("Add a reply", text: $newReply).submitLabel(.done).onSubmit { add(binding) }
                                Button("Add") { add(binding) }.disabled(newReply.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    } header: {
                        ListHeader(text: "Quick replies")
                    } footer: {
                        Text("Each bot suggests replies for its own last message. Replies you add here show when a bot asks you something and suggests none. Swipe one to remove it.")
                    }
                } else {
                    Section {
                        if loadFailed {
                            Label("Could not load these from the server.", systemImage: "wifi.slash").foregroundStyle(.secondary)
                            Button("Try again") { Task { @MainActor in await load() } }.disabled(loading)
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Loading").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        ListHeader(text: direct ? "Quiet hours and replies" : "Quiet hours, brief and replies")
                    } footer: {
                        Text(direct ? "Quiet hours and quick replies show once T3 Code answers."
                             : "Quiet hours, the morning brief and quick replies are kept on the server, so they show once it answers.")
                    }
                }
                if direct {
                    // One quiet line where the two server features would be, so nobody looks for them.
                    Section {
                        Text("The morning brief and sharing your calendar and contacts need a T3 Bot server. This phone is connected to T3 Code itself.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                Section {
                    Toggle("Share calendar and contacts", isOn: Binding(get: { share }, set: { v in
                        busy = true
                        Task {
                            if v { shareStuck = false; share = await PhoneSync.enable() } else {
                                let off = await PhoneSync.disable()
                                share = !off
                                shareStuck = !off
                            }
                            busy = false
                        }
                    }))
                    .tint(.green)
                    .disabled(busy)
                    if shareStuck {
                        Label("Still on: the server could not be reached to remove its copy. Try again when it is back.", systemImage: "wifi.slash")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    ListHeader(text: "Calendar and contacts")
                } footer: {
                    Text("Your bots can read your iPhone calendar (yesterday to two weeks ahead) and contacts, kept on your server only. They never send anything: they leave drafts that open in Messages, Mail or Calendar, and you press Send yourself.")
                }
                }
                SettingsAboutSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let s, s != store.settings { store.save(s) }
                        dismiss()
                    }
                }
            }
            .task {
                await load()
                if store.hello == nil { await store.loadHello() }
            }
            // The server came back while the sheet was open: its settings load without a tap.
            .onChange(of: store.online) { _, online in
                if online, s == nil { Task { @MainActor in await load() } }
            }
            // Swiping the sheet away keeps the changes too, not only Done.
            .onDisappear { if let s, s != store.settings { store.save(s) } }
        }
    }

    private func load() async {
        guard s == nil, !loading else { return }
        loading = true
        if store.settings == nil { await store.loadSettings() }
        s = store.settings
        loadFailed = s == nil
        loading = false
    }

    /// The bots a brief can come from. The one already chosen stays in the list even if it is gone or a group,
    /// so the picker never shows an empty choice.
    private func briefBots(_ chosen: String) -> [Agent] {
        let all = store.home?.agents ?? []
        return all.filter { $0.kind != "group" || $0.id == chosen }
    }

    private func add(_ b: Binding<AppSettings>) {
        let t = newReply.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !b.wrappedValue.quickReplies.contains(t) else { return }
        b.wrappedValue.quickReplies.append(t)
        newReply = ""
    }

    /// "HH:mm" as a Date for the time pickers.
    private func time(_ hhmm: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                let p = hhmm.wrappedValue.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: p.first ?? 8, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                hhmm.wrappedValue = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }
}
