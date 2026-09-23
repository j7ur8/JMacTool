import XCTest
@testable import JMacToolCore

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("v1.0.5", than: "1.0.4"))
        XCTAssertTrue(UpdateChecker.isNewerVersion("1.0.10", than: "1.0.9")) // numeric, not lexicographic
        XCTAssertTrue(UpdateChecker.isNewerVersion("1.1", than: "1.0.9"))   // missing components pad to zero
        XCTAssertFalse(UpdateChecker.isNewerVersion("v1.0.5", than: "1.0.5"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.0.4", than: "1.0.5"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("garbage", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.0.5", than: "also garbage"))
    }

    func testNormalizedVersionComponents() {
        XCTAssertEqual(UpdateChecker.normalizedVersionComponents("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(UpdateChecker.normalizedVersionComponents("1.0"), [1, 0])
        XCTAssertNil(UpdateChecker.normalizedVersionComponents("abc"))
        XCTAssertNil(UpdateChecker.normalizedVersionComponents("1.0.x"))
    }

    func testParseLatestReleasePicksMatchingAsset() throws {
        let json = """
        {
          "tag_name": "v1.0.5",
          "assets": [
            {"name": "JMacTool-v1.0.4-macos.zip", "browser_download_url": "https://github.com/j7ur8/JMacTool/releases/download/v1.0.4/JMacTool-v1.0.4-macos.zip"},
            {"name": "JMacTool-v1.0.5-macos.zip", "browser_download_url": "https://github.com/j7ur8/JMacTool/releases/download/v1.0.5/JMacTool-v1.0.5-macos.zip"},
            {"name": "Source code (zip)", "browser_download_url": "https://github.com/j7ur8/JMacTool/zipball"}
          ]
        }
        """
        let info = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))

        XCTAssertEqual(info.tag, "v1.0.5")
        XCTAssertEqual(info.version, "1.0.5")
        XCTAssertEqual(
            info.downloadURL.absoluteString,
            "https://github.com/j7ur8/JMacTool/releases/download/v1.0.5/JMacTool-v1.0.5-macos.zip"
        )
    }

    func testParseLatestReleaseWithoutMatchingAssetReturnsNil() {
        let json = """
        {"tag_name": "v1.0.5", "assets": [{"name": "Source code (zip)", "browser_download_url": "https://x"}]}
        """
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("not json".utf8)))
    }

    @MainActor
    func testInstallerScriptShellQuoting() {
        XCTAssertEqual(AppUpdater.shellQuoted("/Applications/JMacTool.app"), "'/Applications/JMacTool.app'")
        XCTAssertEqual(AppUpdater.shellQuoted("/tmp/it's here"), "'/tmp/it'\\''s here'")
    }

    @MainActor
    func testRequirementCarriesIdentityHash() {
        let hash = "9EA64ACAB59651F742F59721C3AFE0F3DF52FC9B"

        // Hash form, as emitted for self-signed leaves on current macOS.
        let hashForm = """
        Executable=/tmp/x/JMacTool.app/Contents/MacOS/JMacTool
        Identifier=local.codex.JMacTool
        # designated => identifier "local.codex.JMacTool" and certificate leaf = H"\(hash.lowercased())"
        """
        XCTAssertTrue(AppUpdater.requirement(hashForm, carriesIdentityHash: hash))

        // Common-name form, as emitted by older codesign versions.
        let cnForm = "# designated => identifier \"local.codex.JMacTool\" and certificate leaf[subject.CN] = \"JMacTool Local\""
        XCTAssertTrue(AppUpdater.requirement(cnForm, carriesIdentityHash: hash))

        // Ad-hoc signatures (cdhash only) and foreign certificates never match.
        let adhocForm = "# designated => cdhash H\"aa8314d8f7d0eb0d94898187fb44a5ccbc89e24b\" or cdhash H\"8f1b21c68f397ee6be59db1217e22254a738695d\""
        XCTAssertFalse(AppUpdater.requirement(adhocForm, carriesIdentityHash: hash))
        XCTAssertFalse(AppUpdater.requirement(hashForm, carriesIdentityHash: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"))
        XCTAssertFalse(AppUpdater.requirement("", carriesIdentityHash: hash))
    }

    func testShouldBypassProxyForStatus() {
        // Success and redirect statuses describe the request itself; retrying
        // direct would only duplicate them.
        XCTAssertFalse(ProxyAwareSession.shouldBypassProxyForStatus(200))
        XCTAssertFalse(ProxyAwareSession.shouldBypassProxyForStatus(304))

        // Client/server errors received through the proxy path deserve a
        // direct attempt: e.g. GitHub answers 403 to rate-limited proxy exit
        // IPs while a direct connection succeeds.
        XCTAssertTrue(ProxyAwareSession.shouldBypassProxyForStatus(400))
        XCTAssertTrue(ProxyAwareSession.shouldBypassProxyForStatus(403))
        XCTAssertTrue(ProxyAwareSession.shouldBypassProxyForStatus(429))
        XCTAssertTrue(ProxyAwareSession.shouldBypassProxyForStatus(500))
        XCTAssertTrue(ProxyAwareSession.shouldBypassProxyForStatus(599))

        XCTAssertFalse(ProxyAwareSession.shouldBypassProxyForStatus(399))
        XCTAssertFalse(ProxyAwareSession.shouldBypassProxyForStatus(600))
    }
}
