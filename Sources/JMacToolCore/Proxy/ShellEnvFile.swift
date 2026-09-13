import Foundation

/// Reads/writes the jpmanager-managed proxy export block inside shell rc files
/// (`managed-shell-env` handler). The marker strings are kept identical to the
/// original jpmanager so both tools stay compatible with `~/.zshrc`.
enum ShellEnvFile {
    static let blockStart = ProxyConstants.zshManagedBlockStart
    static let blockEnd = ProxyConstants.zshManagedBlockEnd

    static let shellProxyKeys = [
        "http_proxy",
        "https_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "all_proxy",
        "no_proxy",
        "NO_PROXY"
    ]

    // MARK: - Block handling

    static func readManagedShellExports(content: String) -> [String: String] {
        guard let startRange = content.range(of: blockStart) else {
            return [:]
        }

        guard let endRange = content.range(of: blockEnd, range: startRange.upperBound..<content.endIndex) else {
            return [:]
        }

        // Block body matches `START\n(body)\nEND`.
        let bodyStart = startRange.upperBound
        guard bodyStart < content.endIndex, content[bodyStart] == "\n" else {
            return [:]
        }
        let bodyEnd = endRange.lowerBound
        guard bodyEnd > bodyStart, content[content.index(before: bodyEnd)] == "\n" else {
            return [:]
        }

        let body = String(content[bodyStart..<content.index(before: bodyEnd)])

        var exports: [String: String] = [:]
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(of: /^export\s+([A-Za-z_][A-Za-z0-9_]*)="(.*)"$/) else {
                continue
            }
            let key = String(match.1)
            let value = String(match.2).replacingOccurrences(of: "\\\"", with: "\"")
            exports[key] = value
        }
        return exports
    }

    static func readShellExport(content: String, key: String) -> String {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.firstMatch(of: /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) else {
                continue
            }
            guard String(match.1) == key else {
                continue
            }
            return ProxyDisplay.normalizeValue(LineFormats.stripMatchingQuotes(String(match.2)))
        }
        return ""
    }

    static func removeShellExports(content: String, keys: [String]) -> String {
        let keyPattern = keys
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "^(?:export\\s+)?(?:\(keyPattern))=.*$"

        var nextLines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.range(of: pattern, options: .regularExpression) == nil
            }

        while let last = nextLines.last, last.isEmpty {
            nextLines.removeLast()
        }

        return nextLines.isEmpty ? "" : nextLines.joined(separator: "\n") + "\n"
    }

    static func upsertManagedShellExports(content: String, entries: [(String, String)]) -> String {
        let exportLines = entries
            .filter { !$0.1.isEmpty }
            .map { key, value -> String in
                let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
                return "export \(key)=\"\(escapedValue)\""
            }

        var stripped = removeManagedBlocks(content)
        while stripped.hasSuffix("\n") {
            stripped.removeLast()
        }

        if exportLines.isEmpty {
            return stripped.isEmpty ? "" : stripped + "\n"
        }

        let block = ([blockStart] + exportLines + [blockEnd]).joined(separator: "\n")
        return stripped.isEmpty ? block + "\n" : stripped + "\n\n" + block + "\n"
    }

    private static func removeManagedBlocks(_ content: String) -> String {
        var result = content
        while let startRange = result.range(of: blockStart) {
            let searchEnd = startRange.upperBound
            guard searchEnd <= result.endIndex else {
                break
            }

            // Swallow an optional newline directly before the start marker.
            var removalStart = startRange.lowerBound
            if removalStart > result.startIndex,
               result[result.index(before: removalStart)] == "\n" {
                removalStart = result.index(before: removalStart)
            }

            guard let endRange = result.range(of: blockEnd, range: searchEnd..<result.endIndex) else {
                break
            }

            var removalEnd = endRange.upperBound
            if removalEnd < result.endIndex, result[removalEnd] == "\n" {
                removalEnd = result.index(after: removalEnd)
            }

            result.removeSubrange(removalStart..<removalEnd)
        }
        return result
    }

    // MARK: - Environment state

    static func readEnvironmentProxyState(content: String) -> ProxyState {
        let managed = readManagedShellExports(content: content)
        func managedOrRaw(_ managedKeys: [String], rawKeys: [String]) -> String {
            for key in managedKeys where !(managed[key] ?? "").isEmpty {
                return ProxyDisplay.normalizeValue(managed[key] ?? "")
            }
            for key in rawKeys where !readShellExport(content: content, key: key).isEmpty {
                return readShellExport(content: content, key: key)
            }
            return ""
        }

        var state = ProxyState.empty
        state.httpProxy = managedOrRaw(["http_proxy", "HTTP_PROXY"], rawKeys: ["http_proxy", "HTTP_PROXY"])
        state.httpsProxy = managedOrRaw(["https_proxy", "HTTPS_PROXY"], rawKeys: ["https_proxy", "HTTPS_PROXY"])
        state.socks5Proxy = managedOrRaw(["ALL_PROXY", "all_proxy"], rawKeys: ["ALL_PROXY", "all_proxy"])
        state.noProxy = managedOrRaw(["no_proxy", "NO_PROXY"], rawKeys: ["no_proxy", "NO_PROXY"])
        return state
    }

    static func applyEnvironmentProxyState(context: ProxyFileContext, targetPath: String, state: ProxyState) {
        let content = context.readTextFile(targetPath)
        let httpsValue = state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy
        let nextContent = upsertManagedShellExports(content: content, entries: [
            ("http_proxy", state.httpProxy),
            ("https_proxy", httpsValue),
            ("HTTP_PROXY", state.httpProxy),
            ("HTTPS_PROXY", httpsValue),
            ("ALL_PROXY", state.socks5Proxy),
            ("all_proxy", state.socks5Proxy),
            ("no_proxy", state.noProxy),
            ("NO_PROXY", state.noProxy)
        ])
        context.writeTextFile(targetPath, nextContent)
    }

    static func clearEnvironmentProxyState(context: ProxyFileContext, targetPath: String) {
        let content = context.readTextFile(targetPath)
        let nextContent = removeShellExports(
            content: upsertManagedShellExports(content: content, entries: []),
            keys: shellProxyKeys
        )
        context.syncTextFile(targetPath, nextContent)
    }
}
