import XCTest
@testable import JMacToolCore

final class IniDocumentTests: XCTestCase {
    func testParsesRootAndSectionKeys() {
        let document = IniDocument.parse("""
        # comment
        proxy = http://127.0.0.1:7890

        [http]
        proxy = http://127.0.0.1:7890

        [https]
            proxy = http://127.0.0.1:7890
        """)

        XCTAssertEqual(document.value(forKey: "proxy"), "http://127.0.0.1:7890")
        XCTAssertEqual(document.value(section: "http", key: "proxy"), "http://127.0.0.1:7890")
        XCTAssertEqual(document.value(section: "https", key: "proxy"), "http://127.0.0.1:7890")
    }

    func testUpsertRootKeysPreservesOtherContent() {
        let content = "registry=https://registry.npmjs.org/\n"
        let next = IniDocument.upsertKeys(
            in: content,
            entries: [("proxy", "http://127.0.0.1:7890"), ("https-proxy", "http://127.0.0.1:7890")],
            removeEmpty: false
        )

        XCTAssertTrue(next.contains("registry = https://registry.npmjs.org/"))
        XCTAssertTrue(next.contains("proxy = http://127.0.0.1:7890"))
        XCTAssertTrue(next.contains("https-proxy = http://127.0.0.1:7890"))
    }

    func testUpsertUpdatesExistingKeyInPlace() {
        let content = "proxy = http://old:1\nhttps-proxy = http://old:1\n"
        let next = IniDocument.upsertKeys(
            in: content,
            entries: [("proxy", "http://new:2")],
            removeEmpty: false
        )

        XCTAssertTrue(next.contains("proxy = http://new:2"))
        XCTAssertTrue(next.contains("https-proxy = http://old:1"))
    }

    func testRemoveEmptyDeletesKeysAndEmptySections() {
        let content = """
        keep = yes

        [http]
        proxy = http://old:1

        [https]
        proxy = http://old:1
        other = value
        """

        var document = IniDocument.parse(content)
        document.set("", forKey: "keep", removeIfEmpty: true)
        document.set("", section: "http", key: "proxy", removeIfEmpty: true)
        document.set("", section: "https", key: "proxy", removeIfEmpty: true)

        let serialized = document.serialize()
        XCTAssertFalse(serialized.contains("keep"))
        XCTAssertFalse(serialized.contains("[http]"))
        XCTAssertTrue(serialized.contains("[https]"))
        XCTAssertTrue(serialized.contains("other = value"))
    }

    func testGitConfigStyleRoundTrip() {
        let content = """
        [user]
        name = someone
        email = someone@example.com

        [http]
        proxy = http://old:1
        """

        let next = IniDocument.upsertSectionKeys(
            in: content,
            section: "http",
            entries: [("proxy", "http://new:8080")],
            removeEmpty: false
        )

        XCTAssertTrue(next.contains("name = someone"))
        XCTAssertTrue(next.contains("[http]"))
        XCTAssertTrue(next.contains("proxy = http://new:8080"))

        let reparsed = IniDocument.parse(next)
        XCTAssertEqual(reparsed.value(section: "http", key: "proxy"), "http://new:8080")
        XCTAssertEqual(reparsed.value(section: "user", key: "email"), "someone@example.com")
    }
}
