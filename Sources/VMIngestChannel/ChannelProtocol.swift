// ChannelProtocol.swift — the Claude Code "channel" contract, as pure logic.
//
// A Claude Code *channel* is a stdio MCP server that (a) advertises the
// experimental `claude/channel` capability in its initialize result, (b) pushes
// inbound messages to the session as `notifications/claude/channel`, and (c)
// exposes a `reply` tool for the session to talk back. A session subscribes by
// launching with `claude --dangerously-load-development-channels
// plugin:<name>@<marketplace>` (plain `--channels` only accepts Anthropic's
// allowlist during the research preview).
//
// We hand-roll the JSON-RPC rather than use the swift-sdk `Server`: the SDK's
// `Server.Capabilities` is a fixed Codable with no `experimental` field, so it
// cannot advertise `claude/channel` at all. The contract is small, so a pure
// request→response function (plus a notification builder) is both simpler and —
// unlike anything buried in a transport — directly testable. All I/O lives in
// ChannelServer; this type never touches stdin/stdout.
//
// Shapes mirror the official reference channel (`fakechat`): capabilities
// `{tools:{}, experimental:{"claude/channel":{}}}`, and a notification whose
// params are `{content, meta:{chat_id, message_id, user, ts, …}}`.

import Foundation
import MCP
import VMIngestCore

public struct ChannelProtocol: Sendable {
    public let serverName: String
    public let serverVersion: String
    public let instructions: String
    /// The channel's single conversation id. Voice memos are one linear feed.
    public let chatID: String

    /// Standard MCP version negotiation: answer with the client's requested
    /// version if we speak it, otherwise with our latest. Bounded to the
    /// swift-sdk's `Version.supported` on purpose — blindly echoing whatever the
    /// client asks for would claim revisions we don't implement, and Claude Code
    /// refuses to register a channel that negotiates `2026-07-28`.
    static func negotiatedVersion(requested: String?) -> String {
        if let requested, Version.supported.contains(requested) { return requested }
        return Version.latest
    }

    public static let channelCapabilityKey = "claude/channel"
    public static let notificationMethod = "notifications/claude/channel"
    public static let replyToolName = "reply"

    public init(
        serverName: String = "voice-memos",
        serverVersion: String = "0.1.0",
        chatID: String = "voice-memos",
        instructions: String = ChannelProtocol.defaultInstructions
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.chatID = chatID
        self.instructions = instructions
    }

    public static let defaultInstructions = """
    Each message is a newly recorded Apple Voice Memo transcript, delivered the \
    moment it is ingested. Treat the message content as the transcript text; the \
    memo's title, recorded time, and duration are in the notification meta. This \
    is a one-way feed — there is no person on the other end — so the `reply` tool \
    only logs and discards. Act on each memo according to your own instructions \
    (route it, capture reminders, etc.); do not reply expecting a human to read it.
    """

    // MARK: - Request handling

    /// Handle one decoded JSON-RPC message from the client and return the reply
    /// to send, or nil when none is warranted (a notification, or a response to
    /// one of our own messages — we issue only notifications, so those are just
    /// dropped).
    public func response(to message: Value) -> Value? {
        guard let object = message.objectValue else { return nil }
        guard let method = object["method"]?.stringValue else { return nil }
        let id = object["id"]  // absent ⇒ notification; present ⇒ request

        switch method {
        case "initialize":
            let requested = object["params"]?.objectValue?["protocolVersion"]?.stringValue
            return id.map { success(id: $0, result: initializeResult(protocolVersion: requested)) }

        case "ping":
            return id.map { success(id: $0, result: .object([:])) }

        case "tools/list":
            return id.map { success(id: $0, result: .object(["tools": .array([Self.replyToolDefinition])])) }

        case "tools/call":
            guard let id else { return nil }
            return success(id: id, result: toolCallResult(params: object["params"]))

        case "resources/list":
            return id.map { success(id: $0, result: .object(["resources": .array([])])) }

        case "prompts/list":
            return id.map { success(id: $0, result: .object(["prompts": .array([])])) }

        default:
            // Notifications (no id) are silently accepted; unknown *requests*
            // get a well-formed method-not-found error so the client isn't left
            // waiting on a reply it will never receive.
            guard let id else { return nil }
            return error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    /// The `tools/call` result. The only tool is `reply`; because this is a
    /// one-way feed the call is acknowledged but nothing is delivered anywhere.
    /// `ChannelServer` logs the attempt to stderr for debugging.
    private func toolCallResult(params: Value?) -> Value {
        let name = params?.objectValue?["name"]?.stringValue
        guard name == Self.replyToolName else {
            return .object([
                "content": .array([text("unknown tool: \(name ?? "nil")")]),
                "isError": .bool(true),
            ])
        }
        return .object([
            "content": .array([text(
                "voice-memos is a one-way feed (new memos only); the reply was logged but not delivered to anyone."
            )]),
        ])
    }

    private func initializeResult(protocolVersion: String?) -> Value {
        .object([
            "protocolVersion": .string(Self.negotiatedVersion(requested: protocolVersion)),
            "capabilities": .object([
                "tools": .object([:]),
                "experimental": .object([Self.channelCapabilityKey: .object([:])]),
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(serverVersion),
            ]),
            "instructions": .string(instructions),
        ])
    }

    static let replyToolDefinition: Value = .object([
        "name": .string(replyToolName),
        "description": .string(
            "Acknowledge a voice memo. voice-memos is a one-way feed, so the text is logged but not delivered to any person."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object(["type": .string("string")]),
                "reply_to": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("text")]),
        ]),
    ])

    // MARK: - Outbound notification

    /// The `notifications/claude/channel` message carrying one new memo. The
    /// transcript is the message `content`; descriptive fields ride in `meta`.
    public func channelNotification(for record: TranscriptRecord) -> Value {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string(Self.notificationMethod),
            "params": .object([
                "content": .string(record.text),
                "meta": .object([
                    "chat_id": .string(chatID),
                    "message_id": .string(record.id),
                    "user": .string(chatID),
                    "ts": .string(record.recordedAt),
                    "title": .string(record.title),
                    // Strings only: the contract types meta as
                    // Record<string, string>, so a number here risks the
                    // attribute (or the whole event) being dropped.
                    "duration": .string(String(record.duration)),
                    // `transcript_source`, not `source`: the channel envelope
                    // already carries a `source=` attribute (the plugin id), so
                    // a `source` meta key risks colliding with / mislabelling it.
                    "transcript_source": .string(record.source.rawValue),
                ]),
            ]),
        ])
    }

    // MARK: - JSON-RPC envelope helpers

    private func success(id: Value, result: Value) -> Value {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func error(id: Value, code: Int, message: String) -> Value {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ])
    }

    private func text(_ s: String) -> Value {
        .object(["type": .string("text"), "text": .string(s)])
    }
}
