import XCTest
@testable import JMacToolCore

final class MavenSettingsTests: XCTestCase {
    let existingSettings = """
    <?xml version="1.0" encoding="UTF-8"?>
    <settings>
      <mirrors>
        <mirror>
          <id>internal</id>
          <url>https://maven.example.com</url>
          <mirrorOf>central</mirrorOf>
        </mirror>
      </mirrors>
      <proxies>
        <proxy>
          <id>legacy</id>
          <active>false</active>
          <protocol>http</protocol>
          <host>old.example.com</host>
          <port>3128</port>
        </proxy>
      </proxies>
    </settings>
    """

    func testUpsertInsertsManagedProxyAndPreservesOthers() throws {
        var state = ProxyState.empty
        state.httpProxy = "http://proxy.example.com:7890"
        state.httpsProxy = "http://proxy.example.com:7890"
        state.noProxy = "localhost,127.0.0.1"

        let output = MavenSettings.upsert(content: existingSettings, state: state)
        let document = try XCTUnwrap(MavenSettings.parseDocument(output))
        let root = try XCTUnwrap(document.rootElement())

        let mirror = try XCTUnwrap(root.elements(forName: "mirrors").first?.elements(forName: "mirror").first)
        XCTAssertEqual(mirror.elements(forName: "id").first?.stringValue, "internal")

        let proxies = try XCTUnwrap(root.elements(forName: "proxies").first)
        let proxyNodes = proxies.elements(forName: "proxy")
        XCTAssertEqual(proxyNodes.count, 2)

        let managed = proxyNodes[0]
        XCTAssertEqual(managed.elements(forName: "id").first?.stringValue, ProxyConstants.mavenManagedProxyID)
        XCTAssertEqual(managed.elements(forName: "host").first?.stringValue, "proxy.example.com")
        XCTAssertEqual(managed.elements(forName: "port").first?.stringValue, "7890")
        XCTAssertEqual(managed.elements(forName: "protocol").first?.stringValue, "http")
        XCTAssertEqual(managed.elements(forName: "nonProxyHosts").first?.stringValue, "localhost|127.0.0.1")
        XCTAssertEqual(proxyNodes[1].elements(forName: "id").first?.stringValue, "legacy")

        let current = MavenSettings.currentState(content: output)
        XCTAssertEqual(current.httpProxy, "http://proxy.example.com:7890")
        XCTAssertEqual(current.httpsProxy, "")
        XCTAssertEqual(current.noProxy, "localhost,127.0.0.1")
    }

    func testUpsertReplacesPreviousManagedProxy() throws {
        var state = ProxyState.empty
        state.httpProxy = "http://first:1"

        let first = MavenSettings.upsert(content: existingSettings, state: state)

        var nextState = ProxyState.empty
        nextState.httpProxy = "http://second:2"
        let second = MavenSettings.upsert(content: first, state: nextState)

        let document = try XCTUnwrap(MavenSettings.parseDocument(second))
        let proxies = try XCTUnwrap(document.rootElement()?.elements(forName: "proxies").first)
        let managedNodes = proxies.elements(forName: "proxy").filter {
            $0.elements(forName: "id").first?.stringValue == ProxyConstants.mavenManagedProxyID
        }
        XCTAssertEqual(managedNodes.count, 1)
        XCTAssertEqual(managedNodes[0].elements(forName: "host").first?.stringValue, "second")
    }

    func testUpsertCreatesFreshSettings() throws {
        var state = ProxyState.empty
        state.httpsProxy = "https://user:pass@proxy.example.com:8443"

        let output = MavenSettings.upsert(content: "", state: state)
        XCTAssertTrue(output.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))

        let current = MavenSettings.currentState(content: output)
        XCTAssertEqual(current.httpsProxy, "https://user:pass@proxy.example.com:8443")
        XCTAssertEqual(current.httpProxy, "")
    }

    func testExpectedStateMatchesWriteBehavior() {
        var state = ProxyState.empty
        state.httpProxy = "http://proxy.example.com:7890"

        let expected = MavenSettings.expectedState(state)
        XCTAssertEqual(expected.httpProxy, "http://proxy.example.com:7890")
        XCTAssertEqual(expected.httpsProxy, "")
    }

    func testClearRemovesOnlyManagedProxy() {
        var state = ProxyState.empty
        state.httpProxy = "http://proxy.example.com:7890"
        let withManaged = MavenSettings.upsert(content: existingSettings, state: state)

        let cleared = MavenSettings.clear(content: withManaged)
        let document = MavenSettings.parseDocument(cleared)
        let proxies = document?.rootElement()?.elements(forName: "proxies").first
        let proxyNodes = proxies?.elements(forName: "proxy") ?? []

        XCTAssertEqual(proxyNodes.count, 1)
        XCTAssertEqual(proxyNodes[0].elements(forName: "id").first?.stringValue, "legacy")
        XCTAssertNotNil(document?.rootElement()?.elements(forName: "mirrors").first)
    }

    func testClearDropsEmptyProxiesContainer() {
        var state = ProxyState.empty
        state.httpProxy = "http://proxy.example.com:7890"
        let fresh = MavenSettings.upsert(content: "", state: state)

        let cleared = MavenSettings.clear(content: fresh)
        XCTAssertNil(MavenSettings.parseDocument(cleared)?.rootElement()?.elements(forName: "proxies").first)
    }
}
