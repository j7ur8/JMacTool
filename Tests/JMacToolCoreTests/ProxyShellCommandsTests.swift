import XCTest
@testable import JMacToolCore

final class ProxyShellCommandsTests: XCTestCase {
    func testCurrentShellCommandsExportAndUnset() {
        var state = ProxyState.empty
        state.httpProxy = "http://a:1"
        state.httpsProxy = "http://a:1"
        state.noProxy = "localhost"

        let exports = ProxyShellCommands.buildZshCurrentShellCommands(state)
        XCTAssertTrue(exports.contains("export http_proxy='http://a:1'"))
        XCTAssertTrue(exports.contains("export HTTPS_PROXY='http://a:1'"))
        XCTAssertTrue(exports.contains("export no_proxy='localhost'"))
        XCTAssertTrue(exports.contains("unset ALL_PROXY"))
        XCTAssertTrue(exports.contains("unset no_proxy") == false)

        let cleared = ProxyShellCommands.buildZshCurrentShellCommands(.empty)
        XCTAssertTrue(cleared.contains("unset http_proxy"))
        XCTAssertTrue(cleared.contains("unset NO_PROXY"))
        XCTAssertFalse(cleared.contains("export"))
    }

    func testShellInitScriptShape() {
        let script = ProxyShellCommands.buildZshShellInitScript(invocationCommand: "'/usr/local/bin/jpmanager'")

        XCTAssertTrue(script.hasPrefix("jpmanager() {"))
        XCTAssertTrue(script.contains("JPMANAGER_ZSH_SHELL_HOOK=1 '/usr/local/bin/jpmanager' \"$@\""))
        XCTAssertTrue(script.contains("eval \"$('/usr/local/bin/jpmanager' shell-apply zsh)\""))
        XCTAssertTrue(script.hasSuffix("}\n"))
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(ProxyShellCommands.shellQuote("it's"), "'it'\\''s'")
    }

    func testCLIInstallerShimShape() throws {
        let content = ProxyCLIInstaller.shimContent(executablePath: "/Applications/JMacTool.app/Contents/MacOS/JMacTool")
        XCTAssertEqual(content, """
        #!/bin/zsh
        exec '/Applications/JMacTool.app/Contents/MacOS/JMacTool' "$@"

        """)
    }
}
