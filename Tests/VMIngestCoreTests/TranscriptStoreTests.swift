import XCTest
@testable import VMIngestCore

final class TranscriptStoreTests: XCTestCase {
    private func record(_ id: String, title: String = "t", text: String = "hello") -> TranscriptRecord {
        TranscriptRecord(
            id: id, recordedAt: "2026-06-08T01:04:15Z", duration: 7.0, title: title,
            source: .apple, text: text, appleText: nil, ourText: nil,
            transcribedAt: "2026-06-16T00:00:00Z"
        )
    }

    /// Fresh temp file seeded with the given records via the real writer.
    private func store(_ records: [TranscriptRecord]) throws -> TranscriptStore {
        let path = NSTemporaryDirectory() + "vmstore-\(UUID().uuidString)/transcripts.jsonl"
        for r in records { try JSONLWriter.append(r, to: path) }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        return TranscriptStore(path: path)
    }

    func testMissingFileIsEmptyNotAnError() {
        let store = TranscriptStore(path: NSTemporaryDirectory() + "does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(store.recent().isEmpty)
        XCTAssertNil(store.get(id: "x"))
    }

    func testRecentIsNewestFirstAndLimited() throws {
        let store = try store([record("a"), record("b"), record("c")])
        XCTAssertEqual(store.recent(limit: 2).map(\.id), ["c", "b"])
        XCTAssertEqual(store.count(), 3)
    }

    func testGetById() throws {
        let store = try store([record("a"), record("b")])
        XCTAssertEqual(store.get(id: "b")?.id, "b")
        XCTAssertNil(store.get(id: "zzz"))
    }

    func testSearchMatchesTextAndTitleCaseInsensitively() throws {
        let store = try store([
            record("a", title: "Groceries", text: "buy milk"),
            record("b", title: "Work", text: "Email the TEAM"),
        ])
        XCTAssertEqual(store.search(query: "milk").map(\.id), ["a"])
        XCTAssertEqual(store.search(query: "team").map(\.id), ["b"])
        XCTAssertEqual(store.search(query: "grocer").map(\.id), ["a"])
        XCTAssertTrue(store.search(query: "nope").isEmpty)
    }

    func testSinceCursorReturnsTailAndAdvances() throws {
        let store = try store([record("a"), record("b"), record("c")])
        let r1 = store.since(cursor: 1)
        XCTAssertEqual(r1.records.map(\.id), ["b", "c"]) // oldest-first
        XCTAssertEqual(r1.cursor, 3)

        // At the tail: nothing new, cursor unchanged.
        let r2 = store.since(cursor: 3)
        XCTAssertTrue(r2.records.isEmpty)
        XCTAssertEqual(r2.cursor, 3)

        // nil cursor means from the beginning.
        XCTAssertEqual(store.since(cursor: nil).records.map(\.id), ["a", "b", "c"])
    }

    func testSinceClampsNegativeAndOverrunCursors() throws {
        let store = try store([record("a"), record("b")])

        // A negative cursor clamps to the beginning rather than trapping.
        let negative = store.since(cursor: -5)
        XCTAssertEqual(negative.records.map(\.id), ["a", "b"])
        XCTAssertEqual(negative.cursor, 2)

        // A cursor past the end yields nothing and reports the real tail, so a
        // consumer that over-saved its cursor recovers instead of re-reading.
        let overrun = store.since(cursor: 99)
        XCTAssertTrue(overrun.records.isEmpty)
        XCTAssertEqual(overrun.cursor, 2)
    }

    func testZeroAndNegativeLimitsReturnNothing() throws {
        let store = try store([record("a"), record("b")])
        XCTAssertTrue(store.recent(limit: 0).isEmpty)
        XCTAssertTrue(store.recent(limit: -1).isEmpty)
        XCTAssertTrue(store.search(query: "hello", limit: 0).isEmpty)
    }

    func testMalformedLinesAreSkippedNotFatal() throws {
        // Written with the real writer, then corrupted: a truncated final line
        // is exactly what an in-flight append looks like to a concurrent
        // reader, and it must not break the whole query.
        let store = try store([record("a"), record("b")])
        let handle = FileHandle(forWritingAtPath: store.path)
        XCTAssertNotNil(handle)
        try handle?.seekToEnd()
        try handle?.write(contentsOf: Data("not json at all\n{\"id\":\"truncated\"".utf8))
        try handle?.close()

        XCTAssertEqual(store.all().map(\.id), ["a", "b"])
        XCTAssertEqual(store.count(), 2)
        // The cursor still reflects only the valid records, so a consumer
        // never advances past a line it couldn't read.
        XCTAssertEqual(store.since(cursor: 0).cursor, 2)
    }
}
