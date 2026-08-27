import XCTest
@testable import VMIngestCore

final class FDUsageTests: XCTestCase {
    func testCountReflectsOpenDescriptors() throws {
        let before = try XCTUnwrap(FDUsage.count())
        XCTAssertGreaterThan(before, 0)

        var handles: [FileHandle] = []
        for _ in 0..<5 {
            handles.append(try XCTUnwrap(FileHandle(forReadingAtPath: "/dev/null")))
        }
        let during = try XCTUnwrap(FDUsage.count())
        XCTAssertGreaterThanOrEqual(during, before + 5)

        for h in handles { try h.close() }
        let after = try XCTUnwrap(FDUsage.count())
        XCTAssertLessThan(after, during)
    }

    func testRaiseLimitLiftsSoftLimit() {
        let result = FDUsage.raiseLimit()
        var lim = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &lim), 0)
        XCTAssertEqual(result, Int(lim.rlim_cur))
        // The launchd default is 256; after raising, the soft limit must be
        // meaningfully above it (OPEN_MAX unless the hard limit is lower).
        XCTAssertGreaterThanOrEqual(result, 4096)
    }

    func testVerdictThresholds() {
        XCTAssertEqual(FDUsage.verdict(count: 6), .ok)
        XCTAssertEqual(FDUsage.verdict(count: 511), .ok)
        XCTAssertEqual(FDUsage.verdict(count: 512), .warn)
        XCTAssertEqual(FDUsage.verdict(count: 4095), .warn)
        XCTAssertEqual(FDUsage.verdict(count: 4096), .restart)
        XCTAssertEqual(FDUsage.verdict(count: 10_000), .restart)
    }
}
