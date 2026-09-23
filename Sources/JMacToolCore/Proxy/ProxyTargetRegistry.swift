import Foundation

/// One managed proxy target (an app whose config file jpmanager/JMacTool
/// edits). Definitions load from the built-in set and merge with user
/// overrides from `~/.jpmanager/targets/*.yaml`.
struct ProxyTargetDefinition: Equatable, Sendable {
    var name: String
    var handler: String
    var wayLabel: String
    var path: String
    var aliases: [String]
    var usedBy: [String]
    var dashboardHidden: Bool
    var expected: String
    var read: MiniYAML.Value?
    var write: MiniYAML.Value?
    var clear: MiniYAML.Value?
    var readMode: String
    var writeMode: String
}

enum ProxyTargetRegistry {
    struct Registry: Sendable {
        var targets: [ProxyTargetDefinition]
        var aliases: [String: String]
    }

    static let handlerNames: Set<String> = [
        "ini-root",
        "ini-section",
        "managed-shell-env",
        "line-kv",
        "yarnrc",
        "maven-settings",
        "condarc-proxy-servers",
        "docker-json",
        "system-proxy"
    ]

    // Built-in definitions embedded verbatim (sorted by file name, matching
    // the original config/targets directory order).
    static let builtinTargetYAMLs: [(fileName: String, content: String)] = [
        ("conda.yaml", """
        version: 1
        target:
          name: conda
          wayLabel: ~/.condarc
          path: ~/.condarc
          handler: condarc-proxy-servers
          expected: conda
        """),
        ("curl.yaml", """
        version: 1
        target:
          name: curl
          wayLabel: ~/.curlrc
          path: ~/.curlrc
          handler: ini-root
          read:
            proxy: proxy
          write:
            proxy: pick_proxy
          clear:
            proxy: ""
          expected: single-url
        """),
        ("environment.yaml", """
        version: 1
        target:
          name: environment
          wayLabel: ~/.zshrc
          path: ~/.zshrc
          handler: managed-shell-env
          aliases:
            - brew
            - gem
            - bundle
            - ruby
          usedBy:
            - brew
            - gem
            - bundle
            - ruby
          expected: zsh
        """),
        ("git.yaml", """
        version: 1
        target:
          name: git
          wayLabel: ~/.gitconfig
          path: ~/.gitconfig
          handler: ini-section
          read:
            http_proxy:
              section: http
              key: proxy
            https_proxy:
              section: https
              key: proxy
          write:
            - section: http
              key: proxy
              value: http_proxy
            - section: https
              key: proxy
              value: https_or_http
          clear:
            - section: http
              key: proxy
              value: ""
            - section: https
              key: proxy
              value: ""
          expected: http-https
        """),
        ("go.yaml", """
        version: 1
        target:
          name: go
          wayLabel: ~/.config/go/env
          path: ~/.config/go/env
          handler: line-kv
          read:
            http_proxy: HTTP_PROXY
            https_proxy: HTTPS_PROXY
            socks5_proxy: ALL_PROXY
            no_proxy: NO_PROXY
          write:
            HTTP_PROXY: http_proxy
            HTTPS_PROXY: https_or_http
            ALL_PROXY: socks5_proxy
            NO_PROXY: no_proxy
          clear:
            HTTP_PROXY: ""
            HTTPS_PROXY: ""
            ALL_PROXY: ""
            NO_PROXY: ""
          expected: go
        """),
        ("gradle.yaml", """
        version: 1
        target:
          name: gradle
          wayLabel: ~/.gradle/gradle.properties
          path: ~/.gradle/gradle.properties
          handler: ini-root
          readMode: gradle
          writeMode: gradle
          expected: gradle
        """),
        ("maven.yaml", """
        version: 1
        target:
          name: maven
          wayLabel: ~/.m2/settings.xml
          path: ~/.m2/settings.xml
          handler: maven-settings
          expected: maven
        """),
        ("npm.yaml", """
        version: 1
        target:
          name: npm
          wayLabel: ~/.npmrc
          path: ~/.npmrc
          handler: ini-root
          read:
            http_proxy: proxy
            https_proxy: https-proxy
          write:
            proxy: http_proxy
            https-proxy: https_or_http
          clear:
            proxy: ""
            https-proxy: ""
          expected: http-https
        """),
        ("orbstack-docker.yaml", """
        version: 1
        target:
          name: orbstack-docker
          wayLabel: ~/.orbstack/config/docker.json
          path: ~/.orbstack/config/docker.json
          handler: docker-json
          expected: orbstack-docker
        """),
        ("pip.yaml", """
        version: 1
        target:
          name: pip
          wayLabel: ~/.config/pip/pip.conf
          path: ~/.config/pip/pip.conf
          handler: ini-section
          read:
            proxy:
              section: global
              key: proxy
          write:
            - section: global
              key: proxy
              value: pick_proxy
          clear:
            - section: global
              key: proxy
              value: ""
          expected: single-url
        """),
        ("system-proxy.yaml", """
        version: 1
        target:
          name: system
          wayLabel: macOS Network Proxies
          handler: system-proxy
          expected: system-proxy
        """),
        ("wget.yaml", """
        version: 1
        target:
          name: wget
          wayLabel: ~/.wgetrc
          path: ~/.wgetrc
          handler: ini-root
          readMode: wget
          write:
            use_proxy: on
            http_proxy: http_or_pick
            https_proxy: https_or_http_or_pick
          clear:
            use_proxy: off
            http_proxy: ""
            https_proxy: ""
          expected: wget
        """),
        ("yarn.yaml", """
        version: 1
        target:
          name: yarn
          wayLabel: ~/.yarnrc
          path: ~/.yarnrc
          handler: yarnrc
          read:
            http_proxy: proxy
            https_proxy: https-proxy
          write:
            proxy: http_proxy
            https-proxy: https_or_http
          clear:
            proxy: ""
            https-proxy: ""
          expected: http-https
        """),
        ("zsh.yaml", """
        version: 1
        target:
          name: zsh
          wayLabel: ~/.zshrc
          path: ~/.zshrc
          handler: managed-shell-env
          dashboardHidden: true
          expected: zsh
        """)
    ]

    // MARK: - Loading

    static func load(context: ProxyFileContext) throws -> Registry {
        var rawByName: [(String, MiniYAML.Value)] = []
        var seenNames = Set<String>()

        for (fileName, content) in builtinTargetYAMLs {
            let document = try parseDocument(content, sourceLabel: "built-in proxy target \(fileName)")
            for raw in targetRawMappings(document, sourceLabel: "built-in proxy target \(fileName)") {
                guard let name = targetName(raw), !name.isEmpty else {
                    throw ProxyEngineError(message: "A target entry in built-in proxy target \(fileName) is missing name.")
                }
                if !seenNames.contains(name) {
                    seenNames.insert(name)
                    rawByName.append((name, raw))
                }
            }
        }

        let userFiles = readUserTargetFiles(context: context)
        for (sourceLabel, content) in userFiles {
            let document = try parseDocument(content, sourceLabel: sourceLabel)
            for raw in targetRawMappings(document, sourceLabel: sourceLabel) {
                guard let name = targetName(raw), !name.isEmpty else {
                    throw ProxyEngineError(message: "A target entry in \(sourceLabel) is missing name.")
                }
                if let index = rawByName.firstIndex(where: { $0.0 == name }) {
                    rawByName[index].1 = mergeRaw(base: rawByName[index].1, override: raw)
                } else {
                    seenNames.insert(name)
                    rawByName.append((name, raw))
                }
            }
        }

        var targets: [ProxyTargetDefinition] = []
        for (name, raw) in rawByName {
            let normalized = try normalizeTarget(raw, name: name)
            targets.append(normalized)
        }

        var aliases: [String: String] = [:]
        for target in targets {
            for alias in target.aliases {
                aliases[alias] = target.name
            }
        }

        return Registry(targets: targets, aliases: aliases)
    }

    static func loadOrDefault(context: ProxyFileContext) -> Registry {
        do {
            return try load(context: context)
        } catch let error as ProxyEngineError {
            FileHandle.standardError.write("\(error.message)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("Failed to load proxy targets: \(error)\n".data(using: .utf8)!)
        }
        return Registry(targets: [], aliases: [:])
    }

    private static func readUserTargetFiles(context: ProxyFileContext) -> [(sourceLabel: String, content: String)] {
        let directory = context.userTargetsDirectory
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let fileNames = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted()

        return fileNames.map { fileName in
            let path = directory + "/" + fileName
            return (sourceLabel: path, content: context.readTextFile(path))
        }
    }

    private static func parseDocument(_ content: String, sourceLabel: String) throws -> MiniYAML.Value {
        do {
            return try MiniYAML.parse(content)
        } catch {
            throw ProxyEngineError(message: "Invalid YAML in \(sourceLabel).")
        }
    }

    private static func targetRawMappings(_ document: MiniYAML.Value, sourceLabel: String) -> [MiniYAML.Value] {
        if let array = document.sequenceValue {
            return array
        }
        if let array = document["targets"]?.sequenceValue {
            return array
        }
        if let single = document["target"] {
            return [single]
        }
        return []
    }

    private static func targetName(_ raw: MiniYAML.Value) -> String? {
        raw.string("name").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Shallow merge of two raw target mappings; override keys win.
    private static func mergeRaw(base: MiniYAML.Value, override: MiniYAML.Value) -> MiniYAML.Value {
        guard let baseEntries = base.mappingValue, let overrideEntries = override.mappingValue else {
            return override
        }

        var merged = baseEntries
        for entry in overrideEntries {
            if let index = merged.firstIndex(where: { $0.key == entry.key }) {
                merged[index] = entry
            } else {
                merged.append(entry)
            }
        }
        return .mapping(merged)
    }

    private static func normalizeTarget(_ raw: MiniYAML.Value, name rawName: String) throws -> ProxyTargetDefinition {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard let handler = raw.string("handler")?.trimmingCharacters(in: .whitespaces), !handler.isEmpty else {
            throw ProxyEngineError(message: "Target \"\(name)\" is missing handler.")
        }
        guard handlerNames.contains(handler) else {
            throw ProxyEngineError(message: "Target \"\(name)\" uses unsupported handler \"\(handler)\".")
        }

        let wayLabel = (raw.string("wayLabel") ?? raw.string("path") ?? "")
        let path = (raw.string("path") ?? raw.string("wayLabel") ?? "")

        return ProxyTargetDefinition(
            name: name,
            handler: handler,
            wayLabel: wayLabel,
            path: path,
            aliases: raw.stringArray("aliases"),
            usedBy: raw.stringArray("usedBy"),
            dashboardHidden: raw.string("dashboardHidden") == "true",
            expected: raw.string("expected") ?? "",
            read: raw["read"],
            write: raw["write"],
            clear: raw["clear"],
            readMode: raw.string("readMode") ?? "",
            writeMode: raw.string("writeMode") ?? ""
        )
    }
}
