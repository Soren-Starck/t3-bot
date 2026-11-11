import Foundation

// Text helpers, ported from server/text.ts and server/t3bot.ts so a chat reads the same whether it comes from a
// T3 Bot server or straight from T3 Code: previews, plain lines, search snippets, quick replies, the "» " line of
// suggested replies and the images inside a message.

enum T3Text {
    // MARK: Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        // The patterns are constants written here: a bad one is a bug to see at once in the tests.
        let r = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = r
        return r
    }

    static func replace(_ s: String, _ pattern: String, _ with: String, _ options: NSRegularExpression.Options = []) -> String {
        re(pattern, options).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    static func matches(_ s: String, _ pattern: String, _ options: NSRegularExpression.Options = []) -> Bool {
        re(pattern, options).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Lines

    /// Cuts a line at a word boundary and marks the cut with an ellipsis. `max` counts the ellipsis.
    static func clip(_ t: String, _ max: Int) -> String {
        guard t.count > max, max > 1 else { return t }
        let cut = String(t.prefix(max - 1))
        let kept: String
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > Int(Double(max) * 0.6) {
            kept = String(cut[..<space])
        } else {
            kept = cut
        }
        return replace(kept, "[\\s·,;:(\\[-]+$", "") + "…"
    }

    /// A message as one line of plain text: no code blocks, images, link targets or markdown marks.
    static func plain(_ s: String, _ max: Int = 180) -> String {
        var t = replace(s, "```[\\s\\S]*?```", " ")
        t = replace(t, "!\\[[^\\]]*\\]\\([^)]*\\)", "")
        t = replace(t, "\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
        t = replace(t, "^[ \\t|:-]*-{2,}[ \\t|:-]*$", " ", .anchorsMatchLines)
        t = t.replacingOccurrences(of: "|", with: " ")
        t = replace(t, "^[ \\t]*(?:#{1,6}[ \\t]+|>[ \\t]?)+", "", .anchorsMatchLines)
        t = replace(t, "[*`]", "")
        t = replace(t, "(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])", "")
        t = replace(t, "\\s+", " ").trimmingCharacters(in: .whitespaces)
        return clip(t, max)
    }

    /// A command as one line, every character kept.
    static func oneLineCommand(_ s: String, _ max: Int = 120) -> String {
        clip(replace(s, "\\s+", " ").trimmingCharacters(in: .whitespaces), max)
    }

    private static let imageLines = "^[ \\t]*\\[Image from [^\\n]*$"

    /// A message as Home shows it under a bot's name; a message of nothing but pictures reads "Photo".
    static func preview(_ text: String, _ max: Int = 160, pictures: Int = 0) -> String {
        let hadPicture = pictures > 0 || matches(text, "!\\[[^\\]]*\\]\\([^)]*\\)") || matches(text, "^[ \\t]*\\[Image from ", .anchorsMatchLines)
        let t = plain(replace(text, imageLines, "", .anchorsMatchLines), max)
        return t.isEmpty ? (hadPicture ? "Photo" : "") : t
    }

    // MARK: Search snippets

    /// A message as one line that keeps apart what stood apart (rows, list items, paragraphs) with " · ".
    static func oneLine(_ s: String) -> String {
        var cleaned = replace(s, imageLines, "", .anchorsMatchLines)
        cleaned = replace(cleaned, "!\\[[^\\]]*\\]\\([^)]*\\)", "")
        cleaned = replace(cleaned, "\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
        var out = ""
        var prevText = false, gap = false, inCode = false
        for raw in cleaned.components(separatedBy: "\n") {
            if matches(raw, "^\\s*```") { inCode.toggle(); gap = true; continue }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { gap = true; continue }
            if !inCode, matches(raw, "^[\\s|:-]*-{2,}[\\s|:-]*$") { continue }
            let isRow = !inCode && matches(raw, "^\\s*\\|")
            let isItem = !inCode && matches(raw, "^\\s*(?:[-*+]|\\d+[.)])\\s+")
            var line = raw
            if !inCode {
                if isRow { line = tableRow(line) }
                line = replace(line, "^\\s*(?:[-*+]|\\d+[.)])\\s+", "")
                line = replace(line, "^\\s*#{1,6}\\s+", "")
                line = replace(line, "^\\s*>\\s?", "")
                line = replace(line, "[*`]", "")
                line = replace(line, "(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])", "")
            }
            line = replace(line, "\\s+", " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let isText = !isRow && !isItem && !inCode
            if !out.isEmpty {
                let wrapped = prevText && isText && !gap
                out += wrapped || matches(out, "[.!?…:,;]$") ? " " : " · "
            }
            out += line
            prevText = isText
            gap = false
        }
        return out
    }

    /// The words around the first match of `query`, on whole words, with an ellipsis at each cut end.
    /// A table row in words: its first cell, a colon, the other cells with commas ("Page weight: 2.6 MB, 610 KB").
    static func tableRow(_ raw: String) -> String {
        let inner = replace(replace(raw, "^\\s*\\|", ""), "\\|\\s*$", "")
        let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = cells.first else { return "" }
        return cells.count > 1 ? "\(first): \(cells.dropFirst().joined(separator: ", "))" : first
    }

    static func snippet(_ text: String, _ query: String, _ max: Int = 200) -> String {
        let flat = Array(oneLine(text))
        if flat.count <= max { return String(flat) }
        let q = replace(query.lowercased(), "\\s+", " ").trimmingCharacters(in: .whitespaces)
        let lower = Array(String(flat).lowercased())
        func index(of needle: [Character], in hay: [Character], from: Int = 0) -> Int {
            guard !needle.isEmpty, hay.count >= needle.count else { return -1 }
            var i = from
            while i <= hay.count - needle.count {
                if Array(hay[i..<(i + needle.count)]) == needle { return i }
                i += 1
            }
            return -1
        }
        func lastSpace(before i: Int) -> Int {
            var j = min(i, flat.count - 1)
            while j >= 0 { if flat[j] == " " { return j }; j -= 1 }
            return -1
        }
        func nextSpace(from i: Int) -> Int {
            var j = i
            while j < flat.count { if flat[j] == " " { return j }; j += 1 }
            return -1
        }
        let qa = Array(q)
        let hit = Swift.max(0, q.isEmpty ? -1 : index(of: qa, in: lower))
        let lead = Swift.min(60, max / 3)
        var from = Swift.max(0, hit - lead)
        if from > 0, flat[from - 1] != " " {
            let next = nextSpace(from: from)
            if next >= 0, next < hit { from = next + 1 } else {
                let wordStart = lastSpace(before: hit) + 1
                from = hit - wordStart <= lead ? wordStart : hit
            }
        }
        var to = Swift.min(flat.count, from + max)
        if to < flat.count, flat[to] != " " {
            let space = lastSpace(before: to)
            if space > hit + qa.count, space > from { to = space }
        }
        if to == flat.count, from > 0 {
            let back = Swift.max(0, to - max)
            let next = back == 0 ? -1 : nextSpace(from: back)
            from = back == 0 ? 0 : (next >= 0 && next < from ? next + 1 : from)
        }
        var body = String(flat[from..<to])
        body = replace(body, "^[·\\s]+", "")
        body = replace(body, "[\\s·,;:(\\[-]+$", "")
        return (from > 0 ? "…" : "") + body + (to < flat.count ? "…" : "")
    }

    // MARK: Quick replies

    private static let choice = "\\b(?:let me know|tell me (?:which|what|if|whether|when|how|where)|which (?:one|do you|would you|should)|your call|up to you|pick one|choose (?:one|between)|should i|shall i|do you want|would you like|want me to|say the word|ok(?:ay)? to (?:go|send|ship|merge|proceed))\\b"
    private static let question = "\\?[\"”')\\]*_]*$"

    /// True when a message ends by asking the person something: a question, or a request to choose.
    static func asks(_ text: String) -> Bool {
        var t = replace(text, "```[\\s\\S]*?```", "")
        t = replace(t, "!\\[[^\\]]*\\]\\([^)]*\\)", "")
        t = replace(t, imageLines, "", .anchorsMatchLines)
        let blocks = re("\\n[ \\t]*\\n").stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "\u{0}")
            .components(separatedBy: "\u{0}").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = blocks.last else { return false }
        func isList(_ b: String) -> Bool {
            b.components(separatedBy: "\n").allSatisfy { matches($0, "^\\s*(?:[-*+]\\s|\\d+[.)]\\s|\\|)") }
        }
        let tail = isList(last) && blocks.count > 1 ? [blocks[blocks.count - 2]] : [last]
        return tail.contains { b in
            let flat = replace(b, "\\s+", " ")
            let parts = re("(?<=[.!?…][\"”')\\]*_]{0,3})\\s+").stringByReplacingMatches(in: flat, range: NSRange(flat.startIndex..., in: flat), withTemplate: "\u{0}")
                .components(separatedBy: "\u{0}").filter { !$0.isEmpty }
            return parts.suffix(2).contains { matches($0, question) || matches($0, choice, .caseInsensitive) }
        }
    }

    /// The quick replies under a bot's last answer: its own suggestions, else the saved ones when it asks something.
    static func quickReplies(_ text: String, own: [String]?, saved: [String]) -> [String]? {
        if let own, !own.isEmpty { return own }
        return !saved.isEmpty && asks(text) ? saved : nil
    }

    // MARK: Inside a message

    /// A bot ends a message with its suggested replies on one last line: "» Yes, send it · Show me the draft".
    static func splitSuggestions(_ text: String) -> (text: String, suggestions: [String]?) {
        var lines = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).components(separatedBy: "\n")
        let last = lines.last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard last.hasPrefix("»") else { return (text, nil) }
        let items = re("\\s[·|]\\s").stringByReplacingMatches(in: String(last.dropFirst()), range: NSRange(String(last.dropFirst()).startIndex..., in: String(last.dropFirst())), withTemplate: "\u{0}")
            .components(separatedBy: "\u{0}")
            .map { replace($0.trimmingCharacters(in: .whitespaces), "^[\"“]|[\"”]$", "") }
            .filter { !$0.isEmpty && $0.count <= 60 }
        lines.removeLast()
        let body = lines.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return (body, items.isEmpty ? nil : Array(items.prefix(4)))
    }

    private static let mdImage = "!\\[([^\\]]*)\\]\\((/[^)\\s]+\\.(?:png|jpe?g|gif|webp|heic))\\)"
    private static let sentImage = "^\\[Image from [^:\\]\\n]{1,60}: (/[^\\s]+\\.(?:png|jpe?g))[^\\]]*\\]\\s*$"

    /// Images in a message: markdown images with an absolute path, and the photos the person attached.
    static func splitImages(_ text: String, photosOnly: Bool = false) -> (text: String, images: [EntryImage]?) {
        var images: [EntryImage] = []
        var t = text
        if !photosOnly {
            let r = re(mdImage, .caseInsensitive)
            for m in r.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                if let alt = Range(m.range(at: 1), in: t), let path = Range(m.range(at: 2), in: t) {
                    images.append(EntryImage(path: String(t[path]), alt: String(t[alt])))
                }
            }
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        let s = re(sentImage, [.caseInsensitive, .anchorsMatchLines])
        for m in s.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            if let path = Range(m.range(at: 1), in: t) { images.append(EntryImage(path: String(t[path]), alt: "")) }
        }
        t = s.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        guard !images.isEmpty else { return (text, nil) }
        return (replace(t, "\\n{3,}", "\n\n").trimmingCharacters(in: .whitespacesAndNewlines), images)
    }

    /// `/compact` and other bare slash commands: plumbing, never shown.
    static func isSlash(_ role: String, _ text: String) -> Bool {
        role == "user" && matches(text.trimmingCharacters(in: .whitespacesAndNewlines), "^/[a-z-]+$")
    }
}
