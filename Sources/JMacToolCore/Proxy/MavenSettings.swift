import Foundation

/// Maven `~/.m2/settings.xml` proxy management (`maven-settings` handler).
/// The managed proxy node carries the id `jpmanager`; other nodes are
/// preserved. Output is re-serialized with 2-space indentation, matching the
/// original jpmanager output shape.
enum MavenSettings {
    static func parseDocument(_ content: String) -> XMLDocument? {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try? XMLDocument(xmlString: content)
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

    // MARK: - Node helpers

    private static func proxyNodes(in document: XMLDocument?) -> [XMLElement] {
        guard let root = document?.rootElement() else {
            return []
        }
        let proxies = root.elements(forName: "proxies").first
        return (proxies?.elements(forName: "proxy")) ?? []
    }

    private static func childText(_ element: XMLElement, _ name: String) -> String {
        let value = element.elements(forName: name).first?.stringValue ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isManaged(_ element: XMLElement) -> Bool {
        childText(element, "id") == ProxyConstants.mavenManagedProxyID
    }

    private static func isActive(_ element: XMLElement) -> Bool {
        guard let active = element.elements(forName: "active").first else {
            return true
        }
        let value = (active.stringValue ?? "true").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.lowercased() != "false"
    }

    private static func managedNode(in nodes: [XMLElement]) -> XMLElement? {
        nodes.first(where: isManaged)
            ?? nodes.first(where: isActive)
            ?? nodes.first
    }

    private static func buildManagedProxyNode(state: ProxyState) -> XMLElement {
        let parts = ProxyURL.parse(ProxyURL.pick(state))

        let node = XMLElement(name: "proxy")
        node.addChild(XMLElement(name: "id", stringValue: ProxyConstants.mavenManagedProxyID))
        node.addChild(XMLElement(name: "active", stringValue: "true"))
        node.addChild(XMLElement(name: "protocol", stringValue: parts?.protocol ?? ""))
        node.addChild(XMLElement(name: "host", stringValue: parts?.host ?? ""))
        node.addChild(XMLElement(name: "port", stringValue: parts?.port ?? ""))
        node.addChild(XMLElement(name: "nonProxyHosts", stringValue: formatNoProxyHosts(state.noProxy)))

        if let username = parts?.username, !username.isEmpty {
            node.addChild(XMLElement(name: "username", stringValue: username))
        }
        if let password = parts?.password, !password.isEmpty {
            node.addChild(XMLElement(name: "password", stringValue: password))
        }

        return node
    }

    // MARK: - Public API

    static func currentState(content: String) -> ProxyState {
        guard let node = managedNode(in: proxyNodes(in: parseDocument(content))) else {
            return .empty
        }

        let protocolName = childText(node, "protocol")
        let proxyURL = ProxyURL.build(
            protocol: protocolName.isEmpty ? "http" : protocolName,
            host: childText(node, "host"),
            port: childText(node, "port"),
            username: childText(node, "username"),
            password: childText(node, "password")
        )

        var state = ProxyState.empty
        state.httpProxy = protocolName == "http" ? proxyURL : ""
        state.httpsProxy = protocolName == "https" ? proxyURL : ""
        state.socks5Proxy = protocolName.hasPrefix("socks") ? proxyURL : ""
        state.noProxy = parseNoProxyHosts(childText(node, "nonProxyHosts"))
        return state
    }

    @discardableResult
    static func upsert(content: String, state: ProxyState) -> String {
        let document = parseDocument(content) ?? XMLDocument(rootElement: XMLElement(name: "settings"))
        guard let root = document.rootElement() else {
            return content
        }

        let managed = buildManagedProxyNode(state: state)
        let proxiesContainer: XMLElement
        if let proxies = root.elements(forName: "proxies").first {
            proxiesContainer = proxies
            // Remove previously managed nodes, keep unrelated ones.
            for node in proxies.elements(forName: "proxy") where isManaged(node) {
                node.detach()
            }
        } else {
            proxiesContainer = XMLElement(name: "proxies")
            root.addChild(proxiesContainer)
        }

        proxiesContainer.insertChild(managed, at: 0)
        return serialize(document: document)
    }

    static func clear(content: String) -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        guard let root = parseDocument(content)?.rootElement() else {
            // Malformed content degrades to an empty settings document, like the JS parser.
            return serialize(document: XMLDocument(rootElement: XMLElement(name: "settings")))
        }

        if let proxies = root.elements(forName: "proxies").first {
            for node in proxies.elements(forName: "proxy") where isManaged(node) {
                node.detach()
            }
            if proxies.elements(forName: "proxy").isEmpty {
                proxies.detach()
            }
        }

        return serialize(document: XMLDocument(rootElement: root))
    }

    static func expectedState(_ state: ProxyState) -> ProxyState {
        currentState(content: upsert(content: "", state: state))
    }

    // MARK: - Serialization

    private static func serialize(document: XMLDocument) -> String {
        guard let root = document.rootElement() else {
            return ""
        }

        var lines: [String] = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"]
        appendElement(root, indent: "", to: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendElement(_ element: XMLElement, indent: String, to lines: inout [String]) {
        let attributes = element.attributes?
            .compactMap { node -> String? in
                let name = node.name ?? ""
                let value = escapeXML(node.stringValue ?? "")
                return " \(name)=\"\(value)\""
            }
            .joined() ?? ""

        let elementChildren = (element.children ?? []).compactMap { $0 as? XMLElement }
        let ownText = element.stringValue ?? ""
        let hasText = !elementChildren.isEmpty
            ? false
            : !ownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if elementChildren.isEmpty && !hasText {
            lines.append("\(indent)<\(element.name ?? "")\(attributes)/>")
            return
        }

        if elementChildren.isEmpty {
            let text = escapeXML(ownText.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("\(indent)<\(element.name ?? "")\(attributes)>\(text)</\(element.name ?? "")>")
            return
        }

        lines.append("\(indent)<\(element.name ?? "")\(attributes)>")
        for child in elementChildren {
            appendElement(child, indent: indent + "  ", to: &lines)
        }
        lines.append("\(indent)</\(element.name ?? "")>")
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
