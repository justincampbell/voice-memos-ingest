import XCTest
@testable import VMIngestCore

/// The DB snapshot must be made with plain byte reads, never clonefile:
/// APFS clone fires an ItemCloned FSEvent on the *source*, which re-triggers
/// the app's own recordings watcher in a permanent loop. These tests cover the
/// copy helper that replaced FileManager.copyItem.
final class RecordingsReaderCopyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-copy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCopyBytesPreservesContent() throws {
        let src = tempDir.appendingPathComponent("src.db").path
        let dst = tempDir.appendingPathComponent("dst.db").path
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        try payload.write(to: URL(fileURLWithPath: src))

        try RecordingsReader.copyBytes(from: src, to: dst)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dst)), payload)
    }

    func testCopyBytesOverwritesExistingDestination() throws {
        let src = tempDir.appendingPathComponent("src.db").path
        let dst = tempDir.appendingPathComponent("dst.db").path
        try Data("new".utf8).write(to: URL(fileURLWithPath: src))
        try Data("old-longer-content".utf8).write(to: URL(fileURLWithPath: dst))

        try RecordingsReader.copyBytes(from: src, to: dst)

        XCTAssertEqual(try String(contentsOfFile: dst, encoding: .utf8), "new")
    }

    func testCopyBytesThrowsOnMissingSource() {
        let src = tempDir.appendingPathComponent("nope.db").path
        let dst = tempDir.appendingPathComponent("dst.db").path
        XCTAssertThrowsError(try RecordingsReader.copyBytes(from: src, to: dst))
    }
}
