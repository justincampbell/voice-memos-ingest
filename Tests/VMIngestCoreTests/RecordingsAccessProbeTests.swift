import Synchronization
import XCTest
@testable import VMIngestCore

final class RecordingsAccessProbeTests: XCTestCase {
    private var tempDir: URL!
    private var dbPath: String { tempDir.appendingPathComponent("CloudRecordings.db").path }

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - RecordingsAccessProbe

    func testProbeTrueWhenDatabasePresent() async throws {
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("CloudRecordings.db").path, contents: Data()
        )
        let ok = await RecordingsAccessProbe.probe(recordingsDir: tempDir.path)
        XCTAssertTrue(ok)
    }

    func testProbeFalseWhenDatabaseMissing() async throws {
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("something-else.m4a").path, contents: Data()
        )
        let ok = await RecordingsAccessProbe.probe(recordingsDir: tempDir.path)
        XCTAssertFalse(ok)
    }

    func testProbeFalseForNonexistentDirectory() async throws {
        let ok = await RecordingsAccessProbe.probe(
            recordingsDir: tempDir.appendingPathComponent("does-not-exist").path
        )
        XCTAssertFalse(ok)
    }

    // MARK: - BlockingWork

    func testValueReturnsOperationResultWhenFast() async {
        let value = await BlockingWork.value(within: .seconds(5), fallback: -1) { 42 }
        XCTAssertEqual(value, 42)
    }

    /// The whole point of BlockingWork: a hung operation must not hang the
    /// caller. The fallback has to arrive at the deadline, not when the
    /// blocked thread finally returns.
    func testValueReturnsFallbackWhenOperationHangs() async {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await BlockingWork.value(within: .milliseconds(100), fallback: "timed-out") {
            Thread.sleep(forTimeInterval: 0.5)
            return "finished"
        }
        XCTAssertEqual(value, "timed-out")
        XCTAssertLessThan(
            clock.now - start, .milliseconds(450),
            "fallback must arrive at the deadline, not after the hang"
        )
        // Let the abandoned operation finish inside the test so its late
        // resume attempt runs now — a broken once-only guard would crash here
        // (a continuation may only be resumed once).
        try? await Task.sleep(for: .milliseconds(600))
    }

    /// The mirror image of the hang test: an operation finishing well before
    /// the deadline wins, and the timeout firing later must be discarded.
    func testLateTimeoutAfterCompletionIsDiscarded() async {
        let value = await BlockingWork.value(within: .milliseconds(100), fallback: -1) { 7 }
        XCTAssertEqual(value, 7)
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - probeUntilGranted

    /// The common case must stay free: access already granted, no waiting.
    func testProbeUntilGrantedReturnsImmediatelyWhenGranted() async {
        FileManager.default.createFile(atPath: dbPath, contents: Data())
        let slept = Mutex<[Duration]>([])
        let ok = await RecordingsAccessProbe.probeUntilGranted(
            recordingsDir: tempDir.path,
            retryDelays: [.seconds(1), .seconds(3)],
            sleep: { delay in slept.withLock { $0.append(delay) } }
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(slept.withLock { $0.isEmpty }, "a granted first probe must not wait")
    }

    /// The bug this exists for: at launch the container is cold, the first
    /// listing overruns the deadline and reads as denied. A later attempt sees
    /// the truth — and the loop must stop there rather than run the schedule out.
    func testProbeUntilGrantedRetriesUntilAccessAppears() async {
        let path = dbPath
        let attempts = Mutex(0)
        let ok = await RecordingsAccessProbe.probeUntilGranted(
            recordingsDir: tempDir.path,
            retryDelays: [.seconds(1), .seconds(3), .seconds(5)],
            sleep: { _ in
                let n = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if n == 2 { FileManager.default.createFile(atPath: path, contents: Data()) }
            }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(attempts.withLock { $0 }, 2, "must stop probing once access is confirmed")
    }

    /// A grant that never appears still has to produce a verdict — after the
    /// whole schedule has been waited out, not before.
    func testProbeUntilGrantedGivesUpAfterTheSchedule() async {
        let slept = Mutex<[Duration]>([])
        let delays: [Duration] = [.milliseconds(1), .milliseconds(2), .milliseconds(3)]
        let ok = await RecordingsAccessProbe.probeUntilGranted(
            recordingsDir: tempDir.path,
            retryDelays: delays,
            sleep: { delay in slept.withLock { $0.append(delay) } }
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(slept.withLock { $0 }, delays)
    }

    /// Cancellation surfaces as a throwing sleep: end the attempts, don't
    /// spin through what's left of the schedule without waiting.
    func testProbeUntilGrantedStopsWhenSleepIsCancelled() async {
        struct Cancelled: Error {}
        let attempts = Mutex(0)
        let ok = await RecordingsAccessProbe.probeUntilGranted(
            recordingsDir: tempDir.path,
            retryDelays: [.seconds(1), .seconds(3), .seconds(5)],
            sleep: { _ in
                attempts.withLock { $0 += 1 }
                throw Cancelled()
            }
        )
        XCTAssertFalse(ok)
        XCTAssertEqual(attempts.withLock { $0 }, 1, "a cancelled sleep ends the attempts")
    }

    /// The startup schedule has to outlast a cold login, which is the only
    /// reason it is longer than the routine one.
    func testStartupScheduleOutlastsAColdLogin() {
        let total = RecordingsAccessProbe.startupRetryDelays.reduce(Duration.zero, +)
        XCTAssertGreaterThanOrEqual(total, .seconds(30))
        XCTAssertLessThan(
            RecordingsAccessProbe.confirmRetryDelays.reduce(Duration.zero, +), total
        )
    }
}
