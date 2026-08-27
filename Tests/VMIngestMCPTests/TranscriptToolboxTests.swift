import XCTest
import MCP
@testable import VMIngestCore
@testable import VMIngestMCP

/// Covers the MCP tool/resource surface. This is why the MCP code lives in a
/// library target rather than the executable: an executable can't be imported,
/// so none of this was reachable before.
final class TranscriptToolboxTests: XCTestCase {

    // MARK: - Fixtures

    private func record(_ id: String, title: String = "t", text: String = "hello") -> TranscriptRecord {
        TranscriptRecord(
            id: id, recordedAt: "2026-06-08T01:04:15Z", duration: 7.0, title: title,
            source: .apple, text: text, appleText: nil, ourText: nil,
            transcribedAt: "2026-06-16T00:00:00Z"
        )
    }

    /// A toolbox over a fresh temp dir. Returns the transcripts path too so a
    /// test can append mid-flight (which is what a live pipeline run does).
    private func makeToolbox(
        _ records: [TranscriptRecord] = [],
        status: Status? = nil
    ) throws -> (toolbox: TranscriptToolbox, transcriptsPath: String, hub: TranscriptEventHub) {
        let dir = NSTemporaryDirectory() + "vmmcp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }

        let transcriptsPath = dir + "/transcripts.jsonl"
        for r in records { try JSONLWriter.append(r, to: transcriptsPath) }

        let statusPath = dir + "/status.json"
        if let status { try status.save(path: statusPath) }

        let hub = TranscriptEventHub()
        let toolbox = TranscriptToolbox(
            store: TranscriptStore(path: transcriptsPath),
            hub: hub,
            statusPath: statusPath
        )
        return (toolbox, transcriptsPath, hub)
    }

    /// The text payload of a tool result.
    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let t, _, _) = content { return t }
            return nil
        }.joined()
    }

    // MARK: - Numeric argument coercion
    //
    // The documented SDK gotcha: Value.intValue and .doubleValue do NOT
    // cross-coerce, so a JSON `25` read via .doubleValue alone comes back nil
    // and silently falls through to the default. These are the regression tests
    // for the intArg/doubleArg helpers that exist to paper over it.

    func testIntArgAcceptsIntAndDoubleEncodings() {
        XCTAssertEqual(TranscriptToolbox.intArg(["limit": .int(5)], "limit"), 5)
        XCTAssertEqual(TranscriptToolbox.intArg(["limit": .double(5.0)], "limit"), 5)
        XCTAssertNil(TranscriptToolbox.intArg(["limit": .int(5)], "other"))
        XCTAssertNil(TranscriptToolbox.intArg(nil, "limit"))
    }

    func testDoubleArgAcceptsIntAndDoubleEncodings() {
        XCTAssertEqual(TranscriptToolbox.doubleArg(["t": .double(2.5)], "t"), 2.5)
        // The bug this guards: a client sending `2` for a number-typed field.
        XCTAssertEqual(TranscriptToolbox.doubleArg(["t": .int(2)], "t"), 2.0)
        XCTAssertNil(TranscriptToolbox.doubleArg(nil, "t"))
    }

    func testRawSDKValueStillDoesNotCrossCoerce() {
        // If this ever starts passing, the SDK gained coercion and the helpers
        // above became redundant — worth knowing rather than carrying forever.
        XCTAssertNil(Value.int(2).doubleValue)
        XCTAssertNil(Value.double(2.0).intValue)
    }

    // MARK: - Tools

    func testListMemosIsNewestFirstAndRespectsLimit() async throws {
        let (toolbox, _, _) = try makeToolbox([record("a"), record("b"), record("c")])
        let result = await toolbox.call(name: "list_memos", arguments: ["limit": .int(2)])
        XCTAssertEqual(result.isError, false)
        let body = text(result)
        // Newest first: c before b, and a absent entirely.
        let posC = try XCTUnwrap(body.range(of: "\"c\""))
        let posB = try XCTUnwrap(body.range(of: "\"b\""))
        XCTAssertTrue(posC.lowerBound < posB.lowerBound)
        XCTAssertFalse(body.contains("\"id\":\"a\""))
    }

    func testSearchMemosMatchesAndRequiresQuery() async throws {
        let (toolbox, _, _) = try makeToolbox([
            record("a", title: "Groceries", text: "buy milk"),
            record("b", title: "Work", text: "email the team"),
        ])

        let hit = await toolbox.call(name: "search_memos", arguments: ["query": .string("MILK")])
        XCTAssertEqual(hit.isError, false)
        XCTAssertTrue(text(hit).contains("\"a\""))
        XCTAssertFalse(text(hit).contains("\"b\""))

        let missing = await toolbox.call(name: "search_memos", arguments: [:])
        XCTAssertEqual(missing.isError, true)
        XCTAssertTrue(text(missing).contains("requires a 'query'"))
    }

    func testGetMemoByIdAndItsFailureModes() async throws {
        let (toolbox, _, _) = try makeToolbox([record("a")])

        let found = await toolbox.call(name: "get_memo", arguments: ["id": .string("a")])
        XCTAssertEqual(found.isError, false)
        XCTAssertTrue(text(found).contains("\"a\""))

        let unknown = await toolbox.call(name: "get_memo", arguments: ["id": .string("nope")])
        XCTAssertEqual(unknown.isError, true)

        let noArg = await toolbox.call(name: "get_memo", arguments: [:])
        XCTAssertEqual(noArg.isError, true)
    }

    func testGetStatusReportsMissingStatusFileAsError() async throws {
        let (toolbox, _, _) = try makeToolbox([])
        let result = await toolbox.call(name: "get_status", arguments: nil)
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(text(result).contains("is the watcher running?"))
    }

    func testGetStatusReturnsStatusWhenPresent() async throws {
        var status = Status()
        status.running = true
        status.totalEmitted = 42
        let (toolbox, _, _) = try makeToolbox([], status: status)

        let result = await toolbox.call(name: "get_status", arguments: nil)
        XCTAssertEqual(result.isError, false)
        XCTAssertTrue(text(result).contains("42"))
    }

    func testUnknownToolIsAnErrorNotACrash() async throws {
        let (toolbox, _, _) = try makeToolbox([])
        let result = await toolbox.call(name: "definitely_not_a_tool", arguments: nil)
        XCTAssertEqual(result.isError, true)
    }

    /// Every advertised tool must actually dispatch. Catches a tool being added
    /// to the schema list but never wired into `call`, which would present as a
    /// working tool that always errors.
    func testEveryAdvertisedToolDispatches() async throws {
        let (toolbox, _, _) = try makeToolbox([record("a")])
        for tool in TranscriptToolbox.toolDefinitions {
            let result = await toolbox.call(name: tool.name, arguments: minimalArgs(for: tool.name))
            XCTAssertFalse(
                text(result).contains("unknown tool"),
                "advertised tool '\(tool.name)' is not handled in call()"
            )
        }
    }

    private func minimalArgs(for tool: String) -> [String: Value]? {
        switch tool {
        case "search_memos": return ["query": .string("hello")]
        case "get_memo": return ["id": .string("a")]
        // Keep the long-poll from actually blocking the suite.
        case "wait_for_next": return ["timeout_seconds": .double(0.05)]
        default: return nil
        }
    }

    // MARK: - wait_for_next

    func testWaitForNextReturnsImmediatelyWhenRecordsAlreadyExist() async throws {
        let (toolbox, _, _) = try makeToolbox([record("a"), record("b")])
        // A generous timeout: if the early-return path regresses, this blocks
        // and the test fails loudly on time rather than passing slowly.
        let (records, cursor) = await toolbox.waitForNext(after: 0, timeout: 30)
        XCTAssertEqual(records.map(\.id), ["a", "b"])
        XCTAssertEqual(cursor, 2)
    }

    func testWaitForNextTimesOutEmptyWhenNothingArrives() async throws {
        let (toolbox, _, _) = try makeToolbox([record("a")])
        let (records, cursor) = await toolbox.waitForNext(after: 1, timeout: 0.2)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(cursor, 1, "cursor should still report the real tail")
    }

    func testWaitForNextWakesOnPublishAndReadsFromTheStore() async throws {
        let (toolbox, path, hub) = try makeToolbox([record("a")])

        let waiter = Task { await toolbox.waitForNext(after: 1, timeout: 10) }

        // Simulate a pipeline run: append to the canonical file, then publish.
        try await Task.sleep(for: .milliseconds(50))
        let fresh = record("b")
        try JSONLWriter.append(fresh, to: path)
        await hub.publish([fresh])

        let (records, cursor) = await waiter.value
        XCTAssertEqual(records.map(\.id), ["b"])
        XCTAssertEqual(cursor, 2)
    }

    /// The store is authoritative, not the event payload: a publish that isn't
    /// backed by the file must not fabricate a record.
    func testWaitForNextTrustsTheStoreOverTheEvent() async throws {
        let (toolbox, _, hub) = try makeToolbox([record("a")])

        let waiter = Task { await toolbox.waitForNext(after: 1, timeout: 10) }
        try await Task.sleep(for: .milliseconds(50))
        await hub.publish([record("ghost")])   // never written to the file

        let (records, _) = await waiter.value
        XCTAssertTrue(records.isEmpty, "a record absent from the file must not be returned")
    }

    /// A nil cursor means "from now", so pre-existing memos must not replay.
    func testWaitForNextWithNilCursorDoesNotReplayHistory() async throws {
        let (toolbox, _, _) = try makeToolbox([record("a"), record("b")])
        let (records, cursor) = await toolbox.waitForNext(after: nil, timeout: 0.2)
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(cursor, 2)
    }

    // MARK: - Resources

    func testResourceListAdvertisesOnlyEnumerableURIs() throws {
        let (toolbox, _, _) = try makeToolbox([record("a")])
        let uris = toolbox.resources().map(\.uri)
        XCTAssertEqual(Set(uris), [MCPNames.transcriptsURI, MCPNames.statusURI])
        // memo/{id} is readable by direct URI but deliberately not listed —
        // there is no ListResourceTemplates handler, so advertising it would
        // promise discoverability that doesn't exist.
        XCTAssertFalse(uris.contains { $0.hasPrefix(MCPNames.memoURIPrefix) })
    }

    func testReadTranscriptsAndStatusResources() throws {
        var status = Status()
        status.totalEmitted = 7
        let (toolbox, _, _) = try makeToolbox([record("a")], status: status)

        let transcripts = try toolbox.read(uri: MCPNames.transcriptsURI)
        XCTAssertTrue(transcripts.contents.count == 1)

        let statusResult = try toolbox.read(uri: MCPNames.statusURI)
        XCTAssertTrue(statusResult.contents.count == 1)
    }

    func testReadMemoByDirectURI() throws {
        let (toolbox, _, _) = try makeToolbox([record("a")])
        let result = try toolbox.read(uri: MCPNames.memoURIPrefix + "a")
        XCTAssertEqual(result.contents.count, 1)
    }

    func testReadRejectsUnknownMemoAndUnknownURI() throws {
        let (toolbox, _, _) = try makeToolbox([record("a")])
        XCTAssertThrowsError(try toolbox.read(uri: MCPNames.memoURIPrefix + "nope"))
        XCTAssertThrowsError(try toolbox.read(uri: "voicememo://nonsense"))
        XCTAssertThrowsError(try toolbox.read(uri: "https://example.com"))
    }

    /// The transcripts resource is a bounded snapshot, and README/CLAUDE.md
    /// state the bound. Guards the docs against silent drift.
    func testTranscriptsResourceIsBounded() throws {
        let many = (0..<150).map { record("id-\($0)") }
        let (toolbox, _, _) = try makeToolbox(many)
        let result = try toolbox.read(uri: MCPNames.transcriptsURI)
        let body = try XCTUnwrap(result.contents.first?.text, "expected text content")
        let decoded = try JSONDecoder().decode([TranscriptRecord].self, from: Data(body.utf8))
        XCTAssertEqual(decoded.count, MCPNames.transcriptsResourceLimit)
        XCTAssertEqual(decoded.first?.id, "id-149", "newest first")
    }
}
