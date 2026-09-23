import XCTest
@testable import JMacToolCore

final class ProxyOperationsTests: XCTestCase {
    private var homeDirectory: String!
    private var context: ProxyFileContext!

    override func setUpWithError() throws {
        homeDirectory = NSTemporaryDirectory() + "JMacToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
        // Keep the dashboard's system-target read (scutil) out of tests.
        context = ProxyFileContext(homeDirectory: homeDirectory, runCommand: { _, _ in nil })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: homeDirectory)
    }

    private func saveOfficeProfile() throws {
        var profile = ProxyProfile(name: "office", state: .empty)
        profile.state.httpProxy = "http://127.0.0.1:7890"
        profile.state.httpsProxy = "http://127.0.0.1:7890"
        profile.state.noProxy = "localhost,127.0.0.1"
        _ = try ProfileStore.saveProxyProfile(profile, context: context)
    }

    func testSetAndTestNPM() throws {
        try saveOfficeProfile()

        let result = try ProxyOperations.configureAppWithProfile(context: context, appName: "npm", profileName: "office")
        XCTAssertEqual(result.selection.canonicalName, "npm")

        let npmrc = try String(contentsOfFile: homeDirectory + "/.npmrc", encoding: .utf8)
        XCTAssertTrue(npmrc.contains("proxy = http://127.0.0.1:7890"))
        XCTAssertTrue(npmrc.contains("https-proxy = http://127.0.0.1:7890"))

        let test = try ProxyOperations.testAppProfile(context: context, appName: "npm", profileName: "office")
        XCTAssertTrue(test.mismatches.isEmpty)
    }

    func testSetAndTestGitWithAliasResolution() throws {
        try saveOfficeProfile()

        // brew aliases to the environment target backed by ~/.zshrc.
        let result = try ProxyOperations.configureAppWithProfile(context: context, appName: "brew", profileName: "office")
        XCTAssertEqual(result.selection.canonicalName, "environment")

        let zshrc = try String(contentsOfFile: homeDirectory + "/.zshrc", encoding: .utf8)
        XCTAssertTrue(zshrc.contains(ProxyConstants.zshManagedBlockStart))
        XCTAssertTrue(zshrc.contains("export http_proxy=\"http://127.0.0.1:7890\""))

        let test = try ProxyOperations.testAppProfile(context: context, appName: "environment", profileName: "office")
        XCTAssertTrue(test.mismatches.isEmpty)

        let gitResult = try ProxyOperations.configureAppWithProfile(context: context, appName: "git", profileName: "office")
        XCTAssertEqual(gitResult.selection.canonicalName, "git")

        let gitconfig = try String(contentsOfFile: homeDirectory + "/.gitconfig", encoding: .utf8)
        XCTAssertTrue(gitconfig.contains("[http]"))
        XCTAssertTrue(gitconfig.contains("proxy = http://127.0.0.1:7890"))
    }

    func testDashboardMatchesProfileAndOrdersEnvironmentFirst() throws {
        try saveOfficeProfile()
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "npm", profileName: "office")

        let data = ProxyDashboard.collect(context: context)

        XCTAssertEqual(data.apps.first?.name, ProxyConstants.environmentAppName)
        XCTAssertFalse(data.apps.contains { $0.name == "zsh" })

        let npm = try XCTUnwrap(data.apps.first { $0.name == "npm" })
        XCTAssertEqual(npm.alias, "office")
        XCTAssertEqual(npm.matchedProfileName, "office")
        XCTAssertEqual(npm.method.type, "file")

        let environment = try XCTUnwrap(data.apps.first { $0.name == "environment" })
        // Only npm was configured, so environment is untouched.
        XCTAssertEqual(environment.alias, "None")
        XCTAssertEqual(environment.usedBy, ["brew", "gem", "bundle", "ruby"])

        // Applying the profile through zsh matches the shared environment target.
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "zsh", profileName: "office")
        let updated = ProxyDashboard.collect(context: context)
        XCTAssertEqual(updated.apps.first { $0.name == "environment" }?.alias, "office")

        XCTAssertEqual(data.profiles.count, 1)
        XCTAssertEqual(data.profiles[0].name, "office")
    }

    func testUnsetClearsConfiguredTargets() throws {
        try saveOfficeProfile()
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "npm", profileName: "office")
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "go", profileName: "office")

        let npmResult = try ProxyOperations.clearAppProxy(context: context, appName: "npm", force: false)
        XCTAssertFalse(npmResult.aborted)
        let npmrc = try String(contentsOfFile: homeDirectory + "/.npmrc", encoding: .utf8)
        XCTAssertFalse(npmrc.contains("proxy"))

        let goResult = try ProxyOperations.clearAppProxy(context: context, appName: "go", force: false)
        let goEnv = try String(contentsOfFile: homeDirectory + "/.config/go/env", encoding: .utf8)
        XCTAssertFalse(goEnv.contains("HTTP_PROXY"))
        _ = goResult
    }

    func testUnsetZshWithoutMatchingProfileRequiresForce() throws {
        // Hand-crafted proxy state that matches no saved profile.
        let zshrc = homeDirectory + "/.zshrc"
        try "export http_proxy=http://custom:9\n".write(toFile: zshrc, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ProxyOperations.clearAppProxy(context: context, appName: "zsh", force: false)
        ) { error in
            guard let engineError = error as? ProxyEngineError else {
                XCTFail("expected ProxyEngineError, got \(error)")
                return
            }
            XCTAssertTrue(engineError.message.contains("--force"))
        }

        let result = try ProxyOperations.clearAppProxy(context: context, appName: "zsh", force: true)
        XCTAssertFalse(result.aborted)
        XCTAssertEqual(try String(contentsOfFile: zshrc, encoding: .utf8), "")

        // Unsetting a state that matches a saved profile needs no force.
        try saveOfficeProfile()
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "zsh", profileName: "office")
        let safeResult = try ProxyOperations.clearAppProxy(context: context, appName: "zsh", force: false)
        XCTAssertFalse(safeResult.aborted)
    }

    func testUnknownAppAndUnknownProfileErrors() {
        XCTAssertThrowsError(try ProxyOperations.configureAppWithProfile(context: context, appName: "nosuchapp", profileName: "x")) { error in
            guard let engineError = error as? ProxyEngineError else {
                XCTFail("expected ProxyEngineError, got \(error)")
                return
            }
            XCTAssertTrue(engineError.message.contains("Unknown app \"nosuchapp\""))
            XCTAssertTrue(engineError.message.contains("environment"))
        }

        XCTAssertThrowsError(try ProxyOperations.configureAppWithProfile(context: context, appName: "npm", profileName: "ghost")) { error in
            guard let engineError = error as? ProxyEngineError else {
                XCTFail("expected ProxyEngineError, got \(error)")
                return
            }
            XCTAssertTrue(engineError.message.contains("Unknown proxy profile \"ghost\""))
        }
    }

    func testSetAndTestOrbStackDocker() throws {
        try saveOfficeProfile()

        let result = try ProxyOperations.configureAppWithProfile(context: context, appName: "orbstack-docker", profileName: "office")
        XCTAssertEqual(result.selection.canonicalName, "orbstack-docker")

        let configPath = homeDirectory + "/.orbstack/config/docker.json"
        let config = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertTrue(config.contains("http-proxy"))
        XCTAssertTrue(config.contains("http://127.0.0.1:7890"))
        XCTAssertTrue(config.contains("localhost,127.0.0.1"))

        let test = try ProxyOperations.testAppProfile(context: context, appName: "orbstack-docker", profileName: "office")
        XCTAssertTrue(test.mismatches.isEmpty)

        let clearResult = try ProxyOperations.clearAppProxy(context: context, appName: "orbstack-docker", force: false)
        XCTAssertFalse(clearResult.aborted)
        let cleared = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(cleared.contains("proxies"))
    }

    func testUnsetOrbStackDockerWithoutConfigCreatesNothing() throws {
        _ = try ProxyOperations.clearAppProxy(context: context, appName: "orbstack-docker", force: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: homeDirectory + "/.orbstack"))
    }

    func testUserTargetOverrideMergesBuiltin() throws {
        let targetsDirectory = context.userTargetsDirectory
        try FileManager.default.createDirectory(atPath: targetsDirectory, withIntermediateDirectories: true)
        try """
        version: 1
        target:
          name: npm
          path: ~/custom-npmrc
        """.write(toFile: targetsDirectory + "/npm.yaml", atomically: true, encoding: .utf8)

        try saveOfficeProfile()
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "npm", profileName: "office")

        let custom = try String(contentsOfFile: homeDirectory + "/custom-npmrc", encoding: .utf8)
        XCTAssertTrue(custom.contains("proxy = http://127.0.0.1:7890"))
    }

    func testJSONDashboardEncoding() throws {
        try saveOfficeProfile()
        _ = try ProxyOperations.configureAppWithProfile(context: context, appName: "npm", profileName: "office")

        let data = ProxyDashboard.collect(context: context)
        let json = String(data: ProxyDashboard.jsonData(data), encoding: .utf8)!

        XCTAssertTrue(json.contains("\"http_proxy\""))
        XCTAssertTrue(json.contains("\"matchedProfileName\""))
        XCTAssertTrue(json.contains("\"proxyDisplay\""))
        XCTAssertTrue(json.contains("\"alias\" : \"office\""))
    }
}
