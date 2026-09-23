import Foundation

/// Dispatches read/write/clear on a managed target's config file according to
/// its handler, ported from the jpmanager adapter map.
enum TargetAdapter {
    static func currentState(context: ProxyFileContext, target: ProxyTargetDefinition) -> ProxyState {
        switch target.handler {
        case "ini-root":
            let document = IniDocument.parse(context.readTextFile(target.path))
            if target.readMode == "wget" {
                return WgetProxy.currentState(document: document)
            }
            if target.readMode == "gradle" {
                return GradleProxy.currentState(document: document)
            }
            return ProxyExpressions.stateFromRootReadMap(document, readMap: target.read)

        case "ini-section":
            let document = IniDocument.parse(context.readTextFile(target.path))
            return ProxyExpressions.stateFromSectionReadMap(document, readMap: target.read)

        case "managed-shell-env":
            return ShellEnvFile.readEnvironmentProxyState(content: context.readTextFile(target.path))

        case "line-kv":
            let content = context.readTextFile(target.path)
            func read(_ fileKey: String?) -> String {
                guard let fileKey else { return "" }
                return LineFormats.readGoEnvKey(content: content, key: fileKey)
            }
            var state = ProxyState.empty
            state.httpProxy = read(target.read?.string("http_proxy"))
            state.httpsProxy = read(target.read?.string("https_proxy"))
            state.socks5Proxy = read(target.read?.string("socks5_proxy"))
            state.noProxy = read(target.read?.string("no_proxy"))
            return state

        case "yarnrc":
            let content = context.readTextFile(target.path)
            func read(_ fileKey: String?) -> String {
                guard let fileKey else { return "" }
                return LineFormats.readYarnRcKey(content: content, key: fileKey)
            }
            var state = ProxyState.empty
            state.httpProxy = read(target.read?.string("http_proxy"))
            state.httpsProxy = read(target.read?.string("https_proxy"))
            state.socks5Proxy = read(target.read?.string("socks5_proxy"))
            state.noProxy = read(target.read?.string("no_proxy"))
            return state

        case "maven-settings":
            return MavenSettings.currentState(content: context.readTextFile(target.path))

        case "condarc-proxy-servers":
            return CondaConfig.currentState(content: context.readTextFile(target.path))

        case "docker-json":
            return DockerJSONConfig.currentState(content: context.readTextFile(target.path))

        case "system-proxy":
            return SystemProxy.currentState(run: context.runCommand)

        default:
            return .empty
        }
    }

    static func write(context: ProxyFileContext, target: ProxyTargetDefinition, state: ProxyState) throws {
        switch target.handler {
        case "ini-root":
            let entries: [(String, String)]
            if target.writeMode == "gradle" {
                entries = GradleProxy.proxyEntries(state)
            } else {
                entries = ProxyExpressions.buildEntriesFromMap(target.write, state: state)
            }
            let nextContent = IniDocument.upsertKeys(
                in: context.readTextFile(target.path),
                entries: entries,
                removeEmpty: target.writeMode == "gradle"
            )
            context.writeTextFile(target.path, nextContent)

        case "ini-section":
            let nextContent = ProxyExpressions.applyIniSectionEntries(
                content: context.readTextFile(target.path),
                entries: ProxyExpressions.sectionEntries(target.write),
                state: state,
                removeEmpty: false
            )
            context.writeTextFile(target.path, nextContent)

        case "managed-shell-env":
            ShellEnvFile.applyEnvironmentProxyState(context: context, targetPath: target.path, state: state)

        case "line-kv":
            let nextContent = LineFormats.upsertGoEnvKeys(
                content: context.readTextFile(target.path),
                entries: ProxyExpressions.buildEntriesFromMap(target.write, state: state)
            )
            context.writeTextFile(target.path, nextContent)

        case "yarnrc":
            let nextContent = LineFormats.upsertYarnRcKeys(
                content: context.readTextFile(target.path),
                entries: ProxyExpressions.buildEntriesFromMap(target.write, state: state)
            )
            context.writeTextFile(target.path, nextContent)

        case "maven-settings":
            context.writeTextFile(target.path, MavenSettings.upsert(content: context.readTextFile(target.path), state: state))

        case "condarc-proxy-servers":
            context.writeTextFile(target.path, CondaConfig.upsert(content: context.readTextFile(target.path), state: state))

        case "docker-json":
            context.writeTextFile(target.path, DockerJSONConfig.upsert(content: context.readTextFile(target.path), state: state))

        case "system-proxy":
            try SystemProxy.apply(state, run: context.runCommand)

        default:
            break
        }
    }

    static func clear(context: ProxyFileContext, target: ProxyTargetDefinition) throws {
        let empty = ProxyState.empty

        switch target.handler {
        case "ini-root":
            let entries: [(String, String)]
            if target.writeMode == "gradle" {
                entries = GradleProxy.proxyEntries(empty)
            } else {
                entries = ProxyExpressions.buildEntriesFromMap(target.clear, state: empty)
            }
            let nextContent = IniDocument.upsertKeys(
                in: context.readTextFile(target.path),
                entries: entries,
                removeEmpty: true
            )
            context.syncTextFile(target.path, nextContent)

        case "ini-section":
            let nextContent = ProxyExpressions.applyIniSectionEntries(
                content: context.readTextFile(target.path),
                entries: ProxyExpressions.sectionEntries(target.clear),
                state: empty,
                removeEmpty: true
            )
            context.syncTextFile(target.path, nextContent)

        case "managed-shell-env":
            ShellEnvFile.clearEnvironmentProxyState(context: context, targetPath: target.path)

        case "line-kv":
            let nextContent = LineFormats.upsertGoEnvKeys(
                content: context.readTextFile(target.path),
                entries: ProxyExpressions.buildEntriesFromMap(target.clear, state: empty)
            )
            context.syncTextFile(target.path, nextContent)

        case "yarnrc":
            let nextContent = LineFormats.upsertYarnRcKeys(
                content: context.readTextFile(target.path),
                entries: ProxyExpressions.buildEntriesFromMap(target.clear, state: empty)
            )
            context.syncTextFile(target.path, nextContent)

        case "maven-settings":
            if context.fileExists(target.path) {
                context.writeTextFile(target.path, MavenSettings.clear(content: context.readTextFile(target.path)))
            }

        case "condarc-proxy-servers":
            let nextContent = CondaConfig.upsert(content: context.readTextFile(target.path), state: empty)
            context.syncTextFile(target.path, nextContent)

        case "docker-json":
            guard context.fileExists(target.path) else {
                return
            }
            let nextContent = DockerJSONConfig.upsert(content: context.readTextFile(target.path), state: empty)
            context.syncTextFile(target.path, nextContent)

        case "system-proxy":
            try SystemProxy.clear(run: context.runCommand)

        default:
            break
        }
    }
}

/// A target plus the runtime helpers the CLI/dashboard need, mirroring
/// jpmanager's runtime target registry.
struct ProxyTarget: Sendable {
    var definition: ProxyTargetDefinition
    var context: ProxyFileContext

    var name: String { definition.name }
    var wayLabel: String { definition.wayLabel.isEmpty ? definition.path : definition.wayLabel }

    func expectedState(for state: ProxyState) -> ProxyState {
        ExpectedState.build(for: definition, state: state)
    }

    func currentState() -> ProxyState {
        TargetAdapter.currentState(context: context, target: definition)
    }

    func apply(_ state: ProxyState) throws {
        try TargetAdapter.write(context: context, target: definition, state: state)
    }

    func clear() throws {
        try TargetAdapter.clear(context: context, target: definition)
    }
}

enum ProxyTargetLoader {
    static func load(context: ProxyFileContext) -> (targets: [ProxyTarget], aliases: [String: String]) {
        let registry = ProxyTargetRegistry.loadOrDefault(context: context)
        let targets = registry.targets.map { ProxyTarget(definition: $0, context: context) }
        return (targets, registry.aliases)
    }
}
