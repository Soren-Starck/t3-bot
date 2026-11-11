import SwiftUI
import UIKit

/// Markdown as bots write it, made readable on a phone.
///
/// Two ways in: `Markdown.render` gives one attributed string (previews, small lines, anything with a line limit),
/// and `MarkdownView` lays a whole message out block by block: paragraphs, headings, bulleted, numbered and nested
/// lists, task lists, fenced code with a copy button, tables that scroll sideways, quotes and rules.
enum Markdown {
    // MARK: - One attributed string

    /// Inline markdown (bold, italic, code, links) in a single text, with the block bits made readable:
    /// "- item" becomes "• item", "## Title" a bold line, "> quote" loses its mark and code fences their marker lines.
    /// A "#" with no space after it is left alone, so thread names such as "#deploys" stay as written.
    static func render(_ s: String) -> AttributedString {
        var inFence = false
        let lines = s.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            if fence(t) != nil { inFence.toggle(); return nil }
            if inFence { return line }
            if let item = listItem(line) {
                let pad = String(repeating: " ", count: min(item.indent, 8))
                let mark = item.checked == true ? "☑" : item.checked == false ? "☐" : item.marker
                return pad + mark + " " + item.text
            }
            if let h = heading(t) { return "**" + h.title.replacingOccurrences(of: "**", with: "") + "**" }
            if t.hasPrefix(">") { return String(t.dropFirst().drop(while: { $0 == " " })) }
            return line
        }
        return inline(lines.joined(separator: "\n"))
    }

    /// Bold, italic, strikethrough, inline code and links in one run of text. Line breaks are kept as written,
    /// inline code gets a quiet background, and a bare web address becomes a link.
    static func inline(_ s: String) -> AttributedString {
        if let hit = inlineCache.object(forKey: s as NSString) { return hit.value }
        var out = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        var code: [Range<AttributedString.Index>] = []
        for run in out.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) { code.append(run.range) }
        }
        for r in code { out[r][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color(.tertiarySystemFill) }
        linkify(&out)
        // Links in the text colour (the app's one accent), underlined so they still read as links.
        let links = out.runs.filter { $0.link != nil }.map(\.range)
        for r in links { out[r].underlineStyle = .single }
        inlineCache.setObject(InlineBox(out), forKey: s as NSString)
        return out
    }

    /// The same text with the markdown marks gone, for measuring and for VoiceOver.
    static func plain(_ s: String) -> String { String(inline(s).characters) }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkify(_ out: inout AttributedString) {
        let text = String(out.characters)
        guard text.contains("://") || text.contains("www."), let detector else { return }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        for m in detector.matches(in: text, options: [], range: whole) {
            guard let url = m.url, url.scheme == "http" || url.scheme == "https",
                  let r = Range<AttributedString.Index>(m.range, in: out) else { continue }
            // A link the bot wrote itself keeps its own target.
            if out[r].runs.contains(where: { $0.link != nil }) { continue }
            out[r][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
        }
    }

    // MARK: - Blocks

    struct ListItem: Hashable {
        /// 0 for the list itself, 1 for a list inside it, and so on.
        var level: Int
        /// "•" or "3."
        var marker: String
        var ordered: Bool
        /// A task list item: true when ticked. Nil for a normal item.
        var checked: Bool?
        var text: String
    }

    enum Block: Hashable {
        case paragraph(String)
        case heading(Int, String)
        case list([ListItem])
        case code(language: String?, text: String)
        case table(header: [String], rows: [[String]])
        case quote(String)
        case rule
    }

    /// A message cut into blocks. Kept in memory: a chat redraws often and its messages do not change.
    static func blocks(_ source: String) -> [Block] {
        if let hit = blockCache.object(forKey: source as NSString) { return hit.value }
        let out = parse(source)
        blockCache.setObject(BlockBox(out), forKey: source as NSString)
        return out
    }

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var indents: [Int] = []

        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para = []
        }
        func flushQuote() {
            let t = quote.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.quote(t)) }
            quote = []
        }
        func flushList() {
            if !items.isEmpty { out.append(.list(items)) }
            items = []
            indents = []
        }
        func flushAll() { flushPara(); flushQuote(); flushList() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // Fenced code. A fence that never closes (a message cut short) runs to the end.
            if let mark = fence(t) {
                flushAll()
                let info = String(t.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                if info.count > mark.count, info.hasSuffix(mark) {
                    // ```one line```
                    out.append(.code(language: nil, text: String(info.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
                let pad = line.prefix(while: { $0 == " " }).count
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(mark) {
                    var l = Substring(lines[i])
                    var cut = 0
                    while cut < pad, l.first == " " { l = l.dropFirst(); cut += 1 }
                    body.append(String(l))
                    i += 1
                }
                i += 1
                while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }
                let language = info.split(separator: " ").first.map { String($0.prefix(20)) }
                out.append(.code(language: language, text: body.joined(separator: "\n")))
                continue
            }

            if t.isEmpty {
                // A blank line ends a paragraph or a quote; a list goes on if another item follows.
                flushPara(); flushQuote()
                i += 1
                continue
            }

            if isRule(t) {
                flushAll()
                out.append(.rule)
                i += 1
                continue
            }

            if let h = heading(t) {
                flushAll()
                out.append(.heading(h.level, h.title))
                i += 1
                continue
            }

            // A table: a row of cells, then the line of dashes under it.
            if t.contains("|"), i + 1 < lines.count, isTableDelimiter(lines[i + 1]) {
                let header = tableCells(t)
                if header.count == tableCells(lines[i + 1]).count {
                    flushAll()
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < lines.count {
                        let r = lines[j].trimmingCharacters(in: .whitespaces)
                        guard !r.isEmpty, r.contains("|") else { break }
                        var cells = tableCells(r)
                        while cells.count < header.count { cells.append("") }
                        rows.append(Array(cells.prefix(header.count)))
                        j += 1
                    }
                    out.append(.table(header: header, rows: rows))
                    i = j
                    continue
                }
            }

            if t.hasPrefix(">") {
                flushPara(); flushList()
                quote.append(String(t.dropFirst().drop(while: { $0 == " " })))
                i += 1
                continue
            }

            if let item = listItem(line) {
                flushPara(); flushQuote()
                while let last = indents.last, last > item.indent { indents.removeLast() }
                if let last = indents.last { if last < item.indent { indents.append(item.indent) } } else { indents.append(item.indent) }
                items.append(ListItem(level: min(indents.count - 1, 4), marker: item.marker, ordered: item.ordered, checked: item.checked, text: item.text))
                i += 1
                continue
            }

            // An indented line right under an item belongs to that item.
            if !items.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                items[items.count - 1].text += "\n" + t
                i += 1
                continue
            }

            flushList(); flushQuote()
            para.append(t)
            i += 1
        }
        flushAll()
        return out
    }

    // MARK: - Line shapes

    /// "```" or "~~~" (or longer) opening or closing a code block.
    static func fence(_ t: String) -> String? {
        for c in ["`", "~"] as [Character] {
            let n = t.prefix(while: { $0 == c }).count
            if n >= 3 { return String(repeating: String(c), count: n) }
        }
        return nil
    }

    /// "## Title": one to six "#", then a space. Anything else that starts with "#" is ordinary text.
    static func heading(_ t: String) -> (level: Int, title: String)? {
        let level = t.prefix(while: { $0 == "#" }).count
        guard level >= 1, level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.first == " " else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of "#" only counts after a space ("## Title ##"): "Learning C#" keeps its sharp.
        let closing = title.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let head = title.dropLast(closing)
            if head.isEmpty || head.last == " " { title = String(head) }
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }
        return (level: level, title: title)
    }

    /// "---", "***" or "___" alone on a line.
    static func isRule(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let first = s.first, first == "-" || first == "*" || first == "_" else { return false }
        return s.allSatisfy { $0 == first }
    }

    /// "- text", "* text", "+ text", "1. text", "2) text", with "[ ]" and "[x]" for task lists.
    static func listItem(_ line: String) -> (indent: Int, marker: String, ordered: Bool, checked: Bool?, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            indent += c == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        guard let first = rest.first else { return nil }
        if first == "-" || first == "*" || first == "+" || first == "•" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            var text = after.drop(while: { $0 == " " })
            var checked: Bool?
            if text.hasPrefix("[ ] ") { checked = false; text = text.dropFirst(4) }
            else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { checked = true; text = text.dropFirst(4) }
            guard !text.isEmpty else { return nil }
            return (indent, "•", false, checked, String(text))
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let sep = after.first, sep == "." || sep == ")" else { return nil }
        let body = after.dropFirst()
        guard body.first == " " else { return nil }
        let text = body.drop(while: { $0 == " " })
        guard !text.isEmpty else { return nil }
        return (indent, String(digits) + ".", true, nil, String(text))
    }

    /// The "| --- | :---: |" line under a table's header.
    static func isTableDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        let cells = tableCells(t)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { c in c.contains("-") && c.allSatisfy { $0 == "-" || $0 == ":" } }
    }

    /// The cells of one table row. A "|" inside inline code or written "\|" does not split.
    static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        let chars = Array(t)
        var cells: [String] = []
        var current = ""
        var inCode = false
        var k = 0
        while k < chars.count {
            let ch = chars[k]
            if ch == "\\", k + 1 < chars.count, chars[k + 1] == "|" {
                current.append("|")
                k += 2
                continue
            }
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            k += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Memory

    private final class InlineBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private final class BlockBox {
        let value: [Block]
        init(_ value: [Block]) { self.value = value }
    }

    private static let inlineCache: NSCache<NSString, InlineBox> = {
        let c = NSCache<NSString, InlineBox>()
        c.countLimit = 600
        return c
    }()

    private static let blockCache: NSCache<NSString, BlockBox> = {
        let c = NSCache<NSString, BlockBox>()
        c.countLimit = 300
        return c
    }()
}

/// A whole message, block by block. A message that is one plain paragraph stays a single text.
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = Markdown.blocks(text)
        if blocks.count == 1, case let .paragraph(p) = blocks[0] {
            Text(Markdown.inline(p))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    block(b)
                }
            }
        }
    }

    @ViewBuilder
    private func block(_ b: Markdown.Block) -> some View {
        switch b {
        case let .paragraph(t):
            Text(Markdown.inline(t)).fixedSize(horizontal: false, vertical: true)
        case let .heading(level, t):
            Text(Markdown.inline(t))
                .font(level <= 1 ? Font.title3.weight(.semibold) : level == 2 ? Font.headline : Font.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        case let .list(items):
            MarkdownList(items: items)
        case let .code(language, code):
            MarkdownCode(language: language, code: code)
        case let .table(header, rows):
            MarkdownTable(header: header, rows: rows)
        case let .quote(t):
            Text(Markdown.inline(t))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// Bulleted, numbered, nested and task lists. Numbers line up on their dot.
private struct MarkdownList: View {
    let items: [Markdown.ListItem]

    var body: some View {
        let widest = items.filter(\.ordered).map(\.marker).max { $0.count < $1.count }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(item, widest: widest)
                    Text(Markdown.inline(item.text)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: Markdown.ListItem, widest: String?) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityLabel(checked ? "Done" : "To do")
        } else if item.ordered {
            ZStack(alignment: .trailing) {
                Text(widest ?? item.marker).monospacedDigit().hidden()
                Text(item.marker).monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            // Drawn only: VoiceOver read each one as "bullet" before the line.
            Text(item.level == 0 ? "•" : "◦").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// A fenced code block: monospaced, scrolls sideways instead of wrapping, with its language and a copy button.
struct MarkdownCode: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "Code")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minHeight: 32)
                        // 44 points to the finger; the room is taken back from the layout, so nothing moves.
                        .padding(6)
                        .contentShape(Rectangle())
                        .padding(-6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, 12).padding(.trailing, 12)
            if Self.wraps(code) {
                // Short lines wrap where they must: nothing is cut at the box's edge.
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                }
                // A long line fades out at the box's edge (and scrolls), instead of running into it.
                .mask {
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
    }

    /// Short command lines wrap; code (indented, or with long lines) keeps its lines and scrolls sideways:
    /// wrapped, `sizes="(max-width: 768px)` broke across two lines and lost its indentation.
    static func wraps(_ code: String) -> Bool {
        let lines = code.components(separatedBy: "\n")
        let indented = lines.contains { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
        return !indented && (lines.map(\.count).max() ?? 0) <= 48
    }

    private func copy() {
        UIPasteboard.general.string = code
        Haptics.tap()
        withAnimation(.easeInOut(duration: 0.2)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeInOut(duration: 0.2)) { copied = false }
        }
    }
}

/// A table that keeps its columns: each one as wide as its longest cell (up to a cap, then the cell wraps),
/// and the whole table scrolls sideways when the phone is too narrow for it.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        let widths = columnWidths()
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                line(header, widths: widths, bold: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    line(row, widths: widths, bold: false)
                        .overlay(alignment: .top) { Divider() }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemFill)))
    }

    private func line(_ cells: [String], widths: [CGFloat], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<columns, id: \.self) { c in
                Text(Markdown.inline(c < cells.count ? cells[c] : ""))
                    .font(bold ? Font.footnote.weight(.semibold) : Font.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: c < widths.count ? widths[c] : 80, alignment: .leading)
                    .accessibilityAddTraits(bold ? .isHeader : [])
            }
        }
        .padding(.vertical, 8)
    }

    /// Measured with the same text size the cells are drawn at, so it follows Dynamic Type.
    private func columnWidths() -> [CGFloat] {
        let body = UIFont.preferredFont(forTextStyle: .footnote)
        let bold = UIFont.systemFont(ofSize: body.pointSize, weight: .semibold)
        let cap = body.pointSize * 17
        return (0..<columns).map { c in
            var w = Self.width(c < header.count ? header[c] : "", bold)
            for r in rows where c < r.count { w = max(w, Self.width(r[c], body)) }
            return min(max(w + 6, 28), cap)
        }
    }

    private static func width(_ cell: String, _ font: UIFont) -> CGFloat {
        ceil((Markdown.plain(cell) as NSString).size(withAttributes: [.font: font]).width)
    }
}
