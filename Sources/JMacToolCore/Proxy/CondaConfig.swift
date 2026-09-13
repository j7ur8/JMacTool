import Foundation

/// Conda `~/.condarc` `proxy_servers` section management
/// (`condarc-proxy-servers` handler). The section is manipulated line by line
/// so the rest of the YAML file is preserved verbatim.
enum CondaConfig {
    // MARK: - Reading

    static func parseCondaScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return ""
        }

        let withoutComment = trimmed.replacingOccurrences(
            of: #"\s+#.*$"#,
            with: "",
            options: .regularExpression
        )
        return LineFormats.stripMatchingQuotes(withoutComment)
    }

    static func readProxyEntries(content: String) -> [String: String] {
        var entries: [String: String] = [:]
        var inProxySection = false
        var sectionIndent = 0

        for line in splitLines(content) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inProxySection {
                if let match = line.firstMatch(of: /^(\s*)proxy_servers\s*:\s*(?:#.*)?$/) {
                    inProxySection = true
                    sectionIndent = String(match.1).count
                }
                continue
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let currentIndent = leadingWhitespaceCount(line)
            if currentIndent <= sectionIndent {
                break
            }

            guard let match = line.firstMatch(of: /^\s*([^:]+?)\s*:\s*(.*?)\s*$/) else {
                continue
            }

            let key = LineFormats.stripMatchingQuotes(String(match.1).trimmingCharacters(in: .whitespaces))
            entries[key] = parseCondaScalar(String(match.2))
        }

        return entries
    }

    static func currentState(content: String) -> ProxyState {
        let entries = readProxyEntries(content: content)

        var state = ProxyState.empty
        state.httpProxy = ProxyDisplay.normalizeValue(entries["http"] ?? "")
        state.httpsProxy = ProxyDisplay.normalizeValue(entries["https"] ?? "")
        state.socks5Proxy = ProxyDisplay.normalizeValue(entries["socks5"] ?? "")
        state.noProxy = ""
        return state
    }

    // MARK: - Writing

    static func buildProxyEntries(_ state: ProxyState) -> [(String, String)] {
        let fallback = ProxyURL.pick(state)
        let https = !state.httpsProxy.isEmpty ? state.httpsProxy : (!state.httpProxy.isEmpty ? state.httpProxy : fallback)
        return [
            ("http", state.httpProxy.isEmpty ? fallback : state.httpProxy),
            ("https", https),
            ("socks5", state.socks5Proxy)
        ]
    }

    static func upsert(content: String, state: ProxyState) -> String {
        let entries = buildProxyEntries(state)
        var nextLines: [String] = []
        var inProxySection = false
        var sectionIndent = 0

        for line in splitLines(content) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inProxySection {
                if let match = line.firstMatch(of: /^(\s*)proxy_servers\s*:\s*(?:#.*)?$/) {
                    inProxySection = true
                    sectionIndent = String(match.1).count
                    continue
                }

                nextLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                continue
            }

            let currentIndent = leadingWhitespaceCount(line)
            if trimmed.hasPrefix("#") && currentIndent > sectionIndent {
                continue
            }

            if currentIndent <= sectionIndent {
                inProxySection = false
                nextLines.append(line)
            }
        }

        while let last = nextLines.last, last.isEmpty {
            nextLines.removeLast()
        }

        let nonEmptyEntries = entries.filter { !$0.1.isEmpty }
        if !nonEmptyEntries.isEmpty {
            if !nextLines.isEmpty {
                nextLines.append("")
            }

            nextLines.append("proxy_servers:")
            for (key, value) in nonEmptyEntries {
                nextLines.append("  \(key): \(LineFormats.quoteJSON(value))")
            }
        }

        return nextLines.isEmpty ? "" : nextLines.joined(separator: "\n") + "\n"
    }

    static func expectedState(_ state: ProxyState) -> ProxyState {
        currentState(content: upsert(content: "", state: state))
    }

    // MARK: - Helpers

    private static func splitLines(_ content: String) -> [String] {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}
