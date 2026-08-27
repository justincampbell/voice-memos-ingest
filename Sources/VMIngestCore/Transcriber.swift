// Transcriber.swift — on-device transcription of an audio file using the
// macOS 26 SpeechAnalyzer / SpeechTranscriber API (same engine Voice Memos uses).
//
// This is the in-process port of the original `transcribe.swift` CLI. The
// `vmingest transcribe <file>` subcommand wraps `Transcriber.transcribe(url:)`
// to preserve the original behavior for debugging.

import Foundation
import Speech
import AVFoundation

public enum Transcriber {
    /// Transcribe an audio file on-device, returning the plain-text transcript
    /// (trimmed of leading/trailing whitespace).
    public static func transcribe(url: URL, localeIdentifier: String = "en-US") async throws -> String {
        let locale = Locale(identifier: localeIdentifier)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // Ensure the on-device model assets are present.
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        // Collect results concurrently while feeding the file.
        let collected = Task { () -> String in
            var text = AttributedString()
            for try await result in transcriber.results {
                text += result.text
            }
            return String(text.characters)
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        let out = try await collected.value
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
