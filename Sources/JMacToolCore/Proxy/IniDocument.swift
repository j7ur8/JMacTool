import Foundation

/// INI document model compatible with the subset of the npm `ini` package that
/// jpmanager relies on: `[section]` headers, `key = value` pairs (first `=` or
/// `:` delimits), full-line comments, and quoted values.
struct IniDocument {
    struct Entry {
        var key: String
        var value: String
    }

    struct Section {
        var name: String
        var entries: [Entry]

        mutating func upsert(key: String, value: String) {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                entries[index].value = value
            } else {
                entries.append(Entry(key: key, value: value))
            }
        }
    }

    var root: [Entry] = []
    var sections: [Section] = []

    static func parse(_ content: String) -> IniDocument {
        var document = IniDocument()
        var sectionIndex: Int? = nil

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 {
                let name = String(line.dropFirst().dropLast())
                if let existing = document.sections.firstIndex(where: { $0.name == name }) {
                    sectionIndex = existing
                } else {
                    document.sections.append(Section(name: name, entries: []))
                    sectionIndex = document.sections.count - 1
                }
                continue
            }

            guard let (key, value) = splitKeyValue(line) else {
                continue
            }

            if let sectionIndex {
                document.sections[sectionIndex].upsert(key: key, value: value)
            } else {
                document.root.upsert(key: key, value: value)
            }
        }

        return document
    }

    private static func splitKeyValue(_ line: String) -> (String, String)? {
        var equalsIndex = line.firstIndex(of: "=")
        var colonIndex = line.firstIndex(of: ":")

        if let equals = equalsIndex, let colon = colonIndex {
            if colon < equals {
                equalsIndex = nil
            } else {
                colonIndex = nil
            }
        }

        let delimiterIndex = equalsIndex ?? colonIndex
        guard let delimiterIndex else {
            return nil
        }

        let key = String(line[line.startIndex..<delimiterIndex]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(line[line.index(after: delimiterIndex)...]).trimmingCharacters(in: .whitespaces)

        guard !key.isEmpty else {
            return nil
        }

        return (key, stripMatchingQuotes(stripInlineComment(rawValue)))
    }

    private static func stripInlineComment(_ value: String) -> String {
        guard let range = value.range(of: #"[ \t](?:;|#)"#, options: .regularExpression) else {
            return value
        }
        return String(value[value.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func stripMatchingQuotes(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        if trimmed.count >= 2,
           trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }

        if trimmed.count >= 2,
           trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast())
        }

        return trimmed
    }

    // MARK: - Reading

    func value(forKey key: String) -> String? {
        root.first(where: { $0.key == key })?.value
    }

    func value(section sectionName: String, key: String) -> String? {
        sections.first(where: { $0.name == sectionName })?
            .entries.first(where: { $0.key == key })?.value
    }

    // MARK: - Writing

    mutating func set(_ value: String, forKey key: String, removeIfEmpty: Bool) {
        if removeIfEmpty, value.isEmpty {
            root.removeAll(where: { $0.key == key })
            return
        }
        root.upsert(key: key, value: value)
    }

    mutating func set(_ value: String, section sectionName: String, key: String, removeIfEmpty: Bool) {
        if removeIfEmpty, value.isEmpty {
            guard let sectionIdx = sections.firstIndex(where: { $0.name == sectionName }) else {
                return
            }
            sections[sectionIdx].entries.removeAll(where: { $0.key == key })
            if sections[sectionIdx].entries.isEmpty {
                sections.remove(at: sectionIdx)
            }
            return
        }

        if let sectionIdx = sections.firstIndex(where: { $0.name == sectionName }) {
            sections[sectionIdx].upsert(key: key, value: value)
        } else {
            sections.append(Section(name: sectionName, entries: [Entry(key: key, value: value)]))
        }
    }

    func serialize() -> String {
        var lines: [String] = root.map { "\($0.key) = \($0.value)" }

        for section in sections {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("[\(section.name)]")
            lines.append(contentsOf: section.entries.map { "\($0.key) = \($0.value)" })
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Content-level helpers (jpmanager upsert semantics)

    static func upsertKeys(
        in content: String,
        entries: [(String, String)],
        removeEmpty: Bool
    ) -> String {
        var document = IniDocument.parse(content)
        for (key, value) in entries {
            document.set(value, forKey: key, removeIfEmpty: removeEmpty)
        }
        return document.serialize()
    }

    static func upsertSectionKeys(
        in content: String,
        section sectionName: String,
        entries: [(String, String)],
        removeEmpty: Bool
    ) -> String {
        var document = IniDocument.parse(content)
        for (key, value) in entries {
            document.set(value, section: sectionName, key: key, removeIfEmpty: removeEmpty)
        }
        return document.serialize()
    }
}

private extension Array where Element == IniDocument.Entry {
    mutating func upsert(key: String, value: String) {
        if let index = firstIndex(where: { $0.key == key }) {
            self[index].value = value
        } else {
            append(IniDocument.Entry(key: key, value: value))
        }
    }
}
