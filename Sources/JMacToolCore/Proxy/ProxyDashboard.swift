import Foundation

/// Dashboard/list data collection and rendering, ported from jpmanager's
/// dashboard module (environment app first, hidden targets excluded).
enum ProxyDashboard {
    struct DashboardMethod: Codable, Equatable, Sendable {
        var type: String
        var label: String
    }

    struct DashboardApp: Codable, Equatable, Sendable {
        var name: String
        var current: ProxyState
        var proxyDisplay: String
        var alias: String
        var matchedProfileName: String?
        var method: DashboardMethod
        var way: String?
        var usedBy: [String]
    }

    struct DashboardProfile: Codable, Equatable, Sendable {
        var name: String
        var http_proxy: String
        var https_proxy: String
        var socks5_proxy: String
        var no_proxy: String
        var proxyDisplay: String

        init(profile: ProxyProfile) {
            name = profile.name
            http_proxy = profile.state.httpProxy
            https_proxy = profile.state.httpsProxy
            socks5_proxy = profile.state.socks5Proxy
            no_proxy = profile.state.noProxy
            proxyDisplay = ProxyDisplay.describe(profile.state)
        }
    }

    struct DashboardData: Codable, Equatable, Sendable {
        var profiles: [DashboardProfile]
        var apps: [DashboardApp]
    }

    /// Dashboard ordering: `environment` first, hidden targets excluded.
    static func dashboardTargets(_ targets: [ProxyTarget]) -> [ProxyTarget] {
        let visible = targets.filter { !$0.definition.dashboardHidden }
        guard let environmentIndex = visible.firstIndex(where: { $0.name == ProxyConstants.environmentAppName }),
              environmentIndex > 0 else {
            return visible
        }

        return [visible[environmentIndex]]
            + visible[visible.startIndex..<environmentIndex]
            + visible[(environmentIndex + 1)...]
    }

    static func findMatchingProxyProfile(
        _ target: ProxyTarget,
        profiles: [StoredProfile],
        currentState: ProxyState
    ) -> StoredProfile? {
        profiles.first { stored in
            ExpectedState.diff(
                for: target.definition,
                actual: currentState,
                expected: target.expectedState(for: stored.state)
            ).isEmpty
        }
    }

    static func aliasLabel(
        _ target: ProxyTarget,
        profiles: [StoredProfile],
        currentState: ProxyState
    ) -> (alias: String, matchedProfileName: String?) {
        if let matched = findMatchingProxyProfile(target, profiles: profiles, currentState: currentState) {
            return (matched.name, matched.name)
        }

        if ExpectedState.hasAnyProxyState(currentState) {
            return ("Custom", nil)
        }
        return ("None", nil)
    }

    static func buildAppEntry(
        _ target: ProxyTarget,
        profiles: [StoredProfile]
    ) -> DashboardApp {
        let current = target.currentState()
        let (alias, matchedName) = aliasLabel(target, profiles: profiles, currentState: current)

        return DashboardApp(
            name: target.name,
            current: ProxyDisplay.normalizeComparableState(current),
            proxyDisplay: ProxyDisplay.describe(current),
            alias: alias,
            matchedProfileName: matchedName,
            method: DashboardMethod(type: "file", label: target.wayLabel),
            way: target.wayLabel,
            usedBy: target.definition.usedBy
        )
    }

    static func collect(context: ProxyFileContext) -> DashboardData {
        let (targets, _) = ProxyTargetLoader.load(context: context)
        let profiles = ProfileStore.ensureStore(context: context)

        let apps = dashboardTargets(targets).map { buildAppEntry($0, profiles: profiles) }
        return DashboardData(
            profiles: profiles.map { DashboardProfile(profile: $0.profile) },
            apps: apps
        )
    }

    static func jsonData(_ data: DashboardData) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(data)) ?? Data("{}".utf8)
    }

    /// Plain-text table for `list`, matching the original column set.
    static func renderListTable(_ apps: [DashboardApp]) -> String {
        let headers = ["Component", "Proxy", "Alias", "Method"]
        let rows: [[String]] = apps.map { [$0.name, $0.proxyDisplay, $0.alias, $0.method.label] }

        var widths = headers.enumerated().map { column, header in
            max(header.count, rows.map { $0[column].count }.max() ?? 0)
        }
        widths[3] = max(widths[3], 18)

        var lines: [String] = []
        lines.append(zip(headers, widths).map { $0.0.padding(toLength: max($0.1, $0.0.count), withPad: " ", startingAt: 0) }.joined(separator: "  "))
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for row in rows {
            let cells = zip(row, widths).map { value, width in
                value.padding(toLength: max(width, value.count), withPad: " ", startingAt: 0)
            }
            lines.append(cells.joined(separator: "  "))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
