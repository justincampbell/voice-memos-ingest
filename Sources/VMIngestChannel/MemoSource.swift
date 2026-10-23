// MemoSource.swift — where new memos come from, as an async stream.
//
// The channel needs a push edge: "wake me when a memo lands." Rather than
// re-implement watching/cursoring, the default source reuses the one the
// resident app already hosts for exactly this — the loopback MCP server's
// `wait_for_next` long-poll (see VMIngestMCP). The bridge is thus a thin
// adapter: MCP client on the data side, channel server on the Claude side.
//
// The protocol keeps the pump testable with a canned source.

import Foundation
import MCP
import VMIngestCore

public protocol MemoSource: Sendable {
    /// A live stream of newly emitted records in arrival order. "Live" means it
    /// starts from *now* — history is not replayed, so subscribing never floods
    /// the session with the back-catalogue.
    func records() -> AsyncStream<TranscriptRecord>
}

/// A `MemoSource` backed by the resident app's loopback MCP server. Loops
/// `wait_for_next`, which blocks until a memo arrives (or a timeout), so this is
/// genuine push, not a busy poll. Reconnects with backoff if the server is down
/// (e.g. the menu-bar app isn't running yet), logging each stumble to stderr.
public struct WaitForNextMemoSource: MemoSource {
    let endpoint: URL?
    let pollTimeout: Double
    let reconnectDelay: Duration
    let log: @Sendable (String) -> Void

    public init(
        host: String,
        port: Int,
        pollTimeout: Double = 300,
        reconnectDelay: Duration = .seconds(5),
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.endpoint = URL(string: "http://\(host):\(port)/mcp")
        self.pollTimeout = pollTimeout
        self.reconnectDelay = reconnectDelay
        self.log = log
    }

    struct WaitResult: Decodable {
        let cursor: Int
        let records: [TranscriptRecord]
    }

    public func records() -> AsyncStream<TranscriptRecord> {
        AsyncStream { continuation in
            let task = Task { await run(yielding: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(yielding continuation: AsyncStream<TranscriptRecord>.Continuation) async {
        guard let endpoint else {
            log("vmchannel: invalid MCP endpoint; check mcpHost/mcpPort")
            continuation.finish()
            return
        }

        // `cursor` lives across reconnects on purpose: if the connection drops
        // (e.g. the menu-bar app restarts) and memos are ingested in the gap,
        // the next poll must carry the last cursor so the server replays them.
        // Resetting it here would silently drop those memos — a regression
        // against the byte-offset consumer this channel replaces. It starts nil
        // so the very first poll skips the back-catalogue ("from now").
        var cursor: Int?

        while !Task.isCancelled {
            let client = Client(name: "vmchannel", version: "0.1.0")
            let transport = HTTPClientTransport(endpoint: endpoint)
            do {
                _ = try await client.connect(transport: transport)
                log("vmchannel: subscribed to \(endpoint.absoluteString)")
                while !Task.isCancelled {
                    var args: [String: Value] = ["timeout_seconds": .double(pollTimeout)]
                    if let cursor { args["after_cursor"] = .int(cursor) }

                    let (content, isError) = try await client.callTool(name: "wait_for_next", arguments: args)
                    if isError == true {
                        throw ChannelSourceError.toolError(Self.firstText(content) ?? "wait_for_next failed")
                    }
                    guard let text = Self.firstText(content), let data = text.data(using: .utf8) else {
                        throw ChannelSourceError.decode("wait_for_next returned no text content")
                    }
                    let result = try JSONDecoder().decode(WaitResult.self, from: data)
                    cursor = result.cursor
                    for record in result.records { continuation.yield(record) }
                }
                await client.disconnect()
            } catch {
                await client.disconnect()
                if Task.isCancelled { break }
                log("vmchannel: source error (\(error)); reconnecting in \(reconnectDelay)")
                try? await Task.sleep(for: reconnectDelay)
            }
        }
        continuation.finish()
    }

    private static func firstText(_ content: [Tool.Content]) -> String? {
        for item in content {
            if case let .text(text, _, _) = item { return text }
        }
        return nil
    }
}

public enum ChannelSourceError: Error, CustomStringConvertible {
    case toolError(String)
    case decode(String)

    public var description: String {
        switch self {
        case .toolError(let m): return "wait_for_next error: \(m)"
        case .decode(let m): return "decode error: \(m)"
        }
    }
}
