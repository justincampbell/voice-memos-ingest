import XCTest
@testable import VMIngestCore

final class RecordingTests: XCTestCase {
    func testCoreDataEpochConversion() {
        // ZDATE 0 == 2001-01-01T00:00:00Z == unix 978307200.
        XCTAssertEqual(dateFromCoreData(0).timeIntervalSince1970, 978_307_200, accuracy: 0.0001)

        // A real sample from the DB: 802573455.963773 -> 2026-06-08T01:04:15Z.
        let d = dateFromCoreData(802_573_455.963773)
        let expected = ISO8601DateFormatter().date(from: "2026-06-08T01:04:15Z")!
        XCTAssertEqual(d.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }
}
