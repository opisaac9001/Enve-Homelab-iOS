import Foundation

/// Masks credentials that servers write into their logs (query-string keys, tokens, bearer headers) before a line is shown.
/// Addresses and paths are kept: they're what makes a log useful for diagnosis, and they never leave this device.
enum LogRedactor {
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?i)\b(api_?key|apikey|x-plex-token|x-emby-token|x-mediabrowser-token|access_?token|token|password|passwd|secret)(["']?\s*[=:]\s*["']?)([^&\s"',;]+)"#, "$1$2[redacted]"),
        (#"(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [redacted]"),
        (#"(?i)(MediaBrowser[^\n]*?Token=")([^"]+)(")"#, "$1[redacted]$3"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ line: String) -> String {
        patterns.reduce(line) { text, pattern in
            pattern.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: pattern.1)
        }
    }
}
