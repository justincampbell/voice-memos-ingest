import XCTest
import MCP
@testable import VMIngestChannel
@testable import VMIngestCore

/// The channel contract is hand-rolled (the swift-sdk Server can't advertise the
/// experimental `claude/channel` capability), so these tests pin the exact wire
/// shapes Claude Code expects — the same ones the reference `fakechat` plugin
/// emits.
final class ChannelProtocolTests: XCTestCase {
    private let proto = ChannelProtocol()

    private func record(_ id: String = "A1", title: String = "Idea", text: String = "buy milk") -> TranscriptRecord {
        TranscriptRecord(
            id: id, recordedAt: "2026-10-23T17:36:00Z", duration: 12.5, title: title,
            source: .apple, text: text, appleText: nil, ourText: nil,
            transcribedAt: "2026-10-23T17:36:04Z"
        )
    }

    // MARK: - initialize

    func testInitializeAdvertisesChannelCapabilityAndEchoesVersion() throws {
        let request: Value = .object([
            "jsonrpc": "2.0", "id": .int(1), "method": "initialize",
            "params": .object(["protocolVersion": "2025-11-25"]),
        ])
        let response = try XCTUnwrap(proto.response(to: request)?.objectValue)
        XCTAssertEqual(response["id"]?.intValue, 1)
        let result = try XCTUnwrap(response["result"]?.objectValue)
        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2025-11-25")
        let caps = try XCTUnwrap(result["capabilities"]?.objectValue)
        // The load-bearing bit: experimental.claude/channel must be present, or
        // Claude Code won't treat this as a channel.
        let experimental = try XCTUnwrap(caps["experimental"]?.objectValue)
        XCTAssertNotNil(experimental["claude/channel"]?.objectValue)
        XCTAssertNotNil(caps["tools"]?.objectValue)
        XCTAssertEqual(result["serverInfo"]?.objectValue?["name"]?.stringValue, "voice-memos")
        XCTAssertFalse((result["instructions"]?.stringValue ?? "").isEmpty)
    }

    func testInitializeFallsBackWhenNoVersionRequested() throws {
        let request: Value = .object(["jsonrpc": "2.0", "id": .int(2), "method": "initialize"])
        let result = try XCTUnwrap(proto.response(to: request)?.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["protocolVersion"]?.stringValue, Version.latest)
    }

    /// Claude Code drops a channel that negotiates a revision it can't use as a
    /// channel (`2026-07-28`), so an unknown request must not be echoed back.
    func testInitializeDoesNotEchoUnsupportedVersion() throws {
        let request: Value = .object([
            "jsonrpc": "2.0", "id": .int(3), "method": "initialize",
            "params": .object(["protocolVersion": "2026-07-28"]),
        ])
        let result = try XCTUnwrap(proto.response(to: request)?.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["protocolVersion"]?.stringValue, Version.latest)
        XCTAssertNotEqual(result["protocolVersion"]?.stringValue, "2026-07-28")
    }

    // MARK: - lifecycle / lists

    func testInitializedNotificationHasNoResponse() {
        let note: Value = .object(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(proto.response(to: note))
    }

    func testPingReturnsEmptyResult() throws {
        let request: Value = .object(["jsonrpc": "2.0", "id": .int(3), "method": "ping"])
        let response = try XCTUnwrap(proto.response(to: request)?.objectValue)
        XCTAssertEqual(response["result"]?.objectValue, [:])
    }

    func testToolsListAdvertisesReply() throws {
        let request: Value = .object(["jsonrpc": "2.0", "id": .int(4), "method": "tools/list"])
        let tools = try XCTUnwrap(proto.response(to: request)?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.objectValue?["name"]?.stringValue, "reply")
    }

    // MARK: - tools/call

    func testReplyCallSucceedsButIsNotAnError() throws {
        let request: Value = .object([
            "jsonrpc": "2.0", "id": .int(5), "method": "tools/call",
            "params": .object(["name": "reply", "arguments": .object(["text": "noted"])]),
        ])
        let result = try XCTUnwrap(proto.response(to: request)?.objectValue?["result"]?.objectValue)
        XCTAssertNil(result["isError"]?.boolValue)  // success, not an error
        XCTAssertFalse(result["content"]?.arrayValue?.isEmpty ?? true)
    }

    func testUnknownToolCallIsAnError() throws {
        let request: Value = .object([
            "jsonrpc": "2.0", "id": .int(6), "method": "tools/call",
            "params": .object(["name": "delete_everything"]),
        ])
        let result = try XCTUnwrap(proto.response(to: request)?.objectValue?["result"]?.objectValue)
        XCTAssertEqual(result["isError"]?.boolValue, true)
    }

    // MARK: - unknown methods

    func testUnknownRequestGetsMethodNotFound() throws {
        let request: Value = .object(["jsonrpc": "2.0", "id": "x", "method": "resources/subscribe"])
        let error = try XCTUnwrap(proto.response(to: request)?.objectValue?["error"]?.objectValue)
        XCTAssertEqual(error["code"]?.intValue, -32601)
    }

    func testUnknownNotificationIsSilent() {
        let note: Value = .object(["jsonrpc": "2.0", "method": "notifications/cancelled"])
        XCTAssertNil(proto.response(to: note))
    }

    func testMessageWithoutMethodIsIgnored() {
        let reply: Value = .object(["jsonrpc": "2.0", "id": .int(9), "result": .object([:])])
        XCTAssertNil(proto.response(to: reply))
    }

    // MARK: - outbound notification

    func testChannelNotificationShape() throws {
        let note = try XCTUnwrap(proto.channelNotification(for: record("Z9", text: "hello world")).objectValue)
        XCTAssertEqual(note["method"]?.stringValue, "notifications/claude/channel")
        XCTAssertNil(note["id"])  // a notification carries no id
        let params = try XCTUnwrap(note["params"]?.objectValue)
        XCTAssertEqual(params["content"]?.stringValue, "hello world")
        let meta = try XCTUnwrap(params["meta"]?.objectValue)
        XCTAssertEqual(meta["message_id"]?.stringValue, "Z9")
        XCTAssertEqual(meta["chat_id"]?.stringValue, "voice-memos")
        XCTAssertEqual(meta["ts"]?.stringValue, "2026-10-23T17:36:00Z")
        XCTAssertEqual(meta["title"]?.stringValue, "Idea")
        XCTAssertEqual(meta["transcript_source"]?.stringValue, "apple")
        XCTAssertNil(meta["source"])  // reserved for the channel envelope
        XCTAssertEqual(meta["duration"]?.stringValue, "12.5")
        // meta is Record<string, string> in the contract: every value a string.
        for (key, value) in meta {
            XCTAssertNotNil(value.stringValue, "meta.\(key) must be a string")
        }
    }
}
