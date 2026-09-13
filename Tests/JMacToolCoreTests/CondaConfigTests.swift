import XCTest
@testable import JMacToolCore

final class CondaConfigTests: XCTestCase {
    func testUpsertAppendsProxySectionAndPreservesRest() {
        let content = """
        channels:
          - defaults
        ssl_verify: true

        """

        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"
        state.httpsProxy = "http://127.0.0.1:7890"
        state.socks5Proxy = "socks5://127.0.0.1:1080"

        let output = CondaConfig.upsert(content: content, state: state)

        XCTAssertEqual(output, """
        channels:
          - defaults
        ssl_verify: true

        proxy_servers:
          http: "http://127.0.0.1:7890"
          https: "http://127.0.0.1:7890"
          socks5: "socks5://127.0.0.1:1080"
        """ + "\n")
    }

    func testUpsertReplacesExistingProxySection() {
        let content = """
        ssl_verify: true
        proxy_servers:
          http: "http://old:1"
          https: "http://old:1"
        channel_priority: strict
        """

        var state = ProxyState.empty
        state.httpProxy = "http://new:2"
        state.httpsProxy = "http://new:2"

        let output = CondaConfig.upsert(content: content, state: state)

        XCTAssertEqual(output, """
        ssl_verify: true
        channel_priority: strict

        proxy_servers:
          http: "http://new:2"
          https: "http://new:2"
        """ + "\n")
    }

    func testUpsertWithEmptyStateRemovesSection() {
        let content = """
        proxy_servers:
          http: "http://old:1"
        other: value
        """

        let output = CondaConfig.upsert(content: content, state: .empty)
        XCTAssertEqual(output, "other: value\n")
    }

    func testReadStateAndExpectedState() {
        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"
        state.httpsProxy = "http://127.0.0.1:7890"
        state.noProxy = "localhost"

        let written = CondaConfig.upsert(content: "", state: state)
        let current = CondaConfig.currentState(content: written)

        XCTAssertEqual(current.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(current.httpsProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(current.socks5Proxy, "")
        // conda has no no_proxy representation.
        XCTAssertEqual(current.noProxy, "")

        XCTAssertEqual(CondaConfig.expectedState(state), current)
    }

    func testParseScalarStripsCommentsAndQuotes() {
        XCTAssertEqual(CondaConfig.parseCondaScalar("http://a:1 # inline"), "http://a:1")
        XCTAssertEqual(CondaConfig.parseCondaScalar("\"http://a:1\""), "http://a:1")
        XCTAssertEqual(CondaConfig.parseCondaScalar(""), "")
    }
}
