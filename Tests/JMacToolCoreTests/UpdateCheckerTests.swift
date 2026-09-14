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
}
