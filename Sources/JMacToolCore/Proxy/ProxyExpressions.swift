import Foundation

/// Evaluates the `read`/`write`/`clear` expressions declared in target
/// definitions, ported from the jpmanager expression helpers.
enum ProxyExpressions {
    static func evaluate(_ expression: String, state: ProxyState) -> String {
        if expression.isEmpty {
            return ""
        }

        switch expression {
        case "http_proxy": return state.httpProxy
        case "https_proxy": return state.httpsProxy
        case "socks5_proxy": return state.socks5Proxy
        case "no_proxy": return state.noProxy
        case "https_or_http": return state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy
        case "http_or_pick": return state.httpProxy.isEmpty ? ProxyURL.pick(state) : state.httpProxy
        case "https_or_http_or_pick":
            if !state.httpsProxy.isEmpty {
                return state.httpsProxy
            }
            return state.httpProxy.isEmpty ? ProxyURL.pick(state) : state.httpProxy
        case "pick_proxy": return ProxyURL.pick(state)
        default: return expression
        }
    }

    /// `write`/`clear` declared as a mapping `{ fileKey: expression }`,
    /// kept in declaration order so file output is deterministic.
    static func buildEntriesFromMap(_ map: MiniYAML.Value?, state: ProxyState) -> [(String, String)] {
        guard let entries = map?.mappingValue else {
            return []
        }

        return entries.map { entry in
            (entry.key, evaluate(entry.value.scalarValue ?? "", state: state))
        }
    }

    /// `write`/`clear` declared as a sequence of `{ section, key, value }`.
    static func sectionEntries(_ value: MiniYAML.Value?) -> [(section: String, key: String, expression: String)] {
        guard let items = value?.sequenceValue else {
            return []
        }

        return items.compactMap { item in
            guard let section = item.string("section"),
                  let key = item.string("key") else {
                return nil
            }
            return (section, key, item.string("value") ?? "")
        }
    }

    static func buildStateFromSingleProxyURL(_ proxyURL: String) -> ProxyState {
        let normalized = ProxyDisplay.normalizeValue(proxyURL)
        var state = ProxyState.empty
        state.httpProxy = normalized
        state.httpsProxy = normalized
        state.socks5Proxy = normalized.hasPrefix("socks5") ? normalized : ""
        state.noProxy = ""
        return state
    }

    /// `read` declared as `{ fileKey: stateKey }` or `{ proxy: fileKey }`.
    static func stateFromRootReadMap(_ document: IniDocument, readMap: MiniYAML.Value?) -> ProxyState {
        if let proxyKey = readMap?.string("proxy") {
            return buildStateFromSingleProxyURL(document.value(forKey: proxyKey) ?? "")
        }

        var state = ProxyState.empty
        if let key = readMap?.string("http_proxy") {
            state.httpProxy = document.value(forKey: key) ?? ""
        }
        if let key = readMap?.string("https_proxy") {
            state.httpsProxy = document.value(forKey: key) ?? ""
        }
        if let key = readMap?.string("socks5_proxy") {
            state.socks5Proxy = document.value(forKey: key) ?? ""
        }
        if let key = readMap?.string("no_proxy") {
            state.noProxy = document.value(forKey: key) ?? ""
        }
        return state
    }

    /// `read` declared as `{ stateKey: { section, key } }` or `{ proxy: {...} }`.
    static func stateFromSectionReadMap(_ document: IniDocument, readMap: MiniYAML.Value?) -> ProxyState {
        if let proxyRef = readMap?["proxy"] {
            let section = proxyRef.string("section") ?? ""
            let key = proxyRef.string("key") ?? ""
            return buildStateFromSingleProxyURL(document.value(section: section, key: key) ?? "")
        }

        func read(_ stateKey: String) -> String {
            guard let ref = readMap?[stateKey] else {
                return ""
            }
            return document.value(section: ref.string("section") ?? "", key: ref.string("key") ?? "") ?? ""
        }

        var state = ProxyState.empty
        state.httpProxy = read("http_proxy")
        state.httpsProxy = read("https_proxy")
        state.socks5Proxy = read("socks5_proxy")
        state.noProxy = read("no_proxy")
        return state
    }

    /// Applies a sequence of section entries to INI content.
    static func applyIniSectionEntries(
        content: String,
        entries: [(section: String, key: String, expression: String)],
        state: ProxyState,
        removeEmpty: Bool
    ) -> String {
        var nextContent = content
        for entry in entries {
            nextContent = IniDocument.upsertSectionKeys(
                in: nextContent,
                section: entry.section,
                entries: [(entry.key, evaluate(entry.expression, state: state))],
                removeEmpty: removeEmpty
            )
        }
        return nextContent
    }
}
