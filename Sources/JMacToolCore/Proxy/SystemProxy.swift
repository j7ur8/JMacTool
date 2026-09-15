import Foundation

/// The macOS system proxy target: state lives in the System Configuration
/// database instead of a file, so it is read with `scutil --proxy` and applied
/// with `networksetup` on the default-route network service. Command execution
/// goes through an injectable runner so tests stay hermetic.
enum SystemProxy {
    struct Endpoint: Equatable, Sendable {
        var host: String
        var port: String
    }

    struct Endpoints: Equatable, Sendable {
        var web: Endpoint?
        var secure: Endpoint?
        var socks: Endpoint?
        var bypassDomains: [String]
    }

    static let scutilPath = "/usr/sbin/scutil"
    static let networksetupPath = "/usr/sbin/networksetup"
    static let routePath = "/sbin/route"

    /// Runs a command and captures its streams; `nil` means it could not launch.
    static let defaultRun: RunCommand = { launchPath, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        guard (try? process.run()) != nil else {
            return nil
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProxyCommandOutput(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    // MARK: - Reading

    static func currentState(run: RunCommand) -> ProxyState {
        guard let output = run(scutilPath, ["--proxy"]) else {
            return .empty
        }
        return state(scutilOutput: output.stdout)
    }

    /// Parses `scutil --proxy` output. Only enabled protocols contribute;
    /// system proxies carry no credentials, so URLs come back as
    /// `http://host:port` (and `socks5://host:port` for SOCKS).
    static func state(scutilOutput: String) -> ProxyState {
        var values: [String: String] = [:]
        var bypassDomains: [String] = []
        var inExceptionsList = false

        for rawLine in scutilOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "}" {
                inExceptionsList = false
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            if inExceptionsList {
                if Int(key) != nil, !value.isEmpty {
                    bypassDomains.append(value)
                }
                continue
            }
            if key == "ExceptionsList" {
                inExceptionsList = true
                continue
            }
            values[key] = value
        }

        var state = ProxyState.empty
        if values["HTTPEnable"] == "1", let host = enabledServer(values, "HTTPProxy") {
            state.httpProxy = ProxyURL.build(protocol: "http", host: host, port: values["HTTPPort"] ?? "")
        }
        if values["HTTPSEnable"] == "1", let host = enabledServer(values, "HTTPSProxy") {
            state.httpsProxy = ProxyURL.build(protocol: "http", host: host, port: values["HTTPSPort"] ?? "")
        }
        if values["SOCKSEnable"] == "1", let host = enabledServer(values, "SOCKSProxy") {
            state.socks5Proxy = ProxyURL.build(protocol: "socks5", host: host, port: values["SOCKSPort"] ?? "")
        }
        state.noProxy = bypassDomains.joined(separator: ",")
        return state
    }

    private static func enabledServer(_ values: [String: String], _ key: String) -> String? {
        guard let host = values[key], !host.isEmpty, host != "(null)" else {
            return nil
        }
        return host
    }

    // MARK: - Normalization

    /// The state the system proxy carries once `state` has been applied; used
    /// for profile matching (alias detection) and `jpmanager test`.
    static func expectedState(_ state: ProxyState) -> ProxyState {
        let endpoints = endpoints(from: state)

        var expected = ProxyState.empty
        expected.httpProxy = endpoints.web.map { Self.url(scheme: "http", endpoint: $0) } ?? ""
        expected.httpsProxy = endpoints.secure.map { Self.url(scheme: "http", endpoint: $0) } ?? ""
        expected.socks5Proxy = endpoints.socks.map { Self.url(scheme: "socks5", endpoint: $0) } ?? ""
        expected.noProxy = endpoints.bypassDomains.joined(separator: ",")
        return expected
    }

    static func endpoints(from state: ProxyState) -> Endpoints {
        func endpoint(_ proxyURL: String) -> Endpoint? {
            guard let parts = ProxyURL.parse(proxyURL) else {
                return nil
            }
            return Endpoint(host: parts.host, port: parts.port)
        }

        return Endpoints(
            web: endpoint(state.httpProxy),
            secure: endpoint(state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy),
            socks: endpoint(state.socks5Proxy),
            bypassDomains: bypassDomainList(state.noProxy)
        )
    }

    private static func url(scheme: String, endpoint: Endpoint) -> String {
        ProxyURL.build(protocol: scheme, host: endpoint.host, port: endpoint.port)
    }

    static func bypassDomainList(_ noProxy: String) -> [String] {
        noProxy
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Writing

    /// The `networksetup` invocations that apply `state`, in order. Disabled
    /// protocols are switched off explicitly so `None` fully disables the
    /// system proxy.
    static func applyArguments(service: String, state: ProxyState) -> [[String]] {
        let endpoints = endpoints(from: state)

        var commands: [[String]] = []
        func proxyCommands(setVerb: String, stateVerb: String, endpoint: Endpoint?) {
            if let endpoint {
                commands.append(["-\(setVerb)", service, endpoint.host, endpoint.port])
                commands.append(["-\(stateVerb)", service, "on"])
            } else {
                commands.append(["-\(stateVerb)", service, "off"])
            }
        }

        proxyCommands(setVerb: "setwebproxy", stateVerb: "setwebproxystate", endpoint: endpoints.web)
        proxyCommands(setVerb: "setsecurewebproxy", stateVerb: "setsecurewebproxystate", endpoint: endpoints.secure)
        proxyCommands(setVerb: "setsocksfirewallproxy", stateVerb: "setsocksfirewallproxystate", endpoint: endpoints.socks)

        let domains = endpoints.bypassDomains.isEmpty ? ["<empty>"] : endpoints.bypassDomains
        commands.append(["-setproxybypassdomains", service] + domains)
        return commands
    }

    /// The `networksetup` invocations that reset the system proxy: proxies are
    /// disabled (keeping any stored server config) and bypass domains cleared.
    static func clearArguments(service: String) -> [[String]] {
        [
            ["-setwebproxystate", service, "off"],
            ["-setsecurewebproxystate", service, "off"],
            ["-setsocksfirewallproxystate", service, "off"],
            ["-setproxybypassdomains", service, "<empty>"]
        ]
    }

    static func apply(_ state: ProxyState, run: RunCommand) throws {
        let service = try activeServiceName(run: run)
        try execute(applyArguments(service: service, state: state), run: run)
    }

    static func clear(run: RunCommand) throws {
        let service = try activeServiceName(run: run)
        try execute(clearArguments(service: service), run: run)
    }

    private static func execute(_ commands: [[String]], run: RunCommand) throws {
        for arguments in commands {
            guard let output = run(networksetupPath, arguments) else {
                throw writeFailure(arguments, detail: "")
            }
            guard output.exitStatus == 0 else {
                throw writeFailure(arguments, detail: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private static func writeFailure(_ arguments: [String], detail: String) -> ProxyEngineError {
        let reason = detail.isEmpty ? "" : ": \(detail)"
        return ProxyEngineError(
            message: "Failed to run `networksetup \(arguments.joined(separator: " "))`\(reason). System proxy settings may be unchanged."
        )
    }

    // MARK: - Network service discovery

    /// The service attached to the default route (e.g. Wi-Fi for en0), falling
    /// back to the first enabled network service.
    static func activeServiceName(run: RunCommand) throws -> String {
        let device = defaultRouteDevice(run: run)

        if let output = run(networksetupPath, ["-listallhardwareports"]), output.exitStatus == 0 {
            let ports = parseHardwarePorts(output.stdout)
            if let device, let match = ports.first(where: { $0.device == device }) {
                return match.service
            }
        }

        if let output = run(networksetupPath, ["-listallnetworkservices"]), output.exitStatus == 0,
           let first = parseNetworkServices(output.stdout).first {
            return first
        }

        throw ProxyEngineError(message: "Could not determine the active macOS network service for the system proxy.")
    }

    static func parseHardwarePorts(_ output: String) -> [(service: String, device: String)] {
        var ports: [(service: String, device: String)] = []
        var service: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                service = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                let device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if let service, !device.isEmpty {
                    ports.append((service: service, device: device))
                }
                service = nil
            }
        }

        return ports
    }

    static func parseNetworkServices(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("asterisk") }
            .filter { !$0.hasSuffix("*") }
    }

    static func defaultRouteDevice(run: RunCommand) -> String? {
        guard let output = run(routePath, ["-n", "get", "default"]), output.exitStatus == 0 else {
            return nil
        }

        for rawLine in output.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("interface:") {
                let device = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }
}
