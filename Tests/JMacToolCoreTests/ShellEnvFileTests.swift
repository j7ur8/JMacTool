import XCTest
@testable import JMacToolCore

final class ShellEnvFileTests: XCTestCase {
    func testUpsertCreatesManagedBlock() {
        let next = ShellEnvFile.upsertManagedShellExports(content: "export EDITOR=vim\n", entries: [
            ("http_proxy", "http://127.0.0.1:7890"),
            ("https_proxy", "http://127.0.0.1:7890"),
            ("HTTP_PROXY", "http://127.0.0.1:7890"),
            ("HTTPS_PROXY", "http://127.0.0.1:7890"),
            ("ALL_PROXY", ""),
            ("all_proxy", ""),
            ("no_proxy", "localhost"),
            ("NO_PROXY", "localhost")
        ])

        XCTAssertTrue(next.hasPrefix("export EDITOR=vim\n\n"))
        XCTAssertTrue(next.contains(ProxyConstants.zshManagedBlockStart))
        XCTAssertTrue(next.contains("export http_proxy=\"http://127.0.0.1:7890\""))
        XCTAssertTrue(next.contains("export no_proxy=\"localhost\""))
        XCTAssertFalse(next.contains("ALL_PROXY"))
        XCTAssertTrue(next.hasSuffix(ProxyConstants.zshManagedBlockEnd + "\n"))
    }

    func testUpsertReplacesExistingBlockInPlace() {
        let initial = ShellEnvFile.upsertManagedShellExports(content: "alias ll='ls -la'\n", entries: [
            ("http_proxy", "http://old:1")
        ])

        let next = ShellEnvFile.upsertManagedShellExports(content: initial, entries: [
            ("http_proxy", "http://new:2")
        ])

        XCTAssertEqual(next, """
        alias ll='ls -la'

        \(ProxyConstants.zshManagedBlockStart)
        export http_proxy="http://new:2"
        \(ProxyConstants.zshManagedBlockEnd)
        """ + "\n")
    }

    func testUpsertWithEmptyEntriesRemovesBlock() {
        let initial = ShellEnvFile.upsertManagedShellExports(content: "export EDITOR=vim\n", entries: [
            ("http_proxy", "http://old:1")
        ])

        let next = ShellEnvFile.upsertManagedShellExports(content: initial, entries: [])
        XCTAssertEqual(next, "export EDITOR=vim\n")
    }

    func testEscapesQuotesInValues() {
        let next = ShellEnvFile.upsertManagedShellExports(content: "", entries: [
            ("no_proxy", "he said \"hi\"")
        ])
        XCTAssertTrue(next.contains("export no_proxy=\"he said \\\"hi\\\"\""))
    }

    func testReadEnvironmentProxyStatePrefersManagedBlock() {
        let content = """
        export http_proxy=http://stray:9
        \(ProxyConstants.zshManagedBlockStart)
        export http_proxy="http://managed:1"
        export https_proxy="http://managed:1"
        export ALL_PROXY="socks5://managed:2"
        export no_proxy="localhost"
        \(ProxyConstants.zshManagedBlockEnd)
        """

        let state = ShellEnvFile.readEnvironmentProxyState(content: content)
        XCTAssertEqual(state.httpProxy, "http://managed:1")
        XCTAssertEqual(state.httpsProxy, "http://managed:1")
        XCTAssertEqual(state.socks5Proxy, "socks5://managed:2")
        XCTAssertEqual(state.noProxy, "localhost")
    }

    func testReadEnvironmentProxyStateFallsBackToStrayExports() {
        let content = "export HTTP_PROXY=http://stray:9\n"
        let state = ShellEnvFile.readEnvironmentProxyState(content: content)
        XCTAssertEqual(state.httpProxy, "http://stray:9")
    }

    func testClearRemovesBlockAndStrayExports() {
        let content = """
        export EDITOR=vim
        export http_proxy=http://stray:9

        \(ProxyConstants.zshManagedBlockStart)
        export http_proxy="http://managed:1"
        \(ProxyConstants.zshManagedBlockEnd)
        """

        let cleared = clearEnvironmentProxyStateContent(content)
        XCTAssertEqual(cleared, "export EDITOR=vim\n")
    }

    func testRemoveShellExportsHandlesKeyList() {
        let content = "export EDITOR=vim\nexport no_proxy=localhost\nexport NO_PROXY=localhost\n"
        let next = ShellEnvFile.removeShellExports(content: content, keys: ShellEnvFile.shellProxyKeys)
        XCTAssertEqual(next, "export EDITOR=vim\n")
    }
}

private extension ShellEnvFileTests {
    func clearEnvironmentProxyStateContent(_ content: String) -> String {
        ShellEnvFile.removeShellExports(
            content: ShellEnvFile.upsertManagedShellExports(content: content, entries: []),
            keys: ShellEnvFile.shellProxyKeys
        )
    }
}
