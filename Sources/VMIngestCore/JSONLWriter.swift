// JSONLWriter.swift — append-only writer for the canonical transcripts file.
//
// One self-contained JSON object per line. Strictly append: existing lines are
// never read or rewritten, so a downstream consumer can track progress with a
// byte offset.

import Foundation

public enum JSONLWriter {
    /// Encode `record` as a single JSON line and append it (with a trailing
    /// newline) to the file at `path`, creating the file and parent dirs as
    /// needed. Returns the encoded line (without newline).
    @discardableResult
    public static func append(_ record: TranscriptRecord, to path: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        var line = data
        line.append(0x0A) // newline

        let url = URL(fileURLWithPath: path)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
