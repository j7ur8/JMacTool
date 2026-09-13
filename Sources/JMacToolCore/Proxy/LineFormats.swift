import Foundation

/// Line-based `KEY=value` formats: Go env files (`~/.config/go/env`) and
/// `.yarnrc` (`key "value"`), ported from the jpmanager line handlers.
enum LineFormats {
    static func stripMatchingQuotes(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }

        return trimmed
    }

    static func quoteJSON(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func normalize(_ value: String) -> String {
        ProxyDisplay.normalizeValue(value)
    }

    private static func readLineValue(content: String, key: String, parseLine: (String) -> (String, String)?) -> String {
        let lines = splitLines(content)
        for line in lines.reversed() {
            guard let (parsedKey, parsedValue) = parseLine(line), parsedKey == key else {
                continue
            }
            return normalize(parsedValue)
        }
        return ""
    }

    private static func upsertLineEntries(
        content: String,
        entries: [(String, String)],
        parseLine: (String) -> (String, String)?,
        formatEntry: (String, String) -> String
    ) -> String {
        let managedKeys = Set(entries.map(\.0))
        var preservedLines = splitLines(content).filter { line in
            guard let (key, _) = parseLine(line) else {
                return true
            }
            return !managedKeys.contains(key)
        }

        while let last = preservedLines.last, last.isEmpty {
            preservedLines.removeLast()
        }

        let nextLines = preservedLines
            + entries
            .filter { !$0.1.isEmpty }
            .map { formatEntry($0.0, $0.1) }

        return nextLines.isEmpty ? "" : nextLines.joined(separator: "\n") + "\n"
    }

    private static func splitLines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: - Go env

    static func parseGoEnvLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return nil
        }

        guard let match = line.firstMatch(of: /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/) else {
            return nil
        }

        return (String(match.1), stripMatchingQuotes(String(match.2)))
    }

    static func readGoEnvKey(content: String, key: String) -> String {
        readLineValue(content: content, key: key, parseLine: parseGoEnvLine)
    }

    static func quoteGoEnvValue(_ value: String) -> String {
        value.contains(where: { $0 == " " || $0 == "\t" }) ? quoteJSON(value) : value
    }

    static func upsertGoEnvKeys(content: String, entries: [(String, String)]) -> String {
        upsertLineEntries(
            content: content,
            entries: entries,
            parseLine: parseGoEnvLine
        ) { key, value in
            "\(key)=\(quoteGoEnvValue(value))"
        }
    }

    // MARK: - YarnRC

    static func parseYarnRcLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            return nil
        }

        guard let match = trimmed.firstMatch(of: /^(\S+)\s+(.+)$/) else {
            return nil
        }

        return (String(match.1), stripMatchingQuotes(String(match.2)))
    }

    static func readYarnRcKey(content: String, key: String) -> String {
        readLineValue(content: content, key: key, parseLine: parseYarnRcLine)
    }

    static func upsertYarnRcKeys(content: String, entries: [(String, String)]) -> String {
        upsertLineEntries(
            content: content,
            entries: entries,
            parseLine: parseYarnRcLine
        ) { key, value in
            "\(key) \(quoteJSON(value))"
        }
    }
}
