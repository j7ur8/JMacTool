import Darwin
import Foundation

/// Installs the historical `/usr/local/bin/jpmanager` command shim that
/// forwards to the bundled JMacTool binary so existing scripts and the zsh
/// wrapper keep working.
enum ProxyCLIInstaller {
    static var shimPath: String { "/usr/local/bin/\(ProxyConstants.legacyCommandName)" }

    static func currentExecutablePath() -> String? {
        if let url = Bundle.main.executableURL, FileManager.default.fileExists(atPath: url.path) {
            return url.path
        }

        guard let argv0 = CommandLine.arguments.first else {
            return nil
        }

        if argv0.hasPrefix("/") {
            return argv0
        }
        if argv0.contains("/") {
            return FileManager.default.currentDirectoryPath + "/" + argv0
        }
        return nil
    }

    static func shimContent(executablePath: String) -> String {
        """
        #!/bin/zsh
        exec '\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))' "$@"

        """
    }

    enum InstallOutcome {
        case alreadyInstalled
        case installed
        case replaced
    }

    static func install() throws -> InstallOutcome {
        guard let executablePath = currentExecutablePath() else {
            throw ProxyEngineError(message: "Unable to determine the JMacTool executable path for the CLI shim.")
        }

        let content = shimContent(executablePath: executablePath)

        if let existing = try? String(contentsOfFile: shimPath, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines)
               == content.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .alreadyInstalled
        }

        let directory = (shimPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let replaced = FileManager.default.fileExists(atPath: shimPath)
        let temporaryPath = "\(shimPath).tmp-\(getpid())"
        try content.write(toFile: temporaryPath, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(atPath: temporaryPath, toPath: shimPath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath)

        return replaced ? .replaced : .installed
    }
}

/// Command-line interface for the integrated proxy manager. The commands and
/// output strings mirror the jpmanager CLI so `~/.zshrc` integrations keep
/// working through the `/usr/local/bin/jpmanager` shim.
public enum ProxyCLI {
    // MARK: - Entry

    public static func shouldRunAsCLI(_ arguments: [String]) -> Bool {
        let userArguments = arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
        return !userArguments.isEmpty
    }

    @discardableResult
    public static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        run(arguments: arguments, context: .live)
    }

    @discardableResult
    static func run(arguments: [String], context: ProxyFileContext) -> Int32 {
        let userArguments = Array(arguments.dropFirst().filter { !$0.hasPrefix("-psn") })
        let programName = programNameForUsage(arguments.first)

        do {
            return try dispatch(userArguments, programName: programName, context: context)
        } catch let error as ProxyEngineError {
            FileHandle.standardError.write("\(error.message)\n".data(using: .utf8)!)
            if !error.usage.isEmpty {
                FileHandle.standardError.write("\(error.usage)\n".data(using: .utf8)!)
            }
            return error.exitCode
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static func programNameForUsage(_ argv0: String?) -> String {
        guard let argv0, !argv0.isEmpty else {
            return ProxyConstants.legacyCommandName
        }
        return (argv0 as NSString).lastPathComponent
    }

    private static func usageError(_ message: String, _ usage: String) -> ProxyEngineError {
        ProxyEngineError(message: message, usage: usage)
    }

    private static func generalUsage(programName: String) -> String {
        """
        Usage: \(programName) proxy
           or: \(programName) proxy add --name <name> [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]
           or: \(programName) proxy edit --name <existing-name> [--rename <new-name>] [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]
           or: \(programName) list [--json]
           or: \(programName) set <app> <profile-name>
           or: \(programName) unset <app> [--force]
           or: \(programName) test <app> <profile-name>
           or: \(programName) config
           or: \(programName) shell-init zsh
           or: \(programName) shell-apply zsh
           or: \(programName) login <enable|disable|status> [--json]
           or: \(programName) install-cli
        """
    }

    private static func dispatch(
        _ arguments: [String],
        programName: String,
        context: ProxyFileContext
    ) throws -> Int32 {
        guard let command = arguments.first else {
            throw usageError("", generalUsage(programName: programName))
        }

        let optionArgs = Array(arguments.dropFirst())

        switch command {
        case "help", "--help", "-h":
            print(generalUsage(programName: programName))
            return 0

        case "proxy":
            return try handleProxyCommand(optionArgs, programName: programName, context: context)

        case "list":
            return try handleListCommand(optionArgs, context: context)

        case "set":
            return try handleSetCommand(optionArgs, programName: programName, context: context)

        case "unset":
            return try handleUnsetCommand(optionArgs, programName: programName, context: context)

        case "test":
            return try handleTestCommand(optionArgs, programName: programName, context: context)

        case "config":
            return try handleConfigCommand(context: context)

        case "shell-init":
            return try handleShellInitCommand(optionArgs.first)

        case "shell-apply":
            return try handleShellApplyCommand(optionArgs.first, context: context)

        case "login":
            return try handleLoginCommand(optionArgs)

        case "gui":
            print("JMacTool is the menu bar app; its proxy menu lives in the JMacTool status item.")
            return 0

        case "install-cli":
            return try handleInstallCLICommand()

        default:
            throw usageError("Unknown command \"\(command)\".", generalUsage(programName: programName))
        }
    }

    // MARK: - Shared helpers

    private static var stdinIsTTY: Bool {
        isatty(STDIN_FILENO) == 1
    }

    private static func parseWriteOptions(_ optionArgs: [String]) throws -> (profile: ProxyProfile, allowOverwrite: Bool, originalName: String) {
        var profile = ProxyProfile(name: "", state: .empty)
        var seenKeys = Set<String>()
        var allowOverwrite = false
        var originalName = ""

        var index = 0
        while index < optionArgs.count {
            let option = optionArgs[index]
            let nextValue = index + 1 < optionArgs.count ? optionArgs[index + 1] : nil

            if option == "--force" {
                allowOverwrite = true
                index += 1
                continue
            }

            func takeValue() throws -> String {
                guard let nextValue else {
                    throw usageError("Missing value for \(option).", "")
                }
                index += 1
                return nextValue
            }

            switch option {
            case "--name":
                let value = try takeValue()
                originalName = value
                if !seenKeys.contains("name") {
                    profile.name = value
                    seenKeys.insert("name")
                }
            case "--rename":
                let value = try takeValue()
                profile.name = value
                seenKeys.insert("name")
            case "--http-proxy":
                profile.state.httpProxy = try takeValue()
            case "--https-proxy":
                profile.state.httpsProxy = try takeValue()
            case "--socks5-proxy":
                profile.state.socks5Proxy = try takeValue()
            case "--no-proxy":
                profile.state.noProxy = try takeValue()
            default:
                throw usageError("Unknown option \"\(option)\".", "")
            }

            index += 1
        }

        return (profile, allowOverwrite, originalName)
    }

    private static func printProfileDetails(_ profile: ProxyProfile) {
        print("Name: \(profile.name)")
        print("HTTP: \(profile.state.httpProxy.isEmpty ? "-" : profile.state.httpProxy)")
        print("HTTPS: \(profile.state.httpsProxy.isEmpty ? "-" : profile.state.httpsProxy)")
        print("SOCKS5: \(profile.state.socks5Proxy.isEmpty ? "-" : profile.state.socks5Proxy)")
    }

    private static func interactiveSelect(title: String, items: [String]) -> Int? {
        guard stdinIsTTY else {
            return nil
        }

        print(title)
        for (index, item) in items.enumerated() {
            print("  \(index + 1). \(item)")
        }
        print("  0. Cancel")
        print("Enter a number: ", terminator: "")

        guard let line = readLine()?.trimmingCharacters(in: .whitespaces),
              let number = Int(line),
              number >= 0,
              number <= items.count else {
            return nil
        }
        return number == 0 ? nil : number - 1
    }

    private static func promptInput(_ label: String, allowEmpty: Bool) -> String? {
        while true {
            print("\(label): ", terminator: "")
            guard let line = readLine() else {
                return nil
            }
            let value = line.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty || allowEmpty {
                return value
            }
        }
    }

    private static func promptConfirm(_ question: String) -> Bool {
        print("\(question) [y/N]: ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return line == "y" || line == "yes"
    }

    private static func maybePrintZshShellHookHint() {
        guard isatty(STDOUT_FILENO) == 1,
              ProcessInfo.processInfo.environment["JPMANAGER_ZSH_SHELL_HOOK"] != "1" else {
            return
        }

        FileHandle.standardError.write(
            "Current shell session was not updated. Run `eval \"$(\(ProxyConstants.legacyCommandName) shell-init zsh)\"` once to make `\(ProxyConstants.legacyCommandName) set zsh` and `\(ProxyConstants.legacyCommandName) unset zsh` apply immediately in the current zsh shell.\n"
                .data(using: .utf8)!
        )
    }

    // MARK: - proxy

    private static func handleProxyCommand(_ arguments: [String], programName: String, context: ProxyFileContext) throws -> Int32 {
        guard let action = arguments.first else {
            return try handleInteractiveProxyCommand(context: context)
        }

        let proxyUsage = """
        Usage: \(programName) proxy
           or: \(programName) proxy add --name <name> [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]
           or: \(programName) proxy edit --name <existing-name> [--rename <new-name>] [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]
        """

        guard action == "add" || action == "edit" else {
            throw usageError("Unknown proxy action \"\(action)\".", proxyUsage)
        }

        let parsed = try parseWriteOptions(Array(arguments.dropFirst()))

        if action == "add" {
            let saved = try ProfileStore.saveProxyProfile(
                parsed.profile,
                context: context,
                allowOverwrite: parsed.allowOverwrite
            )
            print("Saved proxy profile \"\(saved.profile.name)\".")
            return 0
        }

        guard !parsed.originalName.isEmpty else {
            throw usageError("Missing value for --name.", "")
        }

        let updates = ProfileStore.ProxyProfileUpdates(
            name: parsed.profile.name.isEmpty ? nil : parsed.profile.name,
            httpProxy: parsed.profile.state.httpProxy,
            httpsProxy: parsed.profile.state.httpsProxy,
            socks5Proxy: parsed.profile.state.socks5Proxy,
            noProxy: parsed.profile.state.noProxy
        )
        let saved = try ProfileStore.editProxyProfile(
            parsed.originalName,
            updates: updates,
            context: context,
            allowOverwrite: parsed.allowOverwrite
        )
        print("Saved proxy profile \"\(saved.profile.name)\".")
        return 0
    }

    private static func handleInteractiveProxyCommand(context: ProxyFileContext) throws -> Int32 {
        guard stdinIsTTY else {
            throw usageError(
                "Interactive mode requires a TTY. Use `\("jpmanager") proxy add` or `proxy edit` instead.",
                ""
            )
        }

        let profiles = ProfileStore.ensureStore(context: context)
        let items = profiles.map { stored in
            "\(stored.profile.name)  \(ProxyDisplay.describe(stored.profile.state))"
        } + ["Add one proxy"]

        guard let selected = interactiveSelect(
            title: profiles.isEmpty ? "No proxy profiles found.\n" : "Saved proxy profiles.\n",
            items: items
        ) else {
            return 0
        }

        if selected < profiles.count {
            printProfileDetails(profiles[selected].profile)
            return 0
        }

        guard let name = promptInput("Config name", allowEmpty: false),
              let httpProxy = promptInput("http_proxy", allowEmpty: true),
              let httpsProxy = promptInput("https_proxy", allowEmpty: true),
              let socks5Proxy = promptInput("socks5_proxy", allowEmpty: true),
              let noProxy = promptInput("no_proxy", allowEmpty: true) else {
            FileHandle.standardError.write("Aborted.\n".data(using: .utf8)!)
            return 1
        }

        var allowOverwrite = false
        if ProfileStore.findProfileByName(profiles, name) != nil {
            guard promptConfirm("Proxy profile \"\(name)\" already exists. Override it?") else {
                FileHandle.standardError.write("Aborted.\n".data(using: .utf8)!)
                return 1
            }
            allowOverwrite = true
        }

        var profile = ProxyProfile(name: name, state: .empty)
        profile.state.httpProxy = httpProxy
        profile.state.httpsProxy = httpsProxy
        profile.state.socks5Proxy = socks5Proxy
        profile.state.noProxy = noProxy

        let saved = try ProfileStore.saveProxyProfile(profile, context: context, allowOverwrite: allowOverwrite)
        print("Saved proxy profile \"\(saved.profile.name)\".")
        return 0
    }

    // MARK: - list

    private static func handleListCommand(_ arguments: [String], context: ProxyFileContext) throws -> Int32 {
        let unknownArgs = arguments.filter { $0 != "--json" }
        if !unknownArgs.isEmpty {
            throw usageError(
                "Unknown option(s): \(unknownArgs.joined(separator: ", "))",
                "Usage: jpmanager list [--json]"
            )
        }

        let data = ProxyDashboard.collect(context: context)

        if arguments.contains("--json") {
            let json = ProxyDashboard.jsonData(data)
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            return 0
        }

        FileHandle.standardOutput.write(ProxyDashboard.renderListTable(data.apps).data(using: .utf8)!)
        return 0
    }

    // MARK: - set / unset / test

    private static func handleSetCommand(_ arguments: [String], programName: String, context: ProxyFileContext) throws -> Int32 {
        guard arguments.count >= 2 else {
            throw usageError("", "Usage: \(programName) set <app> <profile-name>")
        }

        let result = try ProxyOperations.configureAppWithProfile(
            context: context,
            appName: arguments[0],
            profileName: arguments[1]
        )

        let targetSuffix = context.fileExists(result.way) ? " in \(result.way)" : ""
        print("Configured \(result.selection.requestedName) with proxy profile \"\(result.profile.name)\"\(targetSuffix).")

        if result.selection.canonicalName == "zsh" || result.selection.canonicalName == ProxyConstants.environmentAppName {
            maybePrintZshShellHookHint()
        }
        return 0
    }

    private static func handleUnsetCommand(_ arguments: [String], programName: String, context: ProxyFileContext) throws -> Int32 {
        guard let appName = arguments.first else {
            throw usageError("", "Usage: \(programName) unset <app> [--force]")
        }

        let optionArgs = Array(arguments.dropFirst())
        let unknownArgs = optionArgs.filter { $0 != "--force" }
        if !unknownArgs.isEmpty {
            throw usageError(
                "Unknown option(s): \(unknownArgs.joined(separator: ", "))",
                "Usage: \(programName) unset <app> [--force]"
            )
        }

        let interactiveConfirmation: ((ProxyState, String) -> Bool)? = stdinIsTTY
            ? { current, subjectLabel in
                let warning = "Current \(subjectLabel) proxy settings (\(ProxyDisplay.describe(current))) do not match any saved jpmanager profile. They may have been modified by another app."
                if !promptConfirm("\(warning) Unset anyway?") {
                    FileHandle.standardError.write("Aborted.\n".data(using: .utf8)!)
                    return false
                }
                return true
            }
            : nil

        let result = try ProxyOperations.clearAppProxy(
            context: context,
            appName: appName,
            force: optionArgs.contains("--force"),
            confirmUnsafeUnset: interactiveConfirmation
        )

        if result.aborted {
            return 1
        }

        print("Unset proxy settings for \(result.selection.requestedName) in \(result.selection.target.wayLabel).")

        if result.selection.canonicalName == "zsh" || result.selection.canonicalName == ProxyConstants.environmentAppName {
            maybePrintZshShellHookHint()
        }
        return 0
    }

    private static func handleTestCommand(_ arguments: [String], programName: String, context: ProxyFileContext) throws -> Int32 {
        guard arguments.count >= 2 else {
            throw usageError("", "Usage: \(programName) test <app> <profile-name>")
        }

        let result = try ProxyOperations.testAppProfile(
            context: context,
            appName: arguments[0],
            profileName: arguments[1]
        )

        if result.mismatches.isEmpty {
            print("OK: \(result.selection.requestedName) matches proxy profile \"\(result.profile.name)\" in \(result.way).")
            return 0
        }

        FileHandle.standardError.write(
            "Mismatch: \(result.selection.requestedName) config in \(result.way) does not match proxy profile \"\(result.profile.name)\".\n"
                .data(using: .utf8)!
        )
        for mismatch in result.mismatches {
            FileHandle.standardError.write(
                "\(mismatch.key.rawValue): expected \(mismatch.expected.isEmpty ? "-" : mismatch.expected), actual \(mismatch.actual.isEmpty ? "-" : mismatch.actual)\n"
                    .data(using: .utf8)!
            )
        }
        return 1
    }

    // MARK: - config (interactive selector)

    private static func handleConfigCommand(context: ProxyFileContext) throws -> Int32 {
        guard stdinIsTTY else {
            throw usageError("Interactive mode requires a TTY.", "")
        }

        while true {
            let data = ProxyDashboard.collect(context: context)
            let items = data.apps.map { "\($0.name): \($0.proxyDisplay)" } + ["Exit"]

            guard let selectedIndex = interactiveSelect(title: "App proxy configuration\n", items: items),
                  selectedIndex < data.apps.count else {
                return 0
            }

            let app = data.apps[selectedIndex]
            guard !data.profiles.isEmpty else {
                FileHandle.standardError.write("No proxy profiles found. Run `jpmanager proxy` first.\n".data(using: .utf8)!)
                return 1
            }

            let profileItems = data.profiles.map { "\($0.name)  \($0.proxyDisplay)" }
            guard let profileIndex = interactiveSelect(title: "Choose a proxy for \(app.name)\n", items: profileItems) else {
                continue
            }

            let selectedProfile = data.profiles[profileIndex]
            let stored = try ProxyOperations.findProxyProfileByName(context: context, profileName: selectedProfile.name)
            try ProxyOperations.resolveAppSelection(app.name, context: context).target.apply(stored.state)
            print("Configured \(app.name) with proxy profile \"\(selectedProfile.name)\".")
        }
    }

    // MARK: - shell hooks

    private static func handleShellInitCommand(_ shellName: String?) throws -> Int32 {
        guard let shellName else {
            FileHandle.standardError.write("Usage: jpmanager shell-init <shell>\n".data(using: .utf8)!)
            return 1
        }

        guard shellName == "zsh" else {
            FileHandle.standardError.write("Unknown shell \"\(shellName)\". Available shells: zsh\n".data(using: .utf8)!)
            return 1
        }

        print(ProxyShellCommands.buildZshShellInitScript(invocationCommand: ProxyShellCommands.currentInvocationCommand()), terminator: "")
        return 0
    }

    private static func handleShellApplyCommand(_ shellName: String?, context: ProxyFileContext) throws -> Int32 {
        guard let shellName else {
            FileHandle.standardError.write("Usage: jpmanager shell-apply <shell>\n".data(using: .utf8)!)
            return 1
        }

        guard shellName == "zsh" else {
            FileHandle.standardError.write("Unknown shell \"\(shellName)\". Available shells: zsh\n".data(using: .utf8)!)
            return 1
        }

        guard let zshTarget = ProxyTargetLoader.load(context: context).targets.first(where: { $0.name == "zsh" }) else {
            FileHandle.standardError.write("Target \"zsh\" is not available.\n".data(using: .utf8)!)
            return 1
        }

        print(ProxyShellCommands.buildZshCurrentShellCommands(zshTarget.currentState()), terminator: "")
        return 0
    }

    // MARK: - login

    private static func handleLoginCommand(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw usageError("", "Usage: jpmanager login <enable|disable|status> [--json]")
        }

        let wantsJSON = arguments.contains("--json")

        switch action {
        case "enable":
            if let error = ProxyLoginService.enable() {
                FileHandle.standardError.write("Failed to enable launch at login: \(error)\n".data(using: .utf8)!)
                return 1
            }
            print("Launch at login enabled.")
            return 0

        case "disable":
            if let error = ProxyLoginService.disable() {
                FileHandle.standardError.write("Failed to disable launch at login: \(error)\n".data(using: .utf8)!)
                return 1
            }
            print("Launch at login disabled.")
            return 0

        case "status":
            let status = ProxyLoginService.currentStatus()
            if wantsJSON {
                let payload: [String: Any] = ["enabled": status == .enabled, "status": status.rawValue]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            } else {
                print("Launch at login: \(status.rawValue)")
            }
            return 0

        default:
            throw usageError("Unknown login action \"\(action)\".", "Usage: jpmanager login <enable|disable|status> [--json]")
        }
    }

    // MARK: - install-cli

    private static func handleInstallCLICommand() throws -> Int32 {
        switch try ProxyCLIInstaller.install() {
        case .alreadyInstalled:
            print("The \(ProxyCLIInstaller.shimPath) command shim is already up to date.")
        case .installed:
            print("Installed \(ProxyCLIInstaller.shimPath).")
        case .replaced:
            print("Replaced \(ProxyCLIInstaller.shimPath).")
        }
        return 0
    }
}
