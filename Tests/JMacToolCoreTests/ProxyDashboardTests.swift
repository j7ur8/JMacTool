import XCTest
@testable import JMacToolCore

final class ProxyDashboardTests: XCTestCase {
    private var homeDirectory: String!

    /// The bypass domains Clash Verge injects into every system proxy it turns
    /// on (`use_default_bypass`), taken from the app's embedded default list.
    private let vergeBypassDomains = "127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,localhost,*.local,*.crashlytics.com,<local>"

    override func setUpWithError() throws {
        homeDirectory = NSTemporaryDirectory() + "JMacToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: homeDirectory)
    }

    private func scutilOutput(bypassDomains: String) -> String {
        let exceptions = SystemProxy.bypassDomainList(bypassDomains)
            .enumerated()
            .map { "    \($0.offset) : \($0.element)" }
            .joined(separator: "\n")
        let exceptionsBlock = exceptions.isEmpty
            ? ""
            : "  ExceptionsList : <array> {\n\(exceptions)\n  }\n"

        return """
        <dictionary> {
        \(exceptionsBlock)  HTTPEnable : 1
          HTTPPort : 7890
          HTTPProxy : 127.0.0.1
          HTTPSEnable : 1
          HTTPSPort : 7890
          HTTPSProxy : 127.0.0.1
          SOCKSEnable : 1
          SOCKSPort : 7890
          SOCKSProxy : 127.0.0.1
        }
        """
    }

    private func context(systemProxy scutil: String) -> ProxyFileContext {
        ProxyFileContext(homeDirectory: homeDirectory) { launchPath, arguments in
            guard launchPath == SystemProxy.scutilPath, arguments == ["--proxy"] else {
                return nil
            }
            return ProxyCommandOutput(exitStatus: 0, stdout: scutil, stderr: "")
        }
    }

    private var storeContext: ProxyFileContext {
        ProxyFileContext(homeDirectory: homeDirectory, runCommand: { _, _ in nil })
    }

    private func saveClashProfile(noProxy: String = "") throws {
        var profile = ProxyProfile(name: "clash", state: .empty)
        profile.state.httpProxy = "http://127.0.0.1:7890"
        profile.state.httpsProxy = "http://127.0.0.1:7890"
        profile.state.socks5Proxy = "socks5://127.0.0.1:7890"
        profile.state.noProxy = noProxy
        _ = try ProfileStore.saveProxyProfile(profile, context: storeContext)
    }

    private func systemEntry(_ data: ProxyDashboard.DashboardData) throws -> ProxyDashboard.DashboardApp {
        try XCTUnwrap(data.apps.first { $0.name == "system" })
    }

    /// Regression: a system proxy turned on by Clash Verge carries Verge's own
    /// bypass domains, which used to make the row fall back to "Custom" even
    /// though the endpoints matched the profile.
    func testSystemAliasMatchesWhenClientInjectedBypassDomains() throws {
        try saveClashProfile()

        let data = ProxyDashboard.collect(context: context(systemProxy: scutilOutput(bypassDomains: vergeBypassDomains)))
        let system = try systemEntry(data)

        XCTAssertEqual(system.alias, "clash")
        XCTAssertEqual(system.matchedProfileName, "clash")
    }

    func testSystemAliasIsCustomWhenEndpointsDiffer() throws {
        try saveClashProfile()

        // Same bypass domains, but the system proxy points somewhere else.
        let scutil = scutilOutput(bypassDomains: vergeBypassDomains).replacingOccurrences(of: "7890", with: "8081")
        let system = try systemEntry(ProxyDashboard.collect(context: context(systemProxy: scutil)))

        XCTAssertEqual(system.alias, "Custom")
        XCTAssertNil(system.matchedProfileName)
    }

    /// A profile that does ask for bypass domains only matches when the system
    /// honors all of them; extra system entries stay tolerated.
    func testSystemAliasRequiresProfileBypassDomainsToBeHonored() throws {
        try saveClashProfile(noProxy: "10.0.0.0/8")

        let honored = try systemEntry(ProxyDashboard.collect(context: context(systemProxy: scutilOutput(bypassDomains: vergeBypassDomains))))
        XCTAssertEqual(honored.alias, "clash")

        let missing = try systemEntry(ProxyDashboard.collect(context: context(systemProxy: scutilOutput(bypassDomains: "127.0.0.1,localhost"))))
        XCTAssertEqual(missing.alias, "Custom")
    }

    func testSystemAliasIsNoneWithoutProxyState() throws {
        try saveClashProfile()

        let scutil = """
        <dictionary> {
          HTTPEnable : 0
          HTTPSEnable : 0
          SOCKSEnable : 0
        }
        """
        let system = try systemEntry(ProxyDashboard.collect(context: context(systemProxy: scutil)))

        XCTAssertEqual(system.alias, "None")
        XCTAssertNil(system.matchedProfileName)
    }

    /// The tolerance is system-only: a file target that carries an extra
    /// `no_proxy` reads as "Custom" exactly like before.
    func testFileTargetsKeepStrictBypassComparison() throws {
        try saveClashProfile()

        let zshrc = """
        # >>> jpmanager proxy >>>
        export http_proxy="http://127.0.0.1:7890"
        export https_proxy="http://127.0.0.1:7890"
        export ALL_PROXY="socks5://127.0.0.1:7890"
        export all_proxy="socks5://127.0.0.1:7890"
        export no_proxy="localhost"
        # <<< jpmanager proxy <<<
        """
        try zshrc.write(toFile: homeDirectory + "/.zshrc", atomically: true, encoding: .utf8)

        let environment = try XCTUnwrap(
            ProxyDashboard.collect(context: storeContext).apps.first { $0.name == "environment" }
        )
        XCTAssertEqual(environment.alias, "Custom")
    }
}
