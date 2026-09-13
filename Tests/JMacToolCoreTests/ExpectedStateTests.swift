import XCTest
@testable import JMacToolCore

final class ExpectedStateTests: XCTestCase {
    func testHTTPHTTPSExpectedState() {
        var state = ProxyState.empty
        state.httpProxy = "http://a:1"
        state.httpsProxy = "http://b:2"

        let expected = ExpectedState.httpHttps(state)
        XCTAssertEqual(expected.httpProxy, "http://a:1")
        XCTAssertEqual(expected.httpsProxy, "http://b:2")

        var httpOnly = ProxyState.empty
        httpOnly.httpProxy = "http://a:1"
        XCTAssertEqual(ExpectedState.httpHttps(httpOnly).httpsProxy, "http://a:1")
    }

    func testSingleURLPicksHTTPSOverHTTP() {
        var state = ProxyState.empty
        state.httpProxy = "http://a:1"
        state.httpsProxy = "https://b:2"

        let expected = ExpectedState.singleURL(state)
        XCTAssertEqual(expected.httpProxy, "https://b:2")
        XCTAssertEqual(expected.httpsProxy, "https://b:2")
        XCTAssertEqual(expected.socks5Proxy, "")
    }

    func testSingleURLWithSocksProxyMarksSocksState() {
        var state = ProxyState.empty
        state.socks5Proxy = "socks5://c:3"

        let expected = ExpectedState.singleURL(state)
        XCTAssertEqual(expected.httpProxy, "socks5://c:3")
        XCTAssertEqual(expected.socks5Proxy, "socks5://c:3")
    }

    func testWgetExpectedState() {
        var state = ProxyState.empty
        state.httpProxy = "http://a:1"

        let expected = ExpectedState.wget(state)
        XCTAssertEqual(expected.httpProxy, "http://a:1")
        XCTAssertEqual(expected.httpsProxy, "http://a:1")
    }

    func testGradleExpectedStateRoundTrip() {
        var state = ProxyState.empty
        state.httpProxy = "http://user:pass@proxy.example.com:7890"
        state.noProxy = "localhost,127.0.0.1"

        let expected = ExpectedState.gradle(state)
        XCTAssertEqual(expected.httpProxy, "http://user:pass@proxy.example.com:7890")
        XCTAssertEqual(expected.httpsProxy, "https://user:pass@proxy.example.com:7890")
        XCTAssertEqual(expected.noProxy, "localhost,127.0.0.1")
    }

    func testDiffReportsKeyDifferences() {
        var actual = ProxyState.empty
        actual.httpProxy = "http://a:1"

        var expected = ProxyState.empty
        expected.httpProxy = "http://b:2"

        let diff = ExpectedState.diff(actual: actual, expected: expected)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff[0].key, .httpProxy)
        XCTAssertEqual(diff[0].actual, "http://a:1")
        XCTAssertEqual(diff[0].expected, "http://b:2")
    }

    func testHasAnyProxyState() {
        XCTAssertTrue(ExpectedState.hasAnyProxyState(ProxyState(httpProxy: "http://a:1", httpsProxy: "", socks5Proxy: "", noProxy: "")))
        XCTAssertFalse(ExpectedState.hasAnyProxyState(.empty))
    }

    func testProxyURLParseDefaults() throws {
        let parsed = try XCTUnwrap(ProxyURL.parse("socks5://host"))
        XCTAssertEqual(parsed.protocol, "socks5")
        XCTAssertEqual(parsed.host, "host")
        XCTAssertEqual(parsed.port, "1080")

        let http = try XCTUnwrap(ProxyURL.parse("http://host:7890"))
        XCTAssertEqual(http.port, "7890")
        XCTAssertEqual(http.protocol, "http")

        XCTAssertEqual(ProxyURL.parse(""), nil)
    }
}
