import PhotosUI
import SwiftUI
import UIKit

/// Small parts of the chat screen: what a long press on a message offers, the sheet to select part of a message,
/// the dots of the working line, a photo waiting in the composer, and the screen for a chat that did not load.

// MARK: - Copy

@MainActor
enum ChatCopy {
    /// Copies a message and says so in the bar at the bottom, for a moment.
    static func text(_ s: String, _ store: Store) {
        UIPasteboard.general.string = s
        confirm(store)
    }

    static func image(_ img: UIImage, _ store: Store) {
        UIPasteboard.general.image = img
        confirm(store)
    }

    private static func confirm(_ store: Store) {
        Haptics.tap()
        let shown = Store.Toast(text: "Copied")
        store.toast = shown
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            // Only this one: a newer message in the bar (a send that failed, an Undo) stays.
            if store.toast == shown { store.toast = nil }
        }
    }
}

// MARK: - Long press on a message

/// Copy, Share and Select Text on a message bubble.
struct ChatMessageMenu: ViewModifier {
    let text: String
    @EnvironmentObject var store: Store
    @State private var selecting = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { ChatCopy.text(text, store) } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                Button { selecting = true } label: { Label("Select Text", systemImage: "character.cursor.ibeam") }
            }
            .sheet(isPresented: $selecting) { ChatSelectText(text: text) }
    }
}

extension View {
    /// The long-press menu of a message. Off for bubbles that carry their own menu (a message that was not sent).
    @ViewBuilder
    func chatMessageMenu(_ text: String, on: Bool = true) -> some View {
        if on { modifier(ChatMessageMenu(text: text)) } else { self }
    }
}

/// A message as plain selectable text, to copy one line or one command out of it.
struct ChatSelectText: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableText(text: text)
                .padding(.horizontal, 16)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.backgroundColor = .clear
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 24, right: 0)
        v.textContainer.lineFragmentPadding = 0
        v.alwaysBounceVertical = true
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}

// MARK: - Working line

/// Three dots that light up in turn while a bot works.
struct ChatTypingDots: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative, options: .repeating)
            .accessibilityHidden(true)
    }
}

// MARK: - Composer

/// One photo waiting in the composer. Known by its own id, so removing one never removes its neighbour.
struct ChatAttachment: Identifiable {
    let id = UUID()
    /// The photo picker's item; nil for a photo put back from a message that was not sent.
    var item: PhotosPickerItem?
    /// The JPEG that will be sent; nil while the photo is still loading.
    var data: Data?
    /// What the composer shows, made once and not on every redraw.
    var thumb: UIImage?

    /// A small square-ish copy for the composer's strip.
    static func thumbnail(_ img: UIImage) -> UIImage {
        let shortest = min(img.size.width, img.size.height)
        guard shortest > 0 else { return img }
        let k = min(1, 168 / shortest)
        let size = CGSize(width: img.size.width * k, height: img.size.height * k)
        return img.preparingThumbnail(of: size) ?? img
    }
}

// MARK: - A chat that did not load

struct ChatLoadFailed: View {
    let online: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: online ? "exclamationmark.bubble" : "wifi.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Can't load this chat").font(.headline)
            Text(online ? "The server did not answer." : "The server cannot be reached right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.glass)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.horizontal, 24)
    }
}
