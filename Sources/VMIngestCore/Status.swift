// Status.swift — the small status file the menu-bar app maintains and the CLI
// reads. Deliberately loose coupling: no IPC, just a JSON file.

import Foundation

public struct Status: Codable, Sendable {
    public var running: Bool
    public var watchingSince: String?
    public var lastRunAt: String?
    public var totalEmitted: Int
    public var lastMemoTitle: String?
    public var lastMemoAt: String?
    public var lastError: String?
    /// Open file descriptors at the last check — leak canary (see FDUsage).
    public var openFDs: Int?

    public init(
        running: Bool = false,
        watchingSince: String? = nil,
        lastRunAt: String? = nil,
        totalEmitted: Int = 0,
        lastMemoTitle: String? = nil,
        lastMemoAt: String? = nil,
        lastError: String? = nil,
        openFDs: Int? = nil
    ) {
        self.running = running
        self.watchingSince = watchingSince
        self.lastRunAt = lastRunAt
        self.totalEmitted = totalEmitted
        self.lastMemoTitle = lastMemoTitle
        self.lastMemoAt = lastMemoAt
        self.lastError = lastError
        self.openFDs = openFDs
    }

    public static func load(path: String) -> Status? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    public func save(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
