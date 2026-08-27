import XCTest
@testable import VMIngestCore

final class AppleNoteMirrorTests: XCTestCase {
    func testHtmlEscape() {
        XCTAssertEqual(AppleNoteMirror.htmlEscape("a < b & c > d"), "a &lt; b &amp; c &gt; d")
    }

    func testAppleScriptEscape() {
        XCTAssertEqual(AppleNoteMirror.appleScriptEscape("say \"hi\" \\ ok"), "say \\\"hi\\\" \\\\ ok")
    }

    func testDisabledIsNoOp() throws {
        var config = Config.defaults()
        config.appleNoteEnabled = false
        let record = TranscriptRecord(
            id: "a", recordedAt: "2026-06-08T01:04:15Z", duration: 1, title: "t",
            source: .apple, text: "x", appleText: nil, ourText: nil, transcribedAt: "2026-06-16T00:00:00Z"
        )
        XCTAssertFalse(try AppleNoteMirror.append(record, config: config))
    }
}
