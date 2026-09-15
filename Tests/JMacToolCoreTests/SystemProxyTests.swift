import XCTest
@testable import JMacToolCore

final class SystemProxyTests: XCTestCase {
    private let scutilOutput = """
    <dictionary> {
      ExceptionsList : <array> {
        0 : 127.0.0.1
        1 : 192.168.0.0/16
        2 : localhost
        3 : <local>
      }
      HTTPEnable : 1
      HTTPPort : 7890
      HTTPProxy : 127.0.0.1
      HTTPSEnable : 1
      HTTPSPort : 7890
      HTTPSProxy : 127.0.0.1
      SOCKSEnable : 0
      SOCKSPort : 0
      SOCKSProxy : (null)
    }
    """

    func testStateParsesScutilOutput() {
        let state = SystemProxy.state(scutilOutput: scutilOutput)

        XCTAssertEqual(state.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(state.httpsProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(state.socks5Proxy, "")
        XCTAssertEqual(state.noProxy, "127.0.0.1,192.168.0.0/16,localhost,<local>")
    }

    func testStateIsEmptyWhenAllProtocolsDisabled() {
        let output = """
        <dictionary> {
          HTTPEnable : 0
          HTTPPort : 0
          HTTPProxy : (null)
          HTTPSEnable : 0
          SOCKSEnable : 0
        }
        """

        XCTAssertEqual(SystemProxy.state(scutilOutput: output), .empty)
    }

    func testCurrentStateReturnsEmptyWhenScutilUnavailable() {
        let state = SystemProxy.currentState { _, _ in nil }

        XCTAssertEqual(state, .empty)
    }

    func testExpectedStateNormalizesThroughNetworksetupRoundTrip() {
        var profile = ProxyState.empty
        profile.httpProxy = "http://user:secret@127.0.0.1:7890"
        profile.httpsProxy = ""
        profile.socks5Proxy = "socks5://10.0.0.1"
        profile.noProxy = " 127.0.0.1, localhost , *.local "

        let expected = SystemProxy.expectedState(profile)

        // Credentials are dropped (system proxies keep none) and ports get
        // their protocol defaults, matching what currentState() reads back.
        XCTAssertEqual(expected.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(expected.httpsProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(expected.socks5Proxy, "socks5://10.0.0.1:1080")
        XCTAssertEqual(expected.noProxy, "127.0.0.1,localhost,*.local")
    }

    func testApplyArgumentsEnablesConfiguredAndDisablesMissingProtocols() {
        var state = ProxyState.empty
        state.httpProxy = "http://127.0.0.1:7890"
        state.socks5Proxy = "socks5://10.0.0.1:1080"
        state.noProxy = "127.0.0.1, localhost"

        let commands = SystemProxy.applyArguments(service: "Wi-Fi", state: state)

        XCTAssertEqual(commands, [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setwebproxystate", "Wi-Fi", "on"],
            // https falls back to http, so secure web is configured too.
            ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setsecurewebproxystate", "Wi-Fi", "on"],
            ["-setsocksfirewallproxy", "Wi-Fi", "10.0.0.1", "1080"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "on"],
            ["-setproxybypassdomains", "Wi-Fi", "127.0.0.1", "localhost"]
        ])
    }

    func testClearArgumentsDisablesEverythingAndClearsBypassDomains() {
        XCTAssertEqual(SystemProxy.clearArguments(service: "Wi-Fi"), [
            ["-setwebproxystate", "Wi-Fi", "off"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
            ["-setproxybypassdomains", "Wi-Fi", "<empty>"]
        ])
    }

    func testActiveServiceNamePrefersDefaultRouteDevice() throws {
        let calls = CommandRecorder([
            ("/sbin/route", ["-n", "get", "default"], .init(
                exitStatus: 0,
                stdout: "   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en5\n",
                stderr: ""
            )),
            ("/usr/sbin/networksetup", ["-listallhardwareports"], .init(
                exitStatus: 0,
                stdout: """
                Hardware Port: Wi-Fi
                Device: en0
                Ethernet Address: aa:bb:cc:dd:ee:ff

                Hardware Port: USB 10/100/1000 LAN
                Device: en5
                Ethernet Address: 11:22:33:44:55:66

                VLAN Configurations
                ===================
                """,
                stderr: ""
            ))
        ])

        let service = try SystemProxy.activeServiceName(run: calls.runner)

        XCTAssertEqual(service, "USB 10/100/1000 LAN")
        XCTAssertEqual(calls.invoked.count, 2)
    }

    func testActiveServiceNameFallsBackToFirstEnabledService() throws {
        let calls = CommandRecorder([
            ("/sbin/route", ["-n", "get", "default"], .init(exitStatus: 1, stdout: "", stderr: "entry not found")),
            ("/usr/sbin/networksetup", ["-listallhardwareports"], .init(exitStatus: 0, stdout: "garbage", stderr: "")),
            ("/usr/sbin/networksetup", ["-listallnetworkservices"], .init(
                exitStatus: 0,
                stdout: "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nThunderbolt Bridge*\n",
                stderr: ""
            ))
        ])

        let service = try SystemProxy.activeServiceName(run: calls.runner)

        XCTAssertEqual(service, "Wi-Fi")
    }

    func testActiveServiceNameThrowsWhenNothingResolves() {
        let calls = CommandRecorder([
            ("/sbin/route", ["-n", "get", "default"], .init(exitStatus: 1, stdout: "", stderr: "")),
            ("/usr/sbin/networksetup", ["-listallhardwareports"], .init(exitStatus: 1, stdout: "", stderr: "")),
            ("/usr/sbin/networksetup", ["-listallnetworkservices"], .init(exitStatus: 1, stdout: "", stderr: ""))
        ])

        XCTAssertThrowsError(try SystemProxy.activeServiceName(run: calls.runner))
    }

    func testApplyThrowsWhenNetworksetupFails() {
        let calls = CommandRecorder([
            ("/sbin/route", ["-n", "get", "default"], .init(exitStatus: 0, stdout: "  interface: en0\n", stderr: "")),
            ("/usr/sbin/networksetup", ["-listallhardwareports"], .init(exitStatus: 0, stdout: "Hardware Port: Wi-Fi\nDevice: en0\n", stderr: "")),
            ("/usr/sbin/networksetup", ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"], .init(exitStatus: 5, stdout: "", stderr: "** Error: not permitted"))
        ])

        XCTAssertThrowsError(try SystemProxy.apply(ProxyState(urlHost: "127.0.0.1", urlPort: "7890"), run: calls.runner)) { error in
            guard let engineError = error as? ProxyEngineError else {
                XCTFail("expected ProxyEngineError, got \(error)")
                return
            }
            XCTAssertTrue(engineError.message.contains("not permitted"))
        }
    }

    private final class CommandRecorder: @unchecked Sendable {
        struct Output {
            var exitStatus: Int32
            var stdout: String
            var stderr: String
        }

        private let outputs: [(launchPath: String, arguments: [String], output: Output)]
        private(set) var invoked: [(launchPath: String, arguments: [String])] = []

        init(_ outputs: [(launchPath: String, arguments: [String], output: Output)]) {
            self.outputs = outputs
        }

        lazy var runner: RunCommand = { [self] launchPath, arguments in
            invoked.append((launchPath, arguments))
            guard let match = outputs.first(where: { $0.launchPath == launchPath && $0.arguments == arguments }) else {
                return ProxyCommandOutput(exitStatus: 1, stdout: "", stderr: "unexpected command \(launchPath) \(arguments)")
            }
            return .init(exitStatus: match.output.exitStatus, stdout: match.output.stdout, stderr: match.output.stderr)
        }
    }
}

private extension ProxyState {
    init(urlHost: String, urlPort: String) {
        self.init()
        httpProxy = "http://\(urlHost):\(urlPort)"
    }
}
