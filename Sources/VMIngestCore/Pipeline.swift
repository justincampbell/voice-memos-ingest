// Pipeline.swift — the full ingest run.
//
// runOnce() reads recordings, diffs against producer state, and (on a normal
// run) emits a JSONL record per new memo. The first run bootstraps: it records
// every existing memo as seen and emits nothing.

import Foundation

public struct RunResult: Sendable {
    public var bootstrapped: Int = 0
    public var emitted: Int = 0
    public var errors: [String] = []
    public var didBootstrap: Bool = false
    /// The records written this run, in emit order. Lets callers (the app) post
    /// a notification per memo and update status.
    public var emittedRecords: [TranscriptRecord] = []
}

public enum Pipeline {
    public static func runOnce(config: Config) async throws -> RunResult {
        let recordings = try RecordingsReader.readAll(recordingsDir: config.recordingsDir)
        var state = try ProducerState.load(path: config.seenPath)

        if state.isFirstRun {
            state.markSeen(recordings.map { $0.id })
            try state.save(path: config.seenPath)
            return RunResult(bootstrapped: recordings.count, emitted: 0, didBootstrap: true)
        }

        let pending = state.newRecordings(from: recordings)
        var result = RunResult()
        for recording in pending {
            do {
                let record = try await TranscriptPolicy.makeRecord(for: recording, config: config)
                try JSONLWriter.append(record, to: config.transcriptsPath)
                // Mark seen and persist immediately so a later failure never
                // re-emits an already-written memo.
                state.markSeen(recording.id)
                try state.save(path: config.seenPath)
                result.emitted += 1
                result.emittedRecords.append(record)

                // The Apple Note is a convenience mirror, not the source of
                // truth: a failure here must not block or re-emit the memo.
                do {
                    try AppleNoteMirror.append(record, config: config)
                } catch {
                    result.errors.append("note mirror \(recording.id): \(error)")
                }
            } catch {
                result.errors.append("\(recording.id): \(error)")
            }
        }
        return result
    }
}
