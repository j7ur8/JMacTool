import AppKit
import XCTest
@testable import JMacToolCore

final class ProfileFormWindowTests: XCTestCase {
    private let officeFields = ProfileFormWindow.Fields(
        name: "office",
        httpProxy: "http://127.0.0.1:7890",
        httpsProxy: "https://127.0.0.1:7890",
        socks5Proxy: "socks5://127.0.0.1:7890",
        noProxy: "localhost,127.0.0.1"
    )

    @MainActor
    func testPresentRetargetsTitleAndFields() {
        let window = ProfileFormWindow {}
        defer { window.close() }

        XCTAssertEqual(window.title, "Add Proxy Profile")
        XCTAssertEqual(window.fields.name, "")

        window.present(existing: officeFields, onSave: { _ in })

        XCTAssertEqual(window.title, "Edit Proxy Profile")
        XCTAssertEqual(window.fields.name, "office")
        XCTAssertEqual(window.fields.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(window.fields.httpsProxy, "https://127.0.0.1:7890")
        XCTAssertEqual(window.fields.socks5Proxy, "socks5://127.0.0.1:7890")
        XCTAssertEqual(window.fields.noProxy, "localhost,127.0.0.1")

        // Re-targeting back to "add" must clear the previously edited values.
        window.present(existing: nil, onSave: { _ in })

        XCTAssertEqual(window.title, "Add Proxy Profile")
        XCTAssertEqual(window.fields.name, "")
        XCTAssertEqual(window.fields.httpProxy, "")
        XCTAssertEqual(window.fields.httpsProxy, "")
        XCTAssertEqual(window.fields.socks5Proxy, "")
        XCTAssertEqual(window.fields.noProxy, "")
    }

    @MainActor
    func testCommitUsesMostRecentHandlerAndTrimsValues() {
        let window = ProfileFormWindow {}
        defer { window.close() }

        var added: [ProfileFormWindow.Fields] = []
        var edited: [ProfileFormWindow.Fields] = []

        window.present(existing: nil, onSave: { added.append($0) })
        window.present(existing: officeFields, onSave: { edited.append($0) })

        window.fields.name = "  office-renamed  "
        window.fields.noProxy = "  localhost  "
        window.commit()

        XCTAssertTrue(added.isEmpty, "the stale Add handler must not run after re-targeting")
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited.first?.name, "office-renamed")
        XCTAssertEqual(edited.first?.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(edited.first?.noProxy, "localhost")
    }

    @MainActor
    func testCloseRunsTheCloseHandler() {
        var closeCount = 0
        let window = ProfileFormWindow { closeCount += 1 }
        window.present(existing: nil, onSave: { _ in })

        window.close()

        XCTAssertEqual(closeCount, 1)
    }
}
