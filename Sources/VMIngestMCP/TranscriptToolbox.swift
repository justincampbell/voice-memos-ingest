// TranscriptToolbox.swift — what the MCP surface actually *does*, minus the SDK.
//
// The tool/resource behaviour lives here rather than inside the method handlers
// registered on `Server`, because a closure handed to the SDK can only be
// exercised by driving a real transport. Kept as a plain value type, every tool
// call and resource read is directly callable — and therefore directly
// testable — while MCPServerProvider is reduced to wiring.
//
// Read-only by construction: it holds a TranscriptStore (queries the canonical
// JSONL) and a TranscriptEventHub (the live edge), and nothing that can write.

import Foundation
import MCP
import VMIngestCore

public enum MCPNames {
    public static let serverName = "voice-memos-ingest"
    public static let serverVersion = "0.1.0"
    public static let transcriptsURI = "voicememo://transcripts"
    public static let memoURIPrefix = "voicememo://memo/"
    public static let statusURI = "voicememo://status"

    /// How many records the transcripts resource returns. The resource is a
    /// bounded snapshot, not the whole file; `list_memos` is the paged view.
    /// Documented in README/CLAUDE.md — keep those in sync if this changes.
    public static let transcriptsResourceLimit = 100
}

public struct TranscriptToolbox: Sendable {
    let store: TranscriptStore
    let hub: TranscriptEventHub
    let statusPath: String

    public init(config: Config, hub: TranscriptEventHub) {
        self.init(
            store: TranscriptStore(path: config.transcriptsPath),
            hub: hub,
            statusPath: config.statusPath
        )
    }

    init(store: TranscriptStore, hub: TranscriptEventHub, statusPath: String) {
        self.store = store
        self.hub = hub
        self.statusPath = statusPath
    }

    // MARK: - Tools

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        switch name {
        case "list_memos":
            let limit = Self.intArg(arguments, "limit") ?? 20
            return Self.json(store.recent(limit: limit))

        case "search_memos":
            guard let query = arguments?["query"]?.stringValue else {
                return Self.error("search_memos requires a 'query' string")
            }
            let limit = Self.intArg(arguments, "limit") ?? 20
            return Self.json(store.search(query: query, limit: limit))

        case "get_memo":
            guard let id = arguments?["id"]?.stringValue else {
                return Self.error("get_memo requires an 'id' string")
            }
            guard let memo = store.get(id: id) else {
                return Self.error("no memo with id \(id)")
            }
            return Self.json(memo)

        case "wait_for_next":
            let after = Self.intArg(arguments, "after_cursor")
            let timeout = Self.doubleArg(arguments, "timeout_seconds") ?? 25
            let (records, cursor) = await waitForNext(after: after, timeout: timeout)
            return Self.json(Value.object([
                "cursor": .int(cursor),
                "records": Self.encodeValue(records),
            ]))

        case "get_status":
            guard let status = Status.load(path: statusPath) else {
                return Self.error("no status file — is the watcher running?")
            }
            return Self.json(status)

        default:
            return Self.error("unknown tool \(name)")
        }
    }

    /// Long-poll for the next memo after `after` (a line index). A nil cursor
    /// means "from now" — block for the genuinely next memo rather than
    /// replaying history. Returns any records at or after the start, plus the
    /// new tail cursor.
    ///
    /// Two ordering details matter, and both have bitten us:
    ///  • the hub listener is attached BEFORE the first store read, so a memo
    ///    landing in the read/listen gap still signals instead of blocking for
    ///    the full timeout despite already being on disk;
    ///  • the value returned always comes from a store read, never from the
    ///    event payload, so the file stays authoritative.
    func waitForNext(after: Int?, timeout: Double) async -> (records: [TranscriptRecord], cursor: Int) {
        let start = after ?? store.count()

        let stream = await hub.listen()

        let immediate = store.since(cursor: start)
        if !immediate.records.isEmpty { return immediate }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream { break } }
            group.addTask { try? await Task.sleep(for: .seconds(max(0, timeout))) }
            await group.next()
            group.cancelAll()
        }
        return store.since(cursor: start)
    }

    // MARK: - Resources

    func resources() -> [Resource] {
        [
            Resource(
                name: "Recent transcripts",
                uri: MCPNames.transcriptsURI,
                description: "The \(MCPNames.transcriptsResourceLimit) most recent voice-memo transcripts, newest first. Subscribe for push on new memos.",
                mimeType: "application/json"
            ),
            Resource(
                name: "Watcher status",
                uri: MCPNames.statusURI,
                description: "Current ingest watcher status (running, totals, last error).",
                mimeType: "application/json"
            ),
        ]
    }

    func read(uri: String) throws -> ReadResource.Result {
        if uri == MCPNames.transcriptsURI {
            let body = Self.encode(store.recent(limit: MCPNames.transcriptsResourceLimit))
            return ReadResource.Result(contents: [.text(body, uri: uri, mimeType: "application/json")])
        }
        if uri == MCPNames.statusURI {
            let body = Status.load(path: statusPath).map(Self.encode) ?? "null"
            return ReadResource.Result(contents: [.text(body, uri: uri, mimeType: "application/json")])
        }
        if uri.hasPrefix(MCPNames.memoURIPrefix) {
            let id = String(uri.dropFirst(MCPNames.memoURIPrefix.count))
            guard let memo = store.get(id: id) else {
                throw MCPError.invalidParams("no memo with id \(id)")
            }
            return ReadResource.Result(contents: [.text(Self.encode(memo), uri: uri, mimeType: "application/json")])
        }
        throw MCPError.invalidParams("unknown resource \(uri)")
    }

    // MARK: - Tool definitions

    static let toolDefinitions: [Tool] = [
        Tool(
            name: "list_memos",
            description: "List recent voice-memo transcripts, newest first.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "limit": .object(["type": "integer", "description": "Max records to return (default 20)."])
                ]),
            ])
        ),
        Tool(
            name: "search_memos",
            description: "Case-insensitive substring search over transcript text and title.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object(["type": "string", "description": "Substring to match."]),
                    "limit": .object(["type": "integer", "description": "Max records (default 20)."]),
                ]),
                "required": .array(["query"]),
            ])
        ),
        Tool(
            name: "get_memo",
            description: "Fetch one transcript by its stable id (ZUNIQUEID).",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["id": .object(["type": "string"])]),
                "required": .array(["id"]),
            ])
        ),
        Tool(
            name: "wait_for_next",
            description: "Block until the next memo arrives (or timeout). Pass the 'cursor' from a prior call to only get newer memos; omit it to wait for the genuinely next one. Returns {cursor, records}; loop on the returned cursor to subscribe.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "after_cursor": .object(["type": "integer", "description": "Line cursor last seen; omit to start from now."]),
                    "timeout_seconds": .object(["type": "number", "description": "Max seconds to block (default 25)."]),
                ]),
            ])
        ),
        Tool(
            name: "get_status",
            description: "Current ingest watcher status: running, total emitted, last memo, last error.",
            inputSchema: .object(["type": "object", "properties": .object([:])])
        ),
    ]

    // MARK: - Encoding helpers

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// A successful tool result carrying a JSON-encoded Encodable as text.
    static func json<T: Encodable>(_ value: T) -> CallTool.Result {
        CallTool.Result(content: [.text(text: encode(value), annotations: nil, _meta: nil)], isError: false)
    }

    /// A successful tool result carrying a pre-built Value object.
    static func json(_ value: Value) -> CallTool.Result {
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        let text = String(data: data, encoding: .utf8) ?? "null"
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    /// Read a numeric argument regardless of whether the client sent it as a
    /// JSON integer or float — `Value.intValue`/`doubleValue` do **not**
    /// cross-coerce, so reading `timeout_seconds` (declared as a number, so a
    /// client may send `25` or `25.0`) via `doubleValue` alone silently drops an
    /// integer-encoded value and falls back to the default.
    static func intArg(_ args: [String: Value]?, _ key: String) -> Int? {
        guard let v = args?[key] else { return nil }
        return v.intValue ?? v.doubleValue.map(Int.init)
    }

    static func doubleArg(_ args: [String: Value]?, _ key: String) -> Double? {
        guard let v = args?[key] else { return nil }
        return v.doubleValue ?? v.intValue.map(Double.init)
    }

    /// Encode an Encodable into a `Value` so it can be embedded in a larger Value.
    static func encodeValue<T: Encodable>(_ value: T) -> Value {
        guard let data = try? encoder.encode(value),
              let v = try? JSONDecoder().decode(Value.self, from: data)
        else { return .null }
        return v
    }
}
