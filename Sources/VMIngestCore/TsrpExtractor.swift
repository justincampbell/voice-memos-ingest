// TsrpExtractor.swift — pull Apple's embedded transcript out of an `.m4a`.
//
// Voice Memos stores its on-device transcript inside each `.m4a` in a custom
// MP4 atom named `tsrp`. The payload is JSON:
//
//   {"attributedString": <X>, "locale": [...]}
//
// where <X> is the attributed string in ONE OF TWO shapes (key order varies
// between files):
//
//   dict shape:  {"attributeTable": [...], "runs": ["word ", 0, "next ", 1, ...]}
//   list shape:  ["word ", {attr}, "next ", {attr}, ...]
//
// In both shapes the plain transcript is the concatenation of the *string*
// elements. The atom only exists after a memo has been opened/transcribed in
// the Voice Memos app — many memos have audio but no `tsrp`.

import Foundation

public enum TsrpExtractor {
    /// Extract Apple's transcript from an `.m4a`, or nil if there is no `tsrp`
    /// atom (memo never opened in the app) or it cannot be parsed.
    public static func extract(fromFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return extract(from: data)
    }

    /// Extract from raw file bytes. Exposed for testing with fixtures.
    public static func extract(from data: Data) -> String? {
        guard let jsonData = jsonSlice(after: Array("tsrp".utf8), in: data) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) else { return nil }
        guard let dict = obj as? [String: Any],
              let attributed = dict["attributedString"] else { return nil }
        return plainText(fromAttributedString: attributed)
    }

    /// Concatenate the string elements of either attributedString shape.
    static func plainText(fromAttributedString attributed: Any) -> String? {
        // dict shape: { "runs": [str, int, ...] }
        if let asDict = attributed as? [String: Any], let runs = asDict["runs"] as? [Any] {
            return concatStrings(runs)
        }
        // list shape: [str, {attr}, str, {attr}, ...]
        if let asList = attributed as? [Any] {
            return concatStrings(asList)
        }
        return nil
    }

    private static func concatStrings(_ elements: [Any]) -> String {
        var out = ""
        for el in elements {
            if let s = el as? String { out += s }
        }
        return out
    }

    /// Find `marker` in `data`, then return the brace-balanced JSON object that
    /// starts at the first `{` after it. Tracks string state and escapes so
    /// braces inside string literals don't throw off the depth count.
    static func jsonSlice(after marker: [UInt8], in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard let markerEnd = firstIndex(of: marker, in: bytes) else { return nil }

        // First `{` at or after the end of the marker.
        let openBrace = UInt8(ascii: "{")
        var start = markerEnd
        while start < bytes.count && bytes[start] != openBrace { start += 1 }
        guard start < bytes.count else { return nil }

        let closeBrace = UInt8(ascii: "}")
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if b == backslash {
                    escaped = true
                } else if b == quote {
                    inString = false
                }
            } else {
                if b == quote {
                    inString = true
                } else if b == openBrace {
                    depth += 1
                } else if b == closeBrace {
                    depth -= 1
                    if depth == 0 {
                        return Data(bytes[start...i])
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// Index just past the first occurrence of `needle` in `haystack`.
    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            var j = 0
            while j < needle.count && haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i + needle.count }
            i += 1
        }
        return nil
    }
}
