import Foundation

/// Builds the state a target should carry for a given profile (`expected`
/// mode) and diffs it against the current state.
enum ExpectedState {
    static func hasAnyProxyState(_ state: ProxyState) -> Bool {
        ProxyStateKey.allCases.contains { key in
            !ProxyDisplay.normalizeComparableState(state)[key].isEmpty
        }
    }

    static func diff(actual: ProxyState, expected: ProxyState) -> [(key: ProxyStateKey, actual: String, expected: String)] {
        let normalizedActual = ProxyDisplay.normalizeComparableState(actual)
        let normalizedExpected = ProxyDisplay.normalizeComparableState(expected)

        return ProxyStateKey.allCases
            .filter { normalizedActual[$0] != normalizedExpected[$0] }
            .map { ($0, normalizedActual[$0], normalizedExpected[$0]) }
    }

    static func build(for target: ProxyTargetDefinition, state: ProxyState) -> ProxyState {
        switch target.expected {
        case "single-url":
            return singleURL(state)
        case "wget":
            return wget(state)
        case "zsh":
            return zsh(state)
        case "maven":
            return MavenSettings.expectedState(state)
        case "gradle":
            return gradle(state)
        case "conda":
            return CondaConfig.expectedState(state)
        case "go":
            return go(state)
        case "system-proxy":
            return SystemProxy.expectedState(state)
        default:
            return httpHttps(state)
        }
    }

    static func httpHttps(_ state: ProxyState) -> ProxyState {
        var expected = ProxyState.empty
        expected.httpProxy = state.httpProxy
        expected.httpsProxy = state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy
        return expected
    }

    static func singleURL(_ state: ProxyState) -> ProxyState {
        let proxyURL = ProxyURL.pick(state)
        var expected = ProxyState.empty
        expected.httpProxy = proxyURL
        expected.httpsProxy = proxyURL
        expected.socks5Proxy = proxyURL.hasPrefix("socks5") ? proxyURL : ""
        return expected
    }

    static func wget(_ state: ProxyState) -> ProxyState {
        let proxyURL = ProxyURL.pick(state)
        var expected = ProxyState.empty
        expected.httpProxy = state.httpProxy.isEmpty ? proxyURL : state.httpProxy
        expected.httpsProxy = state.httpsProxy.isEmpty
            ? (state.httpProxy.isEmpty ? proxyURL : state.httpProxy)
            : state.httpsProxy
        return expected
    }

    static func zsh(_ state: ProxyState) -> ProxyState {
        var expected = ProxyState.empty
        expected.httpProxy = state.httpProxy
        expected.httpsProxy = state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy
        expected.socks5Proxy = state.socks5Proxy
        expected.noProxy = state.noProxy
        return expected
    }

    static func go(_ state: ProxyState) -> ProxyState {
        zsh(state)
    }

    static func gradle(_ state: ProxyState) -> ProxyState {
        let entries = GradleProxy.proxyEntries(state)
        let content = IniDocument.upsertKeys(in: "", entries: entries, removeEmpty: true)
        return GradleProxy.currentState(document: IniDocument.parse(content))
    }
}

/// Gradle `gradle.properties` systemProp mapping (`ini-root` + gradle modes).
enum GradleProxy {
    static func currentState(document: IniDocument) -> ProxyState {
        func read(_ key: String) -> String {
            document.value(forKey: key) ?? ""
        }

        let httpHost = read("systemProp.http.proxyHost")
        let httpPort = read("systemProp.http.proxyPort").isEmpty ? "80" : read("systemProp.http.proxyPort")
        let httpUser = read("systemProp.http.proxyUser")
        let httpPassword = read("systemProp.http.proxyPassword")
        let httpsHost = read("systemProp.https.proxyHost")
        let httpsPort = read("systemProp.https.proxyPort").isEmpty ? "443" : read("systemProp.https.proxyPort")
        let httpsUser = read("systemProp.https.proxyUser")
        let httpsPassword = read("systemProp.https.proxyPassword")
        let socksHost = read("systemProp.socksProxyHost")
        let socksPort = read("systemProp.socksProxyPort").isEmpty ? "1080" : read("systemProp.socksProxyPort")
        let socksUser = read("systemProp.java.net.socks.username").isEmpty
            ? read("systemProp.socksProxyUser")
            : read("systemProp.java.net.socks.username")
        let socksPassword = read("systemProp.java.net.socks.password").isEmpty
            ? read("systemProp.socksProxyPassword")
            : read("systemProp.java.net.socks.password")
        let nonProxyHosts = read("systemProp.http.nonProxyHosts").isEmpty
            ? read("systemProp.https.nonProxyHosts")
            : read("systemProp.http.nonProxyHosts")

        var state = ProxyState.empty
        state.httpProxy = httpHost.isEmpty
            ? ""
            : ProxyURL.build(protocol: "http", host: httpHost, port: httpPort, username: httpUser, password: httpPassword)
        state.httpsProxy = httpsHost.isEmpty
            ? ""
            : ProxyURL.build(protocol: "https", host: httpsHost, port: httpsPort, username: httpsUser, password: httpsPassword)
        state.socks5Proxy = socksHost.isEmpty
            ? ""
            : ProxyURL.build(protocol: "socks5", host: socksHost, port: socksPort, username: socksUser, password: socksPassword)
        state.noProxy = parseNoProxyHosts(nonProxyHosts)
        return state
    }

    static func proxyEntries(_ state: ProxyState) -> [(String, String)] {
        let httpProxy = ProxyURL.parse(state.httpProxy)
        let httpsProxy = ProxyURL.parse(state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy)
        let socksProxy = ProxyURL.parse(state.socks5Proxy)
        let nonProxyHosts = formatNoProxyHosts(state.noProxy)

        return [
            ("systemProp.http.proxyHost", httpProxy?.host ?? ""),
            ("systemProp.http.proxyPort", httpProxy?.port ?? ""),
            ("systemProp.http.proxyUser", httpProxy?.username ?? ""),
            ("systemProp.http.proxyPassword", httpProxy?.password ?? ""),
            ("systemProp.https.proxyHost", httpsProxy?.host ?? ""),
            ("systemProp.https.proxyPort", httpsProxy?.port ?? ""),
            ("systemProp.https.proxyUser", httpsProxy?.username ?? ""),
            ("systemProp.https.proxyPassword", httpsProxy?.password ?? ""),
            ("systemProp.socksProxyHost", socksProxy?.host ?? ""),
            ("systemProp.socksProxyPort", socksProxy?.port ?? ""),
            ("systemProp.java.net.socks.username", socksProxy?.username ?? ""),
            ("systemProp.java.net.socks.password", socksProxy?.password ?? ""),
            ("systemProp.http.nonProxyHosts", nonProxyHosts),
            ("systemProp.https.nonProxyHosts", nonProxyHosts)
        ]
    }

    static func formatNoProxyHosts(_ noProxy: String) -> String {
        noProxy
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    static func parseNoProxyHosts(_ nonProxyHosts: String) -> String {
        nonProxyHosts
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }
}

/// Wget `~/.wgetrc` current-state reading (`ini-root` + wget mode).
enum WgetProxy {
    static func currentState(document: IniDocument) -> ProxyState {
        let useProxy = (document.value(forKey: "use_proxy") ?? "").lowercased()

        var state = ProxyState.empty
        if useProxy == "off" {
            return state
        }

        state.httpProxy = document.value(forKey: "http_proxy") ?? ""
        state.httpsProxy = document.value(forKey: "https_proxy") ?? ""
        state.socks5Proxy = ""
        return state
    }
}
