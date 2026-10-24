import XCTest
import MCP
@testable import VMIngestChannel
@testable import VMIngestCore

/// Exercises the stdio plumbing without real file descriptors: a canned
/// MemoSource on one side and a capturing writer on the other.
final class ChannelServerTests: XCTestCase {
    // MARK: - Test doubles

    private struct CannedSource: MemoSource {
        let items: [TranscriptRecord]
        func records() -> AsyncStream<TranscriptRecord> {
            AsyncStream { continuation in
                for record in items { continuation.yield(record) }
                continuation.finish()
            }
        }
    }

    private actor CapturingWriter: OutboundWriter {
        private(set) var written: [Value] = []
        func write(_ value: Value) async { written.append(value) }
        func all() -> [Value] { written }
    }

    /// Thread-safe collector for the server's synchronous log closure.
    private final class LogCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private func record(_ id: String, text: String = "x") -> TranscriptRecord {
        TranscriptRecord(
            id: id, recordedAt: "2026-10-23T17:36:00Z", duration: 1, title: "t",
            source: .apple, text: text, appleText: nil, ourText: nil,
            transcribedAt: "2026-10-23T17:36:01Z"
        )
    }

    private func server(source: any MemoSource, writer: CapturingWriter) -> ChannelServer {
        ChannelServer(proto: ChannelProtocol(), source: source, writer: writer, log: { _ in })
    }

    private func line(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: - outbound pump

    func testEveryMemoBecomesAChannelNotification() async {
        let writer = CapturingWriter()
        let source = CannedSource(items: [record("A", text: "one"), record("B", text: "two")])
        let s = server(source: source, writer: writer)
        await s.markInitialized()  // open the handshake gate
        await s.pumpSource()

        let written = await writer.all()
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written.map { $0.objectValue?["method"]?.stringValue },
                       ["notifications/claude/channel", "notifications/claude/channel"])
        let ids = written.map { $0.objectValue?["params"]?.objectValue?["meta"]?.objectValue?["message_id"]?.stringValue }
        XCTAssertEqual(ids, ["A", "B"])
        let contents = written.map { $0.objectValue?["params"]?.objectValue?["content"]?.stringValue }
        XCTAssertEqual(contents, ["one", "two"])
    }

    func testOutboundIsHeldUntilInitialized() async throws {
        let writer = CapturingWriter()
        let s = server(source: CannedSource(items: [record("A")]), writer: writer)

        let pump = Task { await s.pumpSource() }
        // Before the gate opens, nothing is written even though a memo is ready.
        try await Task.sleep(for: .milliseconds(50))
        let before = await writer.all()
        XCTAssertTrue(before.isEmpty)

        await s.markInitialized()
        await pump.value
        let after = await writer.all()
        XCTAssertEqual(after.count, 1)
    }

    /// The `initialize` *request* is not readiness: the client may not be
    /// listening until it sends `notifications/initialized`, so a memo landing
    /// between the two must still be held.
    func testGateOpensOnInitializedNotificationNotInitializeRequest() async throws {
        let writer = CapturingWriter()
        let s = server(source: CannedSource(items: [record("A")]), writer: writer)
        let pump = Task { await s.pumpSource() }

        try await s.handle(line: line(.object(["jsonrpc": "2.0", "id": .int(1), "method": "initialize"])))
        try await Task.sleep(for: .milliseconds(50))
        let afterInitialize = await writer.all()
        // Only the initialize response — no channel notification yet.
        XCTAssertEqual(afterInitialize.count, 1)
        XCTAssertNil(afterInitialize.first?.objectValue?["method"])

        try await s.handle(line: line(.object(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        await pump.value
        let afterInitialized = await writer.all()
        XCTAssertEqual(afterInitialized.count, 2)
        XCTAssertEqual(afterInitialized.last?.objectValue?["method"]?.stringValue, ChannelProtocol.notificationMethod)
    }

    /// A client that disconnects before initializing cancels the pump while it
    /// is still parked on the gate. The pump must return — otherwise `run()`'s
    /// task group never drains and the process outlives its client.
    func testCancellingPumpBeforeInitializeReleasesIt() async {
        let writer = CapturingWriter()
        let s = server(source: CannedSource(items: [record("A")]), writer: writer)
        let pump = Task { await s.pumpSource() }
        try? await Task.sleep(for: .milliseconds(20))  // let it park on the gate

        pump.cancel()
        let returned = expectation(description: "pump returns after cancel")
        Task { await pump.value; returned.fulfill() }
        await fulfillment(of: [returned], timeout: 2)

        let written = await writer.all()
        XCTAssertTrue(written.isEmpty)  // cancelled, so nothing was sent
    }

    // MARK: - inbound handling

    func testHandleInitializeWritesResponse() async throws {
        let writer = CapturingWriter()
        let s = server(source: CannedSource(items: []), writer: writer)
        try await s.handle(line: line(.object(["jsonrpc": "2.0", "id": .int(1), "method": "initialize"])))

        let written = await writer.all()
        XCTAssertEqual(written.count, 1)
        XCTAssertNotNil(written.first?.objectValue?["result"]?.objectValue?["capabilities"])
    }

    func testHandleNotificationWritesNothing() async throws {
        let writer = CapturingWriter()
        let s = server(source: CannedSource(items: []), writer: writer)
        try await s.handle(line: line(.object(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        let written = await writer.all()
        XCTAssertTrue(written.isEmpty)
    }

    func testHandleMalformedLineIsIgnored() async {
        let writer = CapturingWriter()
        let s = server(source: CannedSource(items: []), writer: writer)
        await s.handle(line: Data("{not json".utf8))
        await s.handle(line: Data())  // empty line, e.g. a keepalive blank
        let written = await writer.all()
        XCTAssertTrue(written.isEmpty)
    }

    func testReplyIsLoggedNotDelivered() async throws {
        let writer = CapturingWriter()
        let logs = LogCollector()
        let s = ChannelServer(
            proto: ChannelProtocol(), source: CannedSource(items: []), writer: writer,
            log: { logs.append($0) }
        )
        try await s.handle(line: line(.object([
            "jsonrpc": "2.0", "id": .int(7), "method": "tools/call",
            "params": .object(["name": "reply", "arguments": .object(["text": "noted"])]),
        ])))

        XCTAssertTrue(logs.all().contains { $0.contains("noted") })
        // The caller still gets a (successful) ack.
        let written = await writer.all()
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.objectValue?["result"]?.objectValue?["isError"])
    }

    // MARK: - cross-process contract

    /// The client-side decoder must track exactly what the server's
    /// `wait_for_next` emits: `{cursor, records}` with snake_case record fields.
    /// A literal fixture guards against the two sides drifting.
    func testWaitResultDecodesServerShape() throws {
        let json = """
        {"cursor":3,"records":[{"id":"A1","recorded_at":"2026-10-23T17:36:00Z",\
        "duration":12.5,"title":"Idea","source":"apple","text":"buy milk",\
        "apple_text":null,"our_text":null,"transcribed_at":"2026-10-23T17:36:04Z"}]}
        """
        let result = try JSONDecoder().decode(
            WaitForNextMemoSource.WaitResult.self, from: Data(json.utf8)
        )
        XCTAssertEqual(result.cursor, 3)
        XCTAssertEqual(result.records.count, 1)
        let r = try XCTUnwrap(result.records.first)
        XCTAssertEqual(r.id, "A1")
        XCTAssertEqual(r.text, "buy milk")
        XCTAssertEqual(r.source, .apple)
        XCTAssertEqual(r.duration, 12.5)
    }
}
