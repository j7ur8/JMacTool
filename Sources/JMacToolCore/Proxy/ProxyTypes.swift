import Foundation

/// Shared user-facing error for the proxy engine; the CLI boundary prints the
/// message to stderr and exits non-zero.
struct ProxyEngineError: Error, Sendable {
    var message: String
    var usage: String = ""
    var exitCode: Int32 = 1
}

/// The four proxy settings a managed profile or target state carries.
/// Field names mirror the `*_proxy` keys used by the original jpmanager data
/// files so `~/.jpmanager` stays compatible.
struct ProxyState: Equatable, Sendable {
    var httpProxy: String = ""
    var httpsProxy: String = ""
    var socks5Proxy: String = ""
    var noProxy: String = ""

    static let empty = ProxyState()

    subscript(key: ProxyStateKey) -> String {
        get {
            switch key {
            case .httpProxy: return httpProxy
            case .httpsProxy: return httpsProxy
            case .socks5Proxy: return socks5Proxy
            case .noProxy: return noProxy
            }
        }
        set {
            switch key {
            case .httpProxy: httpProxy = newValue
            case .httpsProxy: httpsProxy = newValue
            case .socks5Proxy: socks5Proxy = newValue
            case .noProxy: noProxy = newValue
            }
        }
    }
}

enum ProxyStateKey: String, CaseIterable, Sendable {
    case httpProxy = "http_proxy"
    case httpsProxy = "https_proxy"
    case socks5Proxy = "socks5_proxy"
    case noProxy = "no_proxy"
}

extension ProxyState: Codable {
    private enum CodingKeys: String, CodingKey {
        case httpProxy = "http_proxy"
        case httpsProxy = "https_proxy"
        case socks5Proxy = "socks5_proxy"
        case noProxy = "no_proxy"
    }
}

/// A saved proxy profile: a name plus the shared proxy state.
struct ProxyProfile: Equatable, Sendable {
    var name: String
    var state: ProxyState

    var stateValues: [ProxyStateKey: String] {
        [
            .httpProxy: state.httpProxy,
            .httpsProxy: state.httpsProxy,
            .socks5Proxy: state.socks5Proxy,
            .noProxy: state.noProxy
        ]
    }
}

enum ProxyDisplay {
    static func normalizeValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" || trimmed == "undefined" || trimmed == "None" {
            return ""
        }
        return trimmed
    }

    static func normalizeComparableState(_ state: ProxyState) -> ProxyState {
        var normalized = ProxyState.empty
        for key in ProxyStateKey.allCases {
            normalized[key] = normalizeValue(state[key])
        }
        return normalized
    }

    static func redactProxyURL(_ proxyURL: String) -> String {
        guard !proxyURL.isEmpty else {
            return ""
        }

        guard var components = URLComponents(string: proxyURL), components.host != nil else {
            if let range = proxyURL.range(of: "://[^/@\\s]+@") {
                var redacted = proxyURL
                redacted.replaceSubrange(range, with: "://****@")
                return redacted
            }
            return proxyURL
        }

        if components.user == nil && components.password == nil {
            return proxyURL
        }

        components.user = "****"
        components.password = components.password == nil ? nil : "****"
        return components.string ?? proxyURL
    }

    static func redactState(_ state: ProxyState) -> ProxyState {
        var redacted = normalizeComparableState(state)
        redacted.httpProxy = redactProxyURL(state.httpProxy)
        redacted.httpsProxy = redactProxyURL(state.httpsProxy)
        redacted.socks5Proxy = redactProxyURL(state.socks5Proxy)
        redacted.noProxy = normalizeValue(state.noProxy)
        return redacted
    }

    static func describe(_ state: ProxyState) -> String {
        let display = redactState(state)
        var parts: [String] = []
        if !display.httpProxy.isEmpty {
            parts.append("http=\(display.httpProxy)")
        }
        if !display.httpsProxy.isEmpty {
            parts.append("https=\(display.httpsProxy)")
        }
        if !display.socks5Proxy.isEmpty {
            parts.append("socks5=\(display.socks5Proxy)")
        }
        if !display.noProxy.isEmpty {
            parts.append("no_proxy=\(display.noProxy)")
        }
        return parts.isEmpty ? "Not set" : parts.joined(separator: " | ")
    }
}
