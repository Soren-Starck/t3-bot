import XCTest
@testable import T3Direct

final class TextTests: XCTestCase {
    func testPlainDropsMarkdown() {
        XCTAssertEqual(T3Text.plain("## Done\n**Shipped** `v2` with [notes](https://x.y) and read_file"), "Done Shipped v2 with notes and read_file")
        XCTAssertEqual(T3Text.plain("```\ncode\n```\nafter"), "after")
    }

    func testClipAtWord() {
        XCTAssertEqual(T3Text.clip("one two three four five six", 15), "one two three…")
        XCTAssertEqual(T3Text.clip("short", 15), "short")
    }

    func testPreviewPhotoOnly() {
        XCTAssertEqual(T3Text.preview("[Image from Soren: /tmp/a.png (open it to see it)]"), "Photo")
        XCTAssertEqual(T3Text.preview("Look\n![shot](/tmp/x.png)"), "Look")
    }

    func testSuggestions() {
        let s = T3Text.splitSuggestions("Ready to ship.\n» Ship it · Show me the diff · \"Not now\"")
        XCTAssertEqual(s.text, "Ready to ship.")
        XCTAssertEqual(s.suggestions ?? [], ["Ship it", "Show me the diff", "Not now"])
        XCTAssertNil(T3Text.splitSuggestions("No line here").suggestions)
    }

    func testImages() {
        let r = T3Text.splitImages("Here:\n![home](/Users/a/shot.png)\nDone")
        XCTAssertEqual(r.images?.first?.path, "/Users/a/shot.png")
        XCTAssertEqual(r.text, "Here:\n\nDone")
        let mine = T3Text.splitImages("Look\n[Image from Ada: /tmp/p.jpg (open it to see it)]", photosOnly: true)
        XCTAssertEqual(mine.images?.first?.path, "/tmp/p.jpg")
        XCTAssertEqual(mine.text, "Look")
    }

    func testAsks() {
        XCTAssertTrue(T3Text.asks("I fixed it. Shall I deploy?"))
        XCTAssertTrue(T3Text.asks("Two options:\n\n- A\n- B\n\nWhich one do you want?"))
        XCTAssertTrue(T3Text.asks("Here are the options. Let me know.\n\n- A\n- B"))
        XCTAssertFalse(T3Text.asks("Done. Deployed and checked."))
        XCTAssertEqual(T3Text.quickReplies("Deploy now?", own: nil, saved: ["Yes"]), ["Yes"])
        XCTAssertNil(T3Text.quickReplies("Deployed.", own: nil, saved: ["Yes"]))
    }

    func testSnippet() {
        let long = String(repeating: "word ", count: 80) + "needle here " + String(repeating: "tail ", count: 40)
        let s = T3Text.snippet(long, "needle", 60)
        XCTAssertTrue(s.contains("needle"))
        XCTAssertTrue(s.hasPrefix("…"))
    }

    func testSlash() {
        XCTAssertTrue(T3Text.isSlash("user", " /compact "))
        XCTAssertFalse(T3Text.isSlash("user", "/compact now please"))
        XCTAssertFalse(T3Text.isSlash("assistant", "/compact"))
    }
}

final class PairingParseTests: XCTestCase {
    func testDirectLink() {
        let p = T3Link.parse(link: "Scan: http://192.168.1.20:3773/pair#token=ABC123")
        XCTAssertEqual(p?.base.absoluteString, "http://192.168.1.20:3773")
        XCTAssertEqual(p?.code, "ABC123")
    }

    func testAppLink() {
        let inner = "https://mac.tail.ts.net/pair#token=XYZ"
        let link = "t3code://pair?pairingUrl=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let p = T3Link.parse(link: link)
        XCTAssertEqual(p?.base.absoluteString, "https://mac.tail.ts.net")
        XCTAssertEqual(p?.code, "XYZ")
    }

    func testHostedLink() {
        let p = T3Link.parse(link: "https://app.t3.codes/pair?host=prod-abc.t3coderelay.com#token=K1")
        XCTAssertEqual(p?.base.absoluteString, "https://prod-abc.t3coderelay.com")
        XCTAssertEqual(p?.code, "K1")
    }

    func testBaseURL() {
        XCTAssertEqual(T3Link.baseURL("https://prod-abc.t3coderelay.com/mcp")?.absoluteString, "https://prod-abc.t3coderelay.com")
        XCTAssertEqual(T3Link.baseURL("192.168.1.2:3773")?.absoluteString, "http://192.168.1.2:3773")
        XCTAssertEqual(T3Link.baseURL("mac.tail.ts.net")?.absoluteString, "https://mac.tail.ts.net")
        XCTAssertNil(T3Link.baseURL("not a url"))
        XCTAssertNil(T3Link.parse(link: "https://example.com/no-token"))
    }

    func testSegmentAndSocketURL() {
        XCTAssertEqual(T3Link.segment("mcp:a4f8-b"), "mcp%3Aa4f8-b")
        let u = T3Link.socketURL(URL(string: "https://x.t3coderelay.com")!, ticket: "t/+=")
        XCTAssertEqual(u.absoluteString, "wss://x.t3coderelay.com/ws?orchestrationProtocol=2&wsTicket=t%2F%2B%3D")
    }
}
