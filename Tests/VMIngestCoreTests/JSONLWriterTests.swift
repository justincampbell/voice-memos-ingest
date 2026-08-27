import XCTest
@testable import VMIngestCore

final class JSONLWriterTests: XCTestCase {
    private func record(_ id: String, source: TranscriptSource = .apple, both: Bool = false) -> TranscriptRecord {
        TranscriptRecord(
            id: id, recordedAt: "2026-06-08T01:04:15Z", duration: 7.0, title: "t",
            source: source, text: "hello",
            appleText: both ? "hello" : nil, ourText: both ? "hi" : nil,
            transcribedAt: "2026-06-16T00:00:00Z"
        )
    }

    func testOmitsNilTextsWhenNotDoubled() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(record("a")), encoding: .utf8)!
        XCTAssertFalse(json.contains("apple_text"))
        XCTAssertFalse(json.contains("our_text"))
        XCTAssertTrue(json.contains("\"source\":\"apple\""))
    }

    func testIncludesBothTextsWhenDoubled() throws {
        let json = String(data: try JSONEncoder().encode(record("a", both: true)), encoding: .utf8)!
        XCTAssertTrue(json.contains("apple_text"))
        XCTAssertTrue(json.contains("our_text"))
    }

    func testAppendIsAdditiveAndImmutable() throws {
        let path = NSTemporaryDirectory() + "vmingest-test-\(UUID().uuidString)/transcripts.jsonl"
        let first = try JSONLWriter.append(record("a"), to: path)
        let bytesAfterFirst = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try JSONLWriter.append(record("b"), to: path)
        let bytesAfterSecond = try Data(contentsOf: URL(fileURLWithPath: path))

        // First line's bytes are a prefix of the file after the second append.
        XCTAssertTrue(bytesAfterSecond.starts(with: bytesAfterFirst))
        let lines = String(data: bytesAfterSecond, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0]), first)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
