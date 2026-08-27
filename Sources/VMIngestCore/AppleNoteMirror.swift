// AppleNoteMirror.swift — optional human-facing mirror in Apple Notes.
//
// Each new transcript is appended to a single dedicated note (created on first
// use) via AppleScript. This is a convenience mirror, NOT the source of truth:
// the note is mutable and has no clean cursor. Disabled by default; toggled with
// `appleNoteEnabled` in config.
//
// ⚠️ LEGACY / DESTRUCTIVE — point this at a DEDICATED note only.
// It appends with AppleScript `set body of theNote`, which re-renders the note's
// HTML and therefore DESTROYS checklists, tables, and attachments. That is why
// the project standard for appending to a real note is the Shortcuts "Append to
// Note" action (see router/append-note.sh), and why this stays off by default.
// Do not aim it at a note you care about, and do not extend this path — new
// note-writing work belongs in the Shortcuts router.

import Foundation

public enum AppleNoteMirrorError: Error, CustomStringConvertible {
    case scriptFailed(String)
    public var description: String {
        switch self {
        case .scriptFailed(let m): return "Apple Notes scripting failed: \(m)"
        }
    }
}

public enum AppleNoteMirror {
    /// Append one transcript record to the configured note, creating the note if
    /// it doesn't exist. No-op (returns false) when mirroring is disabled.
    @discardableResult
    public static func append(_ record: TranscriptRecord, config: Config) throws -> Bool {
        guard config.appleNoteEnabled else { return false }

        let header = "\(record.recordedAt) — \(record.title) [\(record.source.rawValue)]"
        let entry = "<div><b>\(htmlEscape(header))</b></div><div>\(htmlEscape(record.text))</div><div><br></div>"

        // Capture the created note directly rather than re-looking it up by
        // name: a freshly-made note isn't reliably findable by `whose name is`
        // in the same script run, which silently drops the append.
        let name = appleScriptEscape(config.appleNoteName)
        let script = """
        tell application "Notes"
            if (exists note named "\(name)") then
                set theNote to first note whose name is "\(name)"
            else
                set theNote to make new note with properties {name:"\(name)", body:"<div><h1>\(appleScriptEscape(htmlEscape(config.appleNoteName)))</h1></div>"}
            end if
            set body of theNote to (body of theNote) & "\(appleScriptEscape(entry))"
        end tell
        """
        try runAppleScript(script)
        return true
    }

    private static func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw AppleNoteMirrorError.scriptFailed("could not compile script")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
            throw AppleNoteMirrorError.scriptFailed(msg)
        }
    }

    /// Escape for embedding inside an AppleScript double-quoted string literal.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Escape for safe insertion into the note's HTML body.
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
