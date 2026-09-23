import XCTest
@testable import JMacToolCore

final class DockerJSONConfigTests: XCTestCase {
    private func dictionary(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testUpsertCreatesProxiesSectionFromEmptyContent() throws {
        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"

        let output = DockerJSONConfig.upsert(content: "", state: state)

        XCTAssertEqual(try dictionary(output) as NSDictionary, [
            "proxies": [
                "http-proxy": "http://127.0.0.1:7890",
                // https-proxy falls back to http-proxy.
                "https-proxy": "http://127.0.0.1:7890"
            ]
        ])
        XCTAssertTrue(output.hasSuffix("\n"))
    }

    func testUpsertPreservesOtherKeysAndReplacesExistingValues() throws {
        // Mirrors OrbStack's own rewrite style, including escaped slashes.
        let content = """
        {
          "cpu" : 4,
          "proxies" : {
            "http-proxy" : "http:\\/\\/old:1",
            "https-proxy" : "http:\\/\\/old:1",
            "no-proxy" : "localhost"
          }
        }
        """

        var state = ProxyState.empty
        state.httpProxy = "http://new:2"
        state.httpsProxy = "http://new:2"

        let output = DockerJSONConfig.upsert(content: content, state: state)
        let document = try dictionary(output)
        XCTAssertEqual(document["cpu"] as? Int, 4)
        XCTAssertEqual(document["proxies"] as? [String: String], [
            "http-proxy": "http://new:2",
            "https-proxy": "http://new:2"
        ])
    }

    func testUpsertPassesThroughNoProxyOnlyWhenPresent() throws {
        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"
        state.noProxy = "localhost,127.0.0.1"

        let withNoProxy = try dictionary(DockerJSONConfig.upsert(content: "", state: state))
        XCTAssertEqual((withNoProxy["proxies"] as? [String: String])?["no-proxy"], "localhost,127.0.0.1")

        state.noProxy = ""
        let withoutNoProxy = try dictionary(DockerJSONConfig.upsert(content: "", state: state))
        XCTAssertNil((withoutNoProxy["proxies"] as? [String: String])?["no-proxy"])
    }

    func testUpsertWithEmptyStateRemovesProxiesSection() throws {
        let content = """
        {
          "builder" : true,
          "proxies" : {
            "http-proxy" : "http://old:1"
          }
        }
        """

        let output = DockerJSONConfig.upsert(content: content, state: .empty)
        XCTAssertEqual(try dictionary(output) as NSDictionary, ["builder": true])
    }

    func testUpsertOnEmptyDocumentProducesEmptyObject() {
        XCTAssertEqual(DockerJSONConfig.upsert(content: "", state: .empty), "{}\n")
    }

    func testUpsertRebuildsDocumentWhenFileIsMalformed() throws {
        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"
        state.httpsProxy = "http://127.0.0.1:7890"

        let output = DockerJSONConfig.upsert(content: "not json {", state: state)
        XCTAssertEqual(try dictionary(output) as NSDictionary, [
            "proxies": [
                "http-proxy": "http://127.0.0.1:7890",
                "https-proxy": "http://127.0.0.1:7890"
            ]
        ])
    }

    func testCurrentStateReadsEscapedSlashConfig() {
        // OrbStack writes forward slashes escaped (http:\/\/...).
        let content = #"{"proxies":{"http-proxy":"http:\/\/127.0.0.1:7890","https-proxy":"http:\/\/127.0.0.1:7890","no-proxy":"localhost"}}"#

        let state = DockerJSONConfig.currentState(content: content)
        XCTAssertEqual(state.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(state.httpsProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(state.noProxy, "localhost")
        // Docker daemon.json has no socks5 representation.
        XCTAssertEqual(state.socks5Proxy, "")
    }

    func testCurrentStateOfMissingOrNonObjectContentIsEmpty() {
        XCTAssertEqual(DockerJSONConfig.currentState(content: ""), .empty)
        XCTAssertEqual(DockerJSONConfig.currentState(content: "   \n"), .empty)
        XCTAssertEqual(DockerJSONConfig.currentState(content: "not json"), .empty)
        XCTAssertEqual(DockerJSONConfig.currentState(content: "[]"), .empty)
    }

    func testExpectedStateRoundTripsThroughUpsert() {
        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"
        state.httpsProxy = "http://127.0.0.1:7890"
        state.noProxy = "localhost"
        state.socks5Proxy = "socks5://127.0.0.1:1080"

        let written = DockerJSONConfig.upsert(content: "", state: state)
        let current = DockerJSONConfig.currentState(content: written)

        XCTAssertEqual(current.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(current.httpsProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(current.noProxy, "localhost")
        XCTAssertEqual(current.socks5Proxy, "")

        XCTAssertEqual(DockerJSONConfig.expectedState(state), current)
    }
}
