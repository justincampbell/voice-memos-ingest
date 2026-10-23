// ChannelServer.swift — wires ChannelProtocol to stdio and the memo source.
//
// Two pumps run concurrently:
//   • inbound  — read newline-delimited JSON-RPC from stdin, hand each message
//                to ChannelProtocol, write any reply to stdout;
//   • outbound — pull new memos from the MemoSource and write one
//                `notifications/claude/channel` per memo to stdout.
//
// stdout is the single shared resource both pumps write, so it goes through a
// serializing actor (`StdoutWriter`) — interleaved partial writes would corrupt
// the JSON-RPC framing. All the decision-making lives in ChannelProtocol; this
// file is deliberately just plumbing, and the parts that aren't raw FileHandle
// I/O (`handle`, `pumpSource`) take an injectable writer so they can be tested
// without a real stdin/stdout.
//
// Outbound is gated on the initialize handshake: the MCP lifecycle forbids the
// server from sending normal notifications before the client has initialized,
// so the memo pump holds until `initialize` (or `notifications/initialized`) is
// seen. Memos that arrive during the sub-second handshake buffer in the source
// stream and flush the moment the gate opens.

import Foundation
import MCP
import VMIngestCore

/// A sink for outbound JSON-RPC messages. Abstracted so tests can capture what
/// the server would have written instead of driving real file descriptors.
public protocol OutboundWriter: Sendable {
    func write(_ value: Value) async
}

/// Serializes writes to stdout and frames each message as one JSON line.
public actor StdoutWriter: OutboundWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder

    public init(handle: FileHandle = .standardOutput) {
        self.handle = handle
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func write(_ value: Value) async {
        guard let data = try? encoder.encode(value) else { return }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
    }
}

/// A one-shot latch: outbound notifications wait on it until the handshake
/// opens it. Opening is idempotent and releases every waiter.
actor InitGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

public struct ChannelServer: Sendable {
    let proto: ChannelProtocol
    let source: any MemoSource
    let writer: any OutboundWriter
    let log: @Sendable (String) -> Void
    let gate = InitGate()

    public init(
        proto: ChannelProtocol,
        source: any MemoSource,
        writer: any OutboundWriter,
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.proto = proto
        self.source = source
        self.writer = writer
        self.log = log
    }

    /// Run until stdin reaches EOF (the client disconnected). Cancels the memo
    /// pump on the way out.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pumpSource() }
            group.addTask { await pumpStdin() }
            // The first task to finish is stdin hitting EOF; tear the rest down.
            await group.next()
            group.cancelAll()
        }
    }

    /// Forward every new memo to the session as a channel notification — once
    /// the initialize handshake has opened the gate.
    func pumpSource() async {
        await gate.wait()
        for await record in source.records() {
            await writer.write(proto.channelNotification(for: record))
        }
    }

    private func pumpStdin() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                await handle(line: Data(line.utf8))
            }
        } catch {
            log("vmchannel: stdin read error (\(error))")
        }
    }

    /// Decode one JSON-RPC line, dispatch it, and write any response. Malformed
    /// lines are logged and skipped rather than killing the server.
    func handle(line: Data) async {
        guard !line.isEmpty else { return }
        guard let message = try? JSONDecoder().decode(Value.self, from: line) else {
            log("vmchannel: ignoring unparseable line (\(line.count) bytes)")
            return
        }
        let method = message.objectValue?["method"]?.stringValue
        logReplyAttempts(message)
        if let response = proto.response(to: message) {
            await writer.write(response)
        }
        // Open the outbound gate once the client has initialized. Either signal
        // suffices; opening is idempotent.
        if method == "initialize" || method == "notifications/initialized" {
            await markInitialized()
        }
    }

    /// Release the outbound gate. Called from the handshake path; exposed for
    /// tests that drive `pumpSource` directly.
    func markInitialized() async {
        await gate.open()
    }

    /// Surface `reply` calls on stderr — the feed is one-way, so this is the
    /// only place a reply goes.
    private func logReplyAttempts(_ message: Value) {
        guard message.objectValue?["method"]?.stringValue == "tools/call",
              let params = message.objectValue?["params"]?.objectValue,
              params["name"]?.stringValue == ChannelProtocol.replyToolName,
              let text = params["arguments"]?.objectValue?["text"]?.stringValue
        else { return }
        log("vmchannel: reply (not delivered): \(text)")
    }
}
