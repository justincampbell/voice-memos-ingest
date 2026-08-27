import XCTest
@testable import VMIngestCore

final class ProducerStateTests: XCTestCase {
    private func rec(_ id: String) -> Recording {
        Recording(id: id, recordedAt: Date(timeIntervalSince1970: 0), duration: 1, title: id, m4aPath: "/tmp/\(id).m4a")
    }

    func testFirstRunFlagWhenNoFile() throws {
        let path = NSTemporaryDirectory() + "vmingest-test-\(UUID().uuidString)/seen.json"
        let state = try ProducerState.load(path: path)
        XCTAssertTrue(state.isFirstRun)
        XCTAssertTrue(state.seen.isEmpty)
    }

    func testDiffExcludesSeen() {
        let all = [rec("a"), rec("b"), rec("c")]
        let state = ProducerState(seen: ["a", "c"], isFirstRun: false)
        XCTAssertEqual(state.newRecordings(from: all).map { $0.id }, ["b"])
    }

    func testSaveLoadRoundTrip() throws {
        let path = NSTemporaryDirectory() + "vmingest-test-\(UUID().uuidString)/seen.json"
        var state = ProducerState(seen: [], isFirstRun: true)
        state.markSeen(["x", "y", "z"])
        try state.save(path: path)

        let reloaded = try ProducerState.load(path: path)
        XCTAssertFalse(reloaded.isFirstRun)
        XCTAssertEqual(reloaded.seen, ["x", "y", "z"])
        // After bootstrap, nothing is new.
        XCTAssertTrue(reloaded.newRecordings(from: [rec("x"), rec("y")]).isEmpty)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
