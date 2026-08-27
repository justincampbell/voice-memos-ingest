// TranscriptStore.swift — read-only query layer over the canonical JSONL.
//
// The append-only `transcripts.jsonl` is the source of truth; this gives the
// MCP server (and anything else) a small, dependency-free way to list, fetch,
// search, and tail it. The file is append-only, so a line index makes a stable
// cursor: "records after cursor N" == lines[N...]. Reads are fresh each call —
// the file is tiny (one short JSON object per memo), so there is no value in
// caching, and a fresh read can never serve stale data.

import Foundation

public struct TranscriptStore: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// All records in file order (oldest first). Malformed lines are skipped
    /// rather than failing the whole read — the canonical file should never
    /// contain them, but a partial final line during an in-flight append must
    /// not break a query.
    public func all() -> [TranscriptRecord] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var out: [TranscriptRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(TranscriptRecord.self, from: data)
            else { continue }
            out.append(record)
        }
        return out
    }

    /// Number of records currently in the file. Also the current tail cursor.
    public func count() -> Int {
        all().count
    }

    /// The most recent `limit` records, newest first.
    public func recent(limit: Int = 20) -> [TranscriptRecord] {
        Array(all().suffix(max(0, limit)).reversed())
    }

    /// One record by its stable id (ZUNIQUEID), or nil.
    public func get(id: String) -> TranscriptRecord? {
        all().first { $0.id == id }
    }

    /// Case-insensitive substring match over title and text, newest first.
    public func search(query: String, limit: Int = 20) -> [TranscriptRecord] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return recent(limit: limit) }
        let hits = all().filter {
            $0.text.lowercased().contains(needle) || $0.title.lowercased().contains(needle)
        }
        return Array(hits.suffix(max(0, limit)).reversed())
    }

    /// Records appended after the given line-index cursor, plus the new cursor.
    /// A `nil` or negative cursor means "from the beginning". Records are
    /// returned oldest-first so a consumer can process them in arrival order.
    public func since(cursor: Int?) -> (records: [TranscriptRecord], cursor: Int) {
        let everything = all()
        let start = max(0, cursor ?? 0)
        guard start < everything.count else { return ([], everything.count) }
        return (Array(everything[start...]), everything.count)
    }
}
