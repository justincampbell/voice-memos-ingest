// TranscriptPolicy.swift — decide which transcript to record for a memo.
//
// Strategy (from CLAUDE.md): prefer Apple's embedded `tsrp` when present, fall
// back to running our own SpeechTranscriber on the audio otherwise. When
// `alwaysDoubleTranscribe` is set, compute both and record them side by side
// for ongoing comparison.

import Foundation

public enum TranscriptPolicy {
    /// Build a TranscriptRecord for one recording, transcribing as needed.
    public static func makeRecord(
        for recording: Recording,
        config: Config,
        now: Date = Date()
    ) async throws -> TranscriptRecord {
        let appleText = TsrpExtractor.extract(fromFileAt: recording.m4aPath)

        // Run our own transcriber if Apple's is missing, or if we always double.
        var ourText: String? = nil
        if appleText == nil || config.alwaysDoubleTranscribe {
            ourText = try await Transcriber.transcribe(
                url: URL(fileURLWithPath: recording.m4aPath),
                localeIdentifier: config.localeIdentifier
            )
        }

        let source: TranscriptSource
        let text: String
        if let appleText {
            source = .apple
            text = appleText
        } else {
            source = .speechtranscriber
            text = ourText ?? ""
        }

        // Record both texts only when both were actually computed.
        let bothComputed = appleText != nil && ourText != nil

        let iso = ISO8601DateFormatter()
        return TranscriptRecord(
            id: recording.id,
            recordedAt: iso.string(from: recording.recordedAt),
            duration: recording.duration,
            title: recording.title,
            source: source,
            text: text,
            appleText: bothComputed ? appleText : nil,
            ourText: bothComputed ? ourText : nil,
            transcribedAt: iso.string(from: now)
        )
    }
}
