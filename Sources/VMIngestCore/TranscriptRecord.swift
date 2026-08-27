// TranscriptRecord.swift — one line of the canonical append-only JSONL output.
//
// Field contract (see CLAUDE.md): id, recorded_at (ISO 8601), duration, title,
// source (apple | speechtranscriber), text, and — when both transcripts are
// computed — apple_text / our_text, plus transcribed_at.

import Foundation

public enum TranscriptSource: String, Codable, Sendable {
    case apple
    case speechtranscriber
}

public struct TranscriptRecord: Codable, Sendable, Equatable {
    public let id: String
    public let recordedAt: String
    public let duration: Double
    public let title: String
    public let source: TranscriptSource
    public let text: String
    public let appleText: String?
    public let ourText: String?
    public let transcribedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAt = "recorded_at"
        case duration
        case title
        case source
        case text
        case appleText = "apple_text"
        case ourText = "our_text"
        case transcribedAt = "transcribed_at"
    }

    public init(
        id: String,
        recordedAt: String,
        duration: Double,
        title: String,
        source: TranscriptSource,
        text: String,
        appleText: String?,
        ourText: String?,
        transcribedAt: String
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.duration = duration
        self.title = title
        self.source = source
        self.text = text
        self.appleText = appleText
        self.ourText = ourText
        self.transcribedAt = transcribedAt
    }
}
