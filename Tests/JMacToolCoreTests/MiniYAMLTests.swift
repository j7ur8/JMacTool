import XCTest
@testable import JMacToolCore

final class MiniYAMLTests: XCTestCase {
    func testParsesTargetDefinitionShape() throws {
        let content = """
        version: 1
        target:
          name: npm
          wayLabel: ~/.npmrc
          dashboardHidden: true
          aliases:
            - brew
            - gem
          read:
            proxy: proxy
            https_proxy:
              section: http
              key: proxy
          write:
            - section: http
              key: proxy
              value: http_proxy
            - section: https
              key: proxy
              value: https_or_http
        """

        let document = try MiniYAML.parse(content)

        XCTAssertEqual(document.string("version"), "1")
        let target = try XCTUnwrap(document["target"])
        XCTAssertEqual(target.string("name"), "npm")
        XCTAssertEqual(target.string("dashboardHidden"), "true")
        XCTAssertEqual(target.stringArray("aliases"), ["brew", "gem"])
        XCTAssertEqual(target["read"]?.string("proxy"), "proxy")
        XCTAssertEqual(target["read"]?["https_proxy"]?.string("section"), "http")

        let writeEntries = try XCTUnwrap(target["write"]?.sequenceValue)
        XCTAssertEqual(writeEntries.count, 2)
        XCTAssertEqual(writeEntries[0].string("section"), "http")
        XCTAssertEqual(writeEntries[1].string("value"), "https_or_http")
    }

    func testParsesQuotedAndCommentedScalars() throws {
        let content = """
        plain: value
        quoted: "http://host:7890 # not comment"
        single: 'it''s'
        empty: ""
        trailing: value # note
        hashInURL: http://host:8080#frag
        """

        let document = try MiniYAML.parse(content)

        XCTAssertEqual(document.string("plain"), "value")
        XCTAssertEqual(document.string("quoted"), "http://host:7890 # not comment")
        XCTAssertEqual(document.string("single"), "it's")
        XCTAssertEqual(document.string("empty"), "")
        XCTAssertEqual(document.string("trailing"), "value")
        XCTAssertEqual(document.string("hashInURL"), "http://host:8080#frag")
    }

    func testEmptyValueBecomesEmptyScalar() throws {
        let document = try MiniYAML.parse("key:")
        XCTAssertEqual(document.string("key"), "")
    }

    func testEmitAndRoundTripProfileLikeDocument() throws {
        let document = MiniYAML.Value.mapping([
            .init(key: "version", value: .scalar("1")),
            .init(key: "profile", value: .mapping([
                .init(key: "name", value: .scalar("office")),
                .init(key: "http_proxy", value: .scalar("http://127.0.0.1:7890")),
                .init(key: "socks5_proxy", value: .scalar("")),
                .init(key: "no_proxy", value: .scalar("localhost,127.0.0.1"))
            ]))
        ])

        let emitted = MiniYAML.emit(document)
        XCTAssertEqual(emitted, """
        version: "1"
        profile:
          name: office
          http_proxy: http://127.0.0.1:7890
          socks5_proxy: ""
          no_proxy: localhost,127.0.0.1
        """ + "\n")

        let reparsed = try MiniYAML.parse(emitted)
        XCTAssertEqual(reparsed, document)
    }

    func testQuotesReservedAndNumericScalars() {
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded(""), "\"\"")
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded("true"), "\"true\"")
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded("on"), "\"on\"")
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded("42"), "\"42\"")
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded("a: b"), "\"a: b\"")
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded("http://x:1", quoteNumbers: false), "http://x:1")
        XCTAssertEqual(MiniYAML.quoteScalarIfNeeded("- item"), "\"- item\"")
    }
}
