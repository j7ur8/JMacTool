import Foundation

/// Proxy URL parsing/building helpers mirroring the jpmanager URL semantics:
/// default ports per protocol, optional user/password, and a pick order of
/// https -> http -> socks5.
enum ProxyURL {
    struct Parts: Equatable, Sendable {
        var `protocol`: String
        var host: String
        var port: String
        var username: String
        var password: String
    }

    static func defaultPort(forProtocol `protocol`: String) -> String {
        switch `protocol` {
        case "https":
            return "443"
        case "socks4", "socks5":
            return "1080"
        default:
            return "80"
        }
    }

    static func parse(_ proxyURL: String) -> Parts? {
        guard !proxyURL.isEmpty,
              let components = URLComponents(string: proxyURL),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        var protocolName = components.scheme ?? "http"
        if protocolName.hasSuffix(":") {
            protocolName = String(protocolName.dropLast())
        }

        let explicitPort = components.port.map(String.init) ?? ""

        return Parts(
            protocol: protocolName,
            host: host,
            port: explicitPort.isEmpty ? defaultPort(forProtocol: protocolName) : explicitPort,
            username: components.user ?? "",
            password: components.password ?? ""
        )
    }

    static func build(
        protocol protocolName: String,
        host: String,
        port: String,
        username: String = "",
        password: String = ""
    ) -> String {
        guard !host.isEmpty else {
            return ""
        }

        let auth = !username.isEmpty || !password.isEmpty
            ? "\(username)\(!password.isEmpty ? ":\(password)" : "")@"
            : ""

        return "\(protocolName.isEmpty ? "http" : protocolName)://\(auth)\(host)\(!port.isEmpty ? ":\(port)" : "")"
    }

    static func pick(_ state: ProxyState) -> String {
        if !state.httpsProxy.isEmpty {
            return state.httpsProxy
        }
        if !state.httpProxy.isEmpty {
            return state.httpProxy
        }
        return state.socks5Proxy
    }
}
