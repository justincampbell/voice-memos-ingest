// TranscriptEventHub.swift — in-process fan-out of newly emitted transcripts.
//
// The pipeline emits records; multiple consumers want to know the moment a new
// one lands: the `wait_for_next` MCP tool (one-shot) and the per-session
// resource-update notification pumps (long-lived). This is a tiny multicast: a
// listener gets an AsyncStream that yields every batch published after it
// started listening. It is deliberately "live only" — catch-up of older records
// is the TranscriptStore's job (read from a cursor); the hub only carries the
// edge so a waiter can wake without polling.

import Foundation

public actor TranscriptEventHub {
    private var continuations: [UUID: AsyncStream<[TranscriptRecord]>.Continuation] = [:]

    public init() {}

    /// Register a listener. The returned stream yields one element per
    /// `publish` call made while it is alive. Cancel/break to unregister.
    public func listen() -> AsyncStream<[TranscriptRecord]> {
        let id = UUID()
        return AsyncStream { continuation in
            self.add(id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id: id) }
            }
        }
    }

    /// Fan a batch of newly emitted records out to every live listener.
    public func publish(_ records: [TranscriptRecord]) {
        guard !records.isEmpty else { return }
        for continuation in continuations.values {
            continuation.yield(records)
        }
    }

    /// Live listener count. Internal rather than public: it exists so tests can
    /// assert that a dropped stream unregisters itself — a leak here would grow
    /// for the life of the process, one entry per MCP session.
    var listenerCount: Int { continuations.count }

    private func add(id: UUID, continuation: AsyncStream<[TranscriptRecord]>.Continuation) {
        continuations[id] = continuation
    }

    private func remove(id: UUID) {
        continuations[id] = nil
    }
}
