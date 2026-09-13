import XCTest
@testable import JMacToolCore

final class LineFormatsTests: XCTestCase {
    func testGoEnvReadAndUpsert() {
        let content = """
        # go env config
        GO111MODULE=on
        HTTP_PROXY=http://old:1
        GOPROXY=https://proxy.golang.org
        """

        XCTAssertEqual(LineFormats.readGoEnvKey(content: content, key: "HTTP_PROXY"), "http://old:1")
        XCTAssertEqual(LineFormats.readGoEnvKey(content: content, key: "GOPROXY"), "https://proxy.golang.org")
        XCTAssertEqual(LineFormats.readGoEnvKey(content: content, key: "NO_PROXY"), "")

        let next = LineFormats.upsertGoEnvKeys(content: content, entries: [
            ("HTTP_PROXY", "http://new:8080"),
            ("HTTPS_PROXY", "http://new:8080"),
            ("NO_PROXY", "")
        ])

        XCTAssertTrue(next.contains("GO111MODULE=on"))
        XCTAssertTrue(next.contains("GOPROXY=https://proxy.golang.org"))
        XCTAssertTrue(next.contains("HTTP_PROXY=http://new:8080"))
        XCTAssertTrue(next.contains("HTTPS_PROXY=http://new:8080"))
        XCTAssertFalse(next.contains("http://old:1"))
        XCTAssertFalse(next.contains("NO_PROXY"))
    }

    func testGoEnvQuotesValuesWithWhitespace() {
        let next = LineFormats.upsertGoEnvKeys(content: "", entries: [("NO_PROXY", "localhost, .foo.com")])
        XCTAssertEqual(next, "NO_PROXY=\"localhost, .foo.com\"\n")
    }

    func testYarnRcReadAndUpsert() {
        let content = """
        registry "https://registry.yarnpkg.com"
        proxy "http://old:1"
        lastUpdateCheck 1234
        """

        XCTAssertEqual(LineFormats.readYarnRcKey(content: content, key: "proxy"), "http://old:1")

        let next = LineFormats.upsertYarnRcKeys(content: content, entries: [
            ("proxy", "http://new:8080"),
            ("https-proxy", "http://new:8080")
        ])

        XCTAssertTrue(next.contains("registry \"https://registry.yarnpkg.com\""))
        XCTAssertTrue(next.contains("lastUpdateCheck 1234"))
        XCTAssertTrue(next.contains("proxy \"http://new:8080\""))
        XCTAssertTrue(next.contains("https-proxy \"http://new:8080\""))
    }

    func testStripMatchingQuotes() {
        XCTAssertEqual(LineFormats.stripMatchingQuotes("\"value\""), "value")
        XCTAssertEqual(LineFormats.stripMatchingQuotes("'value'"), "value")
        XCTAssertEqual(LineFormats.stripMatchingQuotes("value"), "value")
        XCTAssertEqual(LineFormats.stripMatchingQuotes("say \"hi\""), "say \"hi\"")
    }

    func testUpsertEmptyEntriesTrimsTrailingLines() {
        let next = LineFormats.upsertGoEnvKeys(content: "A=1\n\n\n", entries: [] )
        XCTAssertEqual(next, "A=1\n")
    }
}
