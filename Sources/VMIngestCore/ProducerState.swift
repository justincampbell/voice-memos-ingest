// ProducerState.swift — tracks which memos the producer has already emitted.
//
// State is a set of ZUNIQUEIDs persisted to seen.json. The very first run
// (no state file yet) BOOTSTRAP-SKIPS every existing memo: it records them all
// as seen and emits nothing, so installing the tool on a Mac with a back catalog
// of memos doesn't dump the whole history into the output. Subsequent runs emit
// only memos whose id is not yet in the set.
//
// This is kept separate from any downstream consumer cursor.

import Foundation

public struct ProducerState: Sendable {
    public private(set) var seen: Set<String>
    /// True when no state file existed at load time — i.e. this is a first run
    /// and the caller should bootstrap-skip rather than emit.
    public let isFirstRun: Bool

    public init(seen: Set<String>, isFirstRun: Bool) {
        self.seen = seen
        self.isFirstRun = isFirstRun
    }

    /// Recordings not yet emitted, in input order. Pure function for testing.
    public func newRecordings(from all: [Recording]) -> [Recording] {
        all.filter { !seen.contains($0.id) }
    }

    public mutating func markSeen(_ id: String) {
        seen.insert(id)
    }

    public mutating func markSeen(_ ids: [String]) {
        seen.formUnion(ids)
    }

    // MARK: - Persistence

    public static func load(path: String) throws -> ProducerState {
        guard let data = FileManager.default.contents(atPath: path) else {
            return ProducerState(seen: [], isFirstRun: true)
        }
        let ids = try JSONDecoder().decode([String].self, from: data)
        return ProducerState(seen: Set(ids), isFirstRun: false)
    }

    /// Persist the seen set (sorted for stable diffs) atomically.
    public func save(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(seen.sorted())
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
