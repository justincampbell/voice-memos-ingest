import XCTest
@testable import VMIngestCore

final class TranscriptEventHubTests: XCTestCase {
    private func record(_ id: String) -> TranscriptRecord {
        TranscriptRecord(
            id: id, recordedAt: "2026-06-08T01:04:15Z", duration: 1, title: "t",
            source: .apple, text: "x", appleText: nil, ourText: nil,
            transcribedAt: "2026-06-16T00:00:00Z"
        )
    }

    func testListenerReceivesPublishedBatch() async throws {
        let hub = TranscriptEventHub()
        let stream = await hub.listen()

        let batchToSend = [record("a"), record("b")]
        Task { await hub.publish(batchToSend) }

        var iterator = stream.makeAsyncIterator()
        let batch = await iterator.next()
        XCTAssertEqual(batch?.map(\.id), ["a", "b"])
    }

    func testPublishFansOutToMultipleListeners() async throws {
        let hub = TranscriptEventHub()
        let s1 = await hub.listen()
        let s2 = await hub.listen()

        let batchToSend = [record("z")]
        Task { await hub.publish(batchToSend) }

        var i1 = s1.makeAsyncIterator()
        var i2 = s2.makeAsyncIterator()
        async let first = i1.next()
        async let second = i2.next()
        let (a, b) = await (first, second)
        XCTAssertEqual(a?.map(\.id), ["z"])
        XCTAssertEqual(b?.map(\.id), ["z"])
    }

    /// An empty publish must not wake listeners — otherwise every no-op pipeline
    /// run would spuriously fire `wait_for_next` and every SSE subscriber.
    func testEmptyPublishDoesNotWakeListeners() async throws {
        let hub = TranscriptEventHub()
        let stream = await hub.listen()

        await hub.publish([])

        // Race the stream against a short sleep: the sleep must win, proving
        // nothing was yielded. A real publish then proves the stream is live,
        // so a silently-broken stream can't make this pass vacuously.
        let woke = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                _ = await iterator.next()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertFalse(woke, "empty publish must not yield to listeners")
    }

    /// Ending iteration must unregister the continuation; without this the hub
    /// accumulates dead listeners for the life of the process.
    func testFinishedListenerIsUnregistered() async throws {
        let hub = TranscriptEventHub()
        do {
            let stream = await hub.listen()
            var iterator = stream.makeAsyncIterator()
            let batchToSend = [record("a")]
            Task { await hub.publish(batchToSend) }
            _ = await iterator.next()
            let count = await hub.listenerCount
            XCTAssertEqual(count, 1)
        }
        // The stream is out of scope; its onTermination should have fired.
        // Poll briefly — termination is delivered asynchronously.
        var remaining = await hub.listenerCount
        for _ in 0..<50 where remaining != 0 {
            try await Task.sleep(for: .milliseconds(10))
            remaining = await hub.listenerCount
        }
        XCTAssertEqual(remaining, 0, "dropped listener should unregister itself")
    }
}
