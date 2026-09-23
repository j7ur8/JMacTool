import Foundation

/// Docker daemon JSON config management (`docker-json` handler): edits the
/// `proxies.http-proxy` / `https-proxy` / `no-proxy` keys of OrbStack's
/// `~/.orbstack/config/docker.json` while keeping every other key intact.
/// OrbStack rewrites this file in its own style, so the exact formatting does
/// not need to be preserved and the output is normalized via
/// JSONSerialization. A missing, empty, or malformed file is treated as an
/// empty document and rebuilt around the `proxies` section.
enum DockerJSONConfig {
    // MARK: - Reading

    static func currentState(content: String) -> ProxyState {
        guard let document = parse(content) else {
            return .empty
        }

        let proxies = document["proxies"] as? [String: Any] ?? [:]
        func value(_ key: String) -> String {
            proxies[key] as? String ?? ""
        }

        var state = ProxyState.empty
        state.httpProxy = value("http-proxy")
        state.httpsProxy = value("https-proxy")
        state.noProxy = value("no-proxy")
        return state
    }

    // MARK: - Writing

    static func upsert(content: String, state: ProxyState) -> String {
        var document = parse(content) ?? [:]
        var proxies = document["proxies"] as? [String: Any] ?? [:]

        let httpProxy = state.httpProxy
        let httpsProxy = state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy
        if httpProxy.isEmpty {
            proxies.removeValue(forKey: "http-proxy")
        } else {
            proxies["http-proxy"] = httpProxy
        }
        if httpsProxy.isEmpty {
            proxies.removeValue(forKey: "https-proxy")
        } else {
            proxies["https-proxy"] = httpsProxy
        }
        if state.noProxy.isEmpty {
            proxies.removeValue(forKey: "no-proxy")
        } else {
            proxies["no-proxy"] = state.noProxy
        }

        if proxies.isEmpty {
            document.removeValue(forKey: "proxies")
        } else {
            document["proxies"] = proxies
        }

        return serialize(document)
    }

    static func expectedState(_ state: ProxyState) -> ProxyState {
        currentState(content: upsert(content: "", state: state))
    }

    // MARK: - Helpers

    private static func parse(_ content: String) -> [String: Any]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let document = object as? [String: Any]
        else {
            return nil
        }
        return document
    }

    private static func serialize(_ document: [String: Any]) -> String {
        guard !document.isEmpty,
            let data = try? JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return "{}\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
