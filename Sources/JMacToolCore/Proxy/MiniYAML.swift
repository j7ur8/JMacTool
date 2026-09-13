import Foundation

/// Minimal YAML subset used by jpmanager data files: nested mappings,
/// sequences of scalars, sequences of mappings, quoted or plain scalars, and
/// comments. Values are kept as strings; the managed files never rely on YAML
/// type coercion.
enum MiniYAML {
    enum ParseError: Error, Equatable {
        case invalidSyntax(line: Int, description: String)
    }

    indirect enum Value: Equatable, Sendable {
        case scalar(String)
        case sequence([Value])
        case mapping([Entry])
    }

    struct Entry: Equatable, Sendable {
        var key: String
        var value: Value
    }

    // MARK: - Reading

    private struct RawLine {
        let number: Int
        let indent: Int
        let text: String
    }

    static func parse(_ content: String) throws -> Value {
        let rawLines: [RawLine] = content
            .components(separatedBy: .newlines)
            .enumerated()
            .compactMap { index, line in
                let trimmedLeading = String(line.replacingOccurrences(of: "\t", with: "    ").drop { $0 == " " })
                let indent = line.count - trimmedLeading.count
                let trimmedLine = trimmedLeading.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                    return nil
                }
                return RawLine(number: index + 1, indent: indent, text: trimmedLine)
            }

        guard !rawLines.isEmpty else {
            return .mapping([])
        }

        let (value, next) = parseBlock(rawLines: rawLines, start: 0, indent: rawLines[0].indent)
        guard next >= rawLines.count else {
            throw ParseError.invalidSyntax(line: rawLines[next].number, description: "unexpected indentation")
        }
        return value
    }

    private static func parseBlock(rawLines: [RawLine], start: Int, indent: Int) -> (Value, Int) {
        guard start < rawLines.count else {
            return (.scalar(""), start)
        }

        if isSequenceItem(rawLines[start].text) {
            return parseSequence(rawLines: rawLines, start: start, indent: indent)
        }

        return parseMapping(rawLines: rawLines, start: start, indent: indent)
    }

    private static func isSequenceItem(_ text: String) -> Bool {
        text == "-" || text.hasPrefix("- ")
    }

    private static func parseMapping(rawLines: [RawLine], start: Int, indent: Int) -> (Value, Int) {
        var entries: [Entry] = []
        var index = start

        while index < rawLines.count, rawLines[index].indent == indent,
              !isSequenceItem(rawLines[index].text) {
            let line = rawLines[index]

            guard let colonIndex = findKeyColon(in: line.text) else {
                // Not a key line; stop the block here (tolerated like the JS parser's permissive mode).
                break
            }

            let rawKey = String(line.text[line.text.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let key = unquoteScalar(rawKey)
            var rest = String(line.text[colonIndex...]).dropFirst().trimmingCharacters(in: .whitespaces)

            // Drop a trailing comment on a bare `key: value # note` line.
            if !isQuoted(rest) {
                rest = stripTrailingComment(rest)
            }

            if !rest.isEmpty {
                entries.append(Entry(key: key, value: .scalar(unquoteScalar(rest))))
                index += 1
                continue
            }

            let childIndent = index + 1 < rawLines.count ? rawLines[index + 1].indent : nil
            if let childIndent, childIndent > indent {
                let (value, next) = parseBlock(rawLines: rawLines, start: index + 1, indent: childIndent)
                entries.append(Entry(key: key, value: value))
                index = next
            } else {
                entries.append(Entry(key: key, value: .scalar("")))
                index += 1
            }
        }

        return (.mapping(entries), index)
    }

    private static func parseSequence(rawLines: [RawLine], start: Int, indent: Int) -> (Value, Int) {
        var items: [Value] = []
        var index = start

        while index < rawLines.count, rawLines[index].indent == indent,
              isSequenceItem(rawLines[index].text) {
            let line = rawLines[index]
            let dashText = String(line.text.dropFirst())
            let spacesAfterDash = dashText.prefix { $0 == " " }.count
            let content = String(dashText.dropFirst(spacesAfterDash)).trimmingCharacters(in: .whitespaces)

            if content.isEmpty {
                let childIndent = index + 1 < rawLines.count ? rawLines[index + 1].indent : nil
                if let childIndent, childIndent > indent {
                    let (value, next) = parseBlock(rawLines: rawLines, start: index + 1, indent: childIndent)
                    items.append(value)
                    index = next
                } else {
                    items.append(.scalar(""))
                    index += 1
                }
                continue
            }

            if isSequenceItem(content) || findKeyColon(in: content) != nil {
                // `- key: value` starts a mapping whose continuation lines align
                // with the first key's column.
                let contentColumn = indent + 1 + spacesAfterDash
                var synthetic = rawLines
                synthetic[index] = RawLine(number: line.number, indent: contentColumn, text: content)
                let (value, next) = parseMapping(rawLines: synthetic, start: index, indent: contentColumn)
                items.append(value)
                index = next
            } else {
                items.append(.scalar(unquoteScalar(stripTrailingComment(content))))
                index += 1
            }
        }

        return (.sequence(items), index)
    }

    private static func findKeyColon(in text: String) -> String.Index? {
        var inDoubleQuotes = false
        var inSingleQuotes = false
        var previous: Character? = nil

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if character == "\"" && !inSingleQuotes {
                if !inDoubleQuotes || previous != "\\" {
                    inDoubleQuotes.toggle()
                }
            } else if character == "'" && !inDoubleQuotes {
                if !inSingleQuotes || previous != "'" {
                    inSingleQuotes.toggle()
                }
            } else if character == ":", !inDoubleQuotes, !inSingleQuotes {
                let nextIndex = text.index(after: index)
                if nextIndex == text.endIndex || text[nextIndex] == " " {
                    return index
                }
            }

            previous = character
            index = text.index(after: index)
        }

        return nil
    }

    private static func isQuoted(_ text: String) -> Bool {
        (text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2)
            || (text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2)
    }

    private static func stripTrailingComment(_ text: String) -> String {
        var previous: Character? = nil
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "#", let previous, previous == " " || previous == "\t" {
                return String(text[text.startIndex..<index]).trimmingCharacters(in: .whitespaces)
            }
            previous = text[index]
            index = text.index(after: index)
        }
        return text
    }

    static func unquoteScalar(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            let inner = String(trimmed.dropFirst().dropLast())
            return unescapeDoubleQuoted(inner)
        }

        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }

        return trimmed
    }

    private static func unescapeDoubleQuoted(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let next = iterator.next() {
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Writing

    static func emit(_ value: Value) -> String {
        var lines: [String] = []
        emitValue(value, indent: 0, into: &lines)
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private static func emitValue(_ value: Value, indent: Int, into lines: inout [String]) {
        switch value {
        case .scalar(let scalar):
            lines.append(String(repeating: " ", count: indent) + quoteScalarIfNeeded(scalar))
        case .sequence(let items):
            for item in items {
                switch item {
                case .scalar(let scalar):
                    lines.append(String(repeating: " ", count: indent) + "- " + quoteScalarIfNeeded(scalar))
                default:
                    var itemLines: [String] = []
                    emitValue(item, indent: indent + 2, into: &itemLines)
                    if let first = itemLines.first {
                        lines.append(String(repeating: " ", count: indent) + "- " + first.dropFirst(indent + 2))
                        lines.append(contentsOf: itemLines.dropFirst())
                    }
                }
            }
        case .mapping(let entries):
            for entry in entries {
                let indentation = String(repeating: " ", count: indent)
                switch entry.value {
                case .scalar(let scalar):
                    lines.append(indentation + quoteKeyIfNeeded(entry.key) + ": " + quoteScalarIfNeeded(scalar))
                case .sequence(let items) where items.isEmpty:
                    lines.append(indentation + quoteKeyIfNeeded(entry.key) + ": []")
                case .mapping(let childEntries) where childEntries.isEmpty:
                    lines.append(indentation + quoteKeyIfNeeded(entry.key) + ": {}")
                default:
                    lines.append(indentation + quoteKeyIfNeeded(entry.key) + ":")
                    emitValue(entry.value, indent: indent + 2, into: &lines)
                }
            }
        }
    }

    private static let reservedScalars: Set<String> = [
        "true", "false", "null", "~",
        "yes", "no", "on", "off",
        "True", "False", "Null", "TRUE", "FALSE", "NULL"
    ]

    static func quoteScalarIfNeeded(_ scalar: String, quoteNumbers: Bool = true) -> String {
        let needsQuoting = scalar.isEmpty
            || scalar != scalar.trimmingCharacters(in: .whitespaces)
            || reservedScalars.contains(scalar)
            || (quoteNumbers && scalar.range(of: "^-?[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil)
            || scalar.contains(": ")
            || scalar.contains(" #")
            || scalar.hasSuffix(":")
            || scalar.hasSuffix("#")
            || scalar.hasPrefix("#")
            || scalar.hasPrefix("- ")
            || (scalar.first.map { "?:,[]{}&*!|>'\"%@`".contains($0) } ?? false)

        guard needsQuoting else {
            return scalar
        }

        let escaped = scalar
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func quoteKeyIfNeeded(_ key: String) -> String {
        let needsQuoting = key.isEmpty
            || key.range(of: "^[A-Za-z0-9_. -]+$", options: .regularExpression) == nil
            || key.hasPrefix(" ") || key.hasSuffix(" ")

        guard needsQuoting else {
            return key
        }

        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Convenience accessors are defined in the MiniYAML.Value extension below.
}

extension MiniYAML.Value {
    var scalarValue: String? {
        if case .scalar(let scalar) = self {
            return scalar
        }
        return nil
    }

    var sequenceValue: [MiniYAML.Value]? {
        if case .sequence(let items) = self {
            return items
        }
        return nil
    }

    var mappingValue: [MiniYAML.Entry]? {
        if case .mapping(let entries) = self {
            return entries
        }
        return nil
    }

    subscript(key: String) -> MiniYAML.Value? {
        guard let entries = mappingValue else {
            return nil
        }
        return entries.first(where: { $0.key == key })?.value
    }

    func string(_ key: String) -> String? {
        self[key]?.scalarValue
    }

    func array(_ key: String) -> [MiniYAML.Value]? {
        self[key]?.sequenceValue
    }

    func stringArray(_ key: String) -> [String] {
        array(key)?.compactMap(\.scalarValue) ?? []
    }
}
