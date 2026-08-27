// Config.swift — resolved configuration for the pipeline.
//
// Loaded from ~/.config/voice-memos-ingest/config.json when present; otherwise
// sensible defaults are used. Every path lives under $HOME so the repo can be
// open-sourced without leaking personal paths.

import Foundation

public struct Config: Codable, Sendable {
    /// Apple Voice Memos Recordings directory (audio + CloudRecordings.db).
    public var recordingsDir: String
    /// Canonical append-only JSONL output — the machine source of truth.
    public var transcriptsPath: String
    /// Producer state: the set of ZUNIQUEIDs already emitted.
    public var seenPath: String
    /// Status file the menu-bar app keeps current for the CLI to read.
    public var statusPath: String
    /// Name of the Apple Note used as the human-facing mirror.
    public var appleNoteName: String
    /// Whether to mirror transcripts into Apple Notes at all.
    public var appleNoteEnabled: Bool
    /// When true, always also run our own transcriber even if Apple's `tsrp`
    /// is present, recording both texts for comparison.
    public var alwaysDoubleTranscribe: Bool
    /// Locale used by the on-device transcriber.
    public var localeIdentifier: String
    /// Whether the menu-bar app hosts the in-process MCP server.
    public var mcpEnabled: Bool
    /// Loopback host the MCP HTTP server binds to. Keep this on 127.0.0.1 —
    /// the server is unauthenticated and meant only for local agents.
    public var mcpHost: String
    /// TCP port the MCP HTTP server listens on.
    public var mcpPort: Int

    public init(
        recordingsDir: String,
        transcriptsPath: String,
        seenPath: String,
        statusPath: String,
        appleNoteName: String,
        appleNoteEnabled: Bool,
        alwaysDoubleTranscribe: Bool,
        localeIdentifier: String,
        mcpEnabled: Bool,
        mcpHost: String,
        mcpPort: Int
    ) {
        self.recordingsDir = recordingsDir
        self.transcriptsPath = transcriptsPath
        self.seenPath = seenPath
        self.statusPath = statusPath
        self.appleNoteName = appleNoteName
        self.appleNoteEnabled = appleNoteEnabled
        self.alwaysDoubleTranscribe = alwaysDoubleTranscribe
        self.localeIdentifier = localeIdentifier
        self.mcpEnabled = mcpEnabled
        self.mcpHost = mcpHost
        self.mcpPort = mcpPort
    }

    /// Decoded from JSON where every field is optional, falling back to the
    /// computed defaults for whatever the file omits.
    private struct Partial: Decodable {
        var recordingsDir: String?
        var transcriptsPath: String?
        var seenPath: String?
        var statusPath: String?
        var appleNoteName: String?
        var appleNoteEnabled: Bool?
        var alwaysDoubleTranscribe: Bool?
        var localeIdentifier: String?
        var mcpEnabled: Bool?
        var mcpHost: String?
        var mcpPort: Int?
    }

    public static func defaults(home: String = NSHomeDirectory()) -> Config {
        let recordings = "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
        let dataDir = "\(home)/.local/share/voice-memos-ingest"
        return Config(
            recordingsDir: recordings,
            transcriptsPath: "\(dataDir)/transcripts.jsonl",
            seenPath: "\(dataDir)/seen.json",
            statusPath: "\(dataDir)/status.json",
            appleNoteName: "Voice Memo Transcripts",
            appleNoteEnabled: false,
            alwaysDoubleTranscribe: false,
            localeIdentifier: "en-US",
            mcpEnabled: true,
            mcpHost: "127.0.0.1",
            mcpPort: 7777
        )
    }

    /// Path to the config file (independent of whether it exists).
    public static func configPath(home: String = NSHomeDirectory()) -> String {
        "\(home)/.config/voice-memos-ingest/config.json"
    }

    /// Load config, overlaying any values from config.json on top of defaults.
    public static func load(home: String = NSHomeDirectory()) throws -> Config {
        var config = defaults(home: home)
        let path = configPath(home: home)
        guard let data = FileManager.default.contents(atPath: path) else {
            return config
        }
        let partial = try JSONDecoder().decode(Partial.self, from: data)
        if let v = partial.recordingsDir { config.recordingsDir = v }
        if let v = partial.transcriptsPath { config.transcriptsPath = v }
        if let v = partial.seenPath { config.seenPath = v }
        if let v = partial.statusPath { config.statusPath = v }
        if let v = partial.appleNoteName { config.appleNoteName = v }
        if let v = partial.appleNoteEnabled { config.appleNoteEnabled = v }
        if let v = partial.alwaysDoubleTranscribe { config.alwaysDoubleTranscribe = v }
        if let v = partial.localeIdentifier { config.localeIdentifier = v }
        if let v = partial.mcpEnabled { config.mcpEnabled = v }
        if let v = partial.mcpHost { config.mcpHost = v }
        if let v = partial.mcpPort { config.mcpPort = v }
        return config
    }
}
