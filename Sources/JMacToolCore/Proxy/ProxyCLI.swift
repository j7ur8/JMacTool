import Darwin
import Foundation

/// Injectable console for the proxy CLI so command handlers are testable.
struct ProxyCLIIO: Sendable {
    let writeStdout: @Sendable (String) -> Void
    let writeStderr: @Sendable (String) -> Void
    let stdinIsTTY: @Sendable () -> Bool
    let stdoutIsTTY: @Sendable () -> Bool
    let readLine: @Sendable () -> String?
    let environment: [String: String]

    static let live = ProxyCLIIO(
        writeStdout: { FileHandle.standardOutput.write($0.data(using: .utf8)!) },
        writeStderr: { FileHandle.standardError.write($0.data(using: .utf8)!) },
        stdinIsTTY: { isatty(STDIN_FILENO) == 1 },
        stdoutIsTTY: { isatty(STDOUT_FILENO) == 1 },
        readLine: { Swift.readLine() },
        environment: ProcessInfo.processInfo.environment
    )
}

/// Everything a command handler needs: the store context, the program name it
/// was invoked as, and the console.
struct ProxyCLIInvocation {
    let programName: String
    let context: ProxyFileContext
    let io: ProxyCLIIO

    func usageError(_ message: String, _ usage: String) -> ProxyEngineError {
        ProxyEngineError(message: message, usage: usage)
    }

    func print(_ text: String) {
        io.writeStdout(text + "\n")
    }

    func printError(_ text: String) {
        io.writeStderr(text + "\n")
    }
}

/// Command-line interface for the integrated proxy manager. It lives inside the
/// app bundle (`JMacTool.app/Contents/MacOS/JMacTool`), so there is no separate
/// command to install: invoke the bundled binary directly. The commands and
/// output strings mirror the jpmanager CLI, and `shell-init zsh` prints a
/// wrapper named after the historical command. Dispatch, help, and usage text
/// are generated from a single command table.
public enum ProxyCLI {
    // MARK: - Entry

    public static func shouldRunAsCLI(_ arguments: [String]) -> Bool {
        let userArguments = arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
        return !userArguments.isEmpty
    }

    @discardableResult
    public static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        run(arguments: arguments, context: .live, io: .live)
    }

    @discardableResult
    static func run(arguments: [String], context: ProxyFileContext, io: ProxyCLIIO) -> Int32 {
        let userArguments = Array(arguments.dropFirst().filter { !$0.hasPrefix("-psn") })
        let programName = programNameForUsage(arguments.first)
        let invocation = ProxyCLIInvocation(programName: programName, context: context, io: io)

        do {
            return try dispatch(userArguments, invocation: invocation)
        } catch let error as ProxyEngineError {
            io.writeStderr("\(error.message)\n")
            if !error.usage.isEmpty {
                io.writeStderr("\(error.usage)\n")
            }
            return error.exitCode
        } catch {
            io.writeStderr("\(error)\n")
            return 1
        }
    }

    private static func programNameForUsage(_ argv0: String?) -> String {
        guard let argv0, !argv0.isEmpty else {
            return ProxyConstants.legacyCommandName
        }
        return (argv0 as NSString).lastPathComponent
    }

    // MARK: - Command table

    private struct CommandSpec {
        let name: String
        let summary: String
        let usageLines: (String) -> [String]
        let run: (ProxyCLIInvocation, [String]) throws -> Int32
    }

    private static let proxyUsageLines: @Sendable (String) -> [String] = { programName in
        [
            "\(programName) proxy",
            "\(programName) proxy add --name <name> [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]",
            "\(programName) proxy edit --name <existing-name> [--rename <new-name>] [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]",
            "\(programName) proxy remove <name> [--force]"
        ]
    }

    private static var commands: [CommandSpec] {
        [
            CommandSpec(
                name: "proxy",
                summary: "Manage saved proxy profiles (interactive, or add/edit/remove)",
                usageLines: proxyUsageLines,
                run: { invocation, args in try handleProxyCommand(invocation, args) }
            ),
            CommandSpec(
                name: "list",
                summary: "Show every managed app with its current proxy state",
                usageLines: { programName in ["\(programName) list [--json]"] },
                run: { invocation, args in try handleListCommand(invocation, args) }
            ),
            CommandSpec(
                name: "set",
                summary: "Apply a saved proxy profile to an app",
                usageLines: { programName in ["\(programName) set <app> <profile-name>"] },
                run: { invocation, args in try handleSetCommand(invocation, args) }
            ),
            CommandSpec(
                name: "unset",
                summary: "Remove the managed proxy settings for an app",
                usageLines: { programName in ["\(programName) unset <app> [--force]"] },
                run: { invocation, args in try handleUnsetCommand(invocation, args) }
            ),
            CommandSpec(
                name: "test",
                summary: "Check whether an app config matches a saved profile",
                usageLines: { programName in ["\(programName) test <app> <profile-name>"] },
                run: { invocation, args in try handleTestCommand(invocation, args) }
            ),
            CommandSpec(
                name: "config",
                summary: "Interactively pick an app and apply a profile (TTY)",
                usageLines: { programName in ["\(programName) config"] },
                run: { invocation, _ in try handleConfigCommand(invocation) }
            ),
            CommandSpec(
                name: "shell-init",
                summary: "Print the zsh wrapper for instant session updates",
                usageLines: { programName in ["\(programName) shell-init zsh"] },
                run: { invocation, args in try handleShellInitCommand(invocation, args.first) }
            ),
            CommandSpec(
                name: "shell-apply",
                summary: "Print export/unset lines for the current session",
                usageLines: { programName in ["\(programName) shell-apply zsh"] },
                run: { invocation, args in try handleShellApplyCommand(invocation, args.first) }
            ),
            CommandSpec(
                name: "login",
                summary: "Control or report launch-at-login",
                usageLines: { programName in ["\(programName) login <enable|disable|status> [--json]"] },
                run: { invocation, args in try handleLoginCommand(invocation, args) }
            ),
            CommandSpec(
                name: "gui",
                summary: "Show a hint about the menu bar app",
                usageLines: { programName in ["\(programName) gui"] },
                run: { invocation, _ in
                    invocation.print("JMacTool is the menu bar app; its proxy menu lives in the JMacTool status item.")
                    return 0
                }
            )
        ]
    }

    private static func generalUsage(programName: String) -> String {
        let lines = commands.flatMap { $0.usageLines(programName) }
        guard let first = lines.first else {
            return ""
        }
        return (["Usage: \(first)"] + lines.dropFirst().map { "   or: \($0)" }).joined(separator: "\n")
    }

    private static func dispatch(_ arguments: [String], invocation: ProxyCLIInvocation) throws -> Int32 {
        guard let command = arguments.first else {
            throw invocation.usageError("", generalUsage(programName: invocation.programName))
        }

        if command == "help" || command == "--help" || command == "-h" {
            invocation.print(generalUsage(programName: invocation.programName))
            return 0
        }

        guard let spec = commands.first(where: { $0.name == command }) else {
            throw invocation.usageError(
                "Unknown command \"\(command)\".",
                generalUsage(programName: invocation.programName)
            )
        }

        return try spec.run(invocation, Array(arguments.dropFirst()))
    }

    // MARK: - Shared helpers

    struct ParsedWriteOptions {
        var profile = ProxyProfile(name: "", state: .empty)
        var allowOverwrite = false
        var originalName = ""
        /// Options the user actually passed; only these become edit updates.
        var providedStateKeys: Set<String> = []
    }

    private static func parseWriteOptions(_ optionArgs: [String]) throws -> ParsedWriteOptions {
        var parsed = ParsedWriteOptions()
        var seenKeys = Set<String>()

        var index = 0
        while index < optionArgs.count {
            let option = optionArgs[index]
            let nextValue = index + 1 < optionArgs.count ? optionArgs[index + 1] : nil

            if option == "--force" {
                parsed.allowOverwrite = true
                index += 1
                continue
            }

            func takeValue() throws -> String {
                guard let nextValue else {
                    throw ProxyEngineError(message: "Missing value for \(option).")
                }
                index += 1
                return nextValue
            }

            switch option {
            case "--name":
                let value = try takeValue()
                parsed.originalName = value
                if !seenKeys.contains("name") {
                    parsed.profile.name = value
                    seenKeys.insert("name")
                }
            case "--rename":
                let value = try takeValue()
                parsed.profile.name = value
                seenKeys.insert("name")
            case "--http-proxy":
                parsed.profile.state.httpProxy = try takeValue()
                parsed.providedStateKeys.insert("httpProxy")
            case "--https-proxy":
                parsed.profile.state.httpsProxy = try takeValue()
                parsed.providedStateKeys.insert("httpsProxy")
            case "--socks5-proxy":
                parsed.profile.state.socks5Proxy = try takeValue()
                parsed.providedStateKeys.insert("socks5Proxy")
            case "--no-proxy":
                parsed.profile.state.noProxy = try takeValue()
                parsed.providedStateKeys.insert("noProxy")
            default:
                throw ProxyEngineError(message: "Unknown option \"\(option)\".")
            }

            index += 1
        }

        return parsed
    }

    private static func printProfileDetails(_ invocation: ProxyCLIInvocation, _ profile: ProxyProfile) {
        invocation.print("Name: \(profile.name)")
        invocation.print("HTTP: \(profile.state.httpProxy.isEmpty ? "-" : profile.state.httpProxy)")
        invocation.print("HTTPS: \(profile.state.httpsProxy.isEmpty ? "-" : profile.state.httpsProxy)")
        invocation.print("SOCKS5: \(profile.state.socks5Proxy.isEmpty ? "-" : profile.state.socks5Proxy)")
    }

    private static func interactiveSelect(
        _ invocation: ProxyCLIInvocation,
        title: String,
        items: [String]
    ) -> Int? {
        guard invocation.io.stdinIsTTY() else {
            return nil
        }

        invocation.io.writeStdout(title + "\n")
        for (index, item) in items.enumerated() {
            invocation.io.writeStdout("  \(index + 1). \(item)\n")
        }
        invocation.io.writeStdout("  0. Cancel\n")
        invocation.io.writeStdout("Enter a number: ")

        guard let line = invocation.io.readLine()?.trimmingCharacters(in: .whitespaces),
              let number = Int(line),
              number >= 0,
              number <= items.count else {
            return nil
        }
        return number == 0 ? nil : number - 1
    }

    private static func promptInput(_ invocation: ProxyCLIInvocation, _ label: String, allowEmpty: Bool) -> String? {
        while true {
            invocation.io.writeStdout("\(label): ")
            guard let line = invocation.io.readLine() else {
                return nil
            }
            let value = line.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty || allowEmpty {
                return value
            }
        }
    }

    private static func promptConfirm(_ invocation: ProxyCLIInvocation, _ question: String) -> Bool {
        invocation.io.writeStdout("\(question) [y/N]: ")
        guard let line = invocation.io.readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return line == "y" || line == "yes"
    }

    private static func maybePrintZshShellHookHint(_ invocation: ProxyCLIInvocation) {
        guard invocation.io.stdoutIsTTY(),
              invocation.io.environment["JPMANAGER_ZSH_SHELL_HOOK"] != "1" else {
            return
        }

        invocation.printError(
            "Current shell session was not updated. Run `eval \"$(\(ProxyConstants.legacyCommandName) shell-init zsh)\"` once to make `\(ProxyConstants.legacyCommandName) set zsh` and `\(ProxyConstants.legacyCommandName) unset zsh` apply immediately in the current zsh shell."
        )
    }

    // MARK: - proxy

    private static func handleProxyCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        let proxyUsage = proxyUsageLines(invocation.programName).joined(separator: "\n")

        guard let action = arguments.first else {
            return try handleInteractiveProxyCommand(invocation)
        }

        guard ["add", "edit", "remove"].contains(action) else {
            throw invocation.usageError("Unknown proxy action \"\(action)\".", proxyUsage)
        }

        if action == "remove" {
            return try handleProxyRemoveCommand(invocation, Array(arguments.dropFirst()))
        }

        let parsed = try parseWriteOptions(Array(arguments.dropFirst()))

        if action == "add" {
            let saved = try ProfileStore.saveProxyProfile(
                parsed.profile,
                context: invocation.context,
                allowOverwrite: parsed.allowOverwrite
            )
            invocation.print("Saved proxy profile \"\(saved.profile.name)\".")
            return 0
        }

        guard !parsed.originalName.isEmpty else {
            throw invocation.usageError("Missing value for --name.", "")
        }

        // Only the options the user passed become updates, mirroring the
        // original hasOwnProperty semantics.
        let updates = ProfileStore.ProxyProfileUpdates(
            name: parsed.profile.name.isEmpty ? nil : parsed.profile.name,
            httpProxy: parsed.providedStateKeys.contains("httpProxy") ? parsed.profile.state.httpProxy : nil,
            httpsProxy: parsed.providedStateKeys.contains("httpsProxy") ? parsed.profile.state.httpsProxy : nil,
            socks5Proxy: parsed.providedStateKeys.contains("socks5Proxy") ? parsed.profile.state.socks5Proxy : nil,
            noProxy: parsed.providedStateKeys.contains("noProxy") ? parsed.profile.state.noProxy : nil
        )
        let saved = try ProfileStore.editProxyProfile(
            parsed.originalName,
            updates: updates,
            context: invocation.context,
            allowOverwrite: parsed.allowOverwrite
        )
        invocation.print("Saved proxy profile \"\(saved.profile.name)\".")
        return 0
    }

    private static func handleProxyRemoveCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        let usage = "Usage: \(invocation.programName) proxy remove <name> [--force]"

        guard let profileName = arguments.first, !profileName.hasPrefix("--") else {
            throw invocation.usageError("", usage)
        }

        let unknownArgs = arguments.dropFirst().filter { $0 != "--force" }
        if !unknownArgs.isEmpty {
            throw invocation.usageError("Unknown option(s): \(unknownArgs.joined(separator: ", "))", usage)
        }

        let force = arguments.contains("--force")
        if !force {
            guard invocation.io.stdinIsTTY() else {
                throw invocation.usageError(
                    "Removing a proxy profile is destructive. Re-run with `\(invocation.programName) proxy remove \(profileName) --force` to remove anyway.",
                    ""
                )
            }

            guard promptConfirm(invocation, "Remove proxy profile \"\(profileName)\"?") else {
                invocation.printError("Aborted.")
                return 1
            }
        }

        let removed = try ProfileStore.removeProxyProfile(profileName, context: invocation.context)
        invocation.print("Removed proxy profile \"\(removed.profile.name)\".")
        return 0
    }

    private static func handleInteractiveProxyCommand(_ invocation: ProxyCLIInvocation) throws -> Int32 {
        guard invocation.io.stdinIsTTY() else {
            throw invocation.usageError(
                "Interactive mode requires a TTY. Use `\(invocation.programName) proxy add`, `proxy edit`, or `proxy remove` instead.",
                ""
            )
        }

        let profiles = ProfileStore.ensureStore(context: invocation.context)
        let items = profiles.map { stored in
            "\(stored.profile.name)  \(ProxyDisplay.describe(stored.profile.state))"
        } + ["Add one proxy"]

        guard let selected = interactiveSelect(
            invocation,
            title: profiles.isEmpty ? "No proxy profiles found.\n" : "Saved proxy profiles.\n",
            items: items
        ) else {
            return 0
        }

        if selected < profiles.count {
            printProfileDetails(invocation, profiles[selected].profile)
            return 0
        }

        guard let name = promptInput(invocation, "Config name", allowEmpty: false),
              let httpProxy = promptInput(invocation, "http_proxy", allowEmpty: true),
              let httpsProxy = promptInput(invocation, "https_proxy", allowEmpty: true),
              let socks5Proxy = promptInput(invocation, "socks5_proxy", allowEmpty: true),
              let noProxy = promptInput(invocation, "no_proxy", allowEmpty: true) else {
            invocation.printError("Aborted.")
            return 1
        }

        var allowOverwrite = false
        if ProfileStore.findProfileByName(profiles, name) != nil {
            guard promptConfirm(invocation, "Proxy profile \"\(name)\" already exists. Override it?") else {
                invocation.printError("Aborted.")
                return 1
            }
            allowOverwrite = true
        }

        var profile = ProxyProfile(name: name, state: .empty)
        profile.state.httpProxy = httpProxy
        profile.state.httpsProxy = httpsProxy
        profile.state.socks5Proxy = socks5Proxy
        profile.state.noProxy = noProxy

        let saved = try ProfileStore.saveProxyProfile(profile, context: invocation.context, allowOverwrite: allowOverwrite)
        invocation.print("Saved proxy profile \"\(saved.profile.name)\".")
        return 0
    }

    // MARK: - list

    private static func handleListCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        let unknownArgs = arguments.filter { $0 != "--json" }
        if !unknownArgs.isEmpty {
            throw invocation.usageError(
                "Unknown option(s): \(unknownArgs.joined(separator: ", "))",
                "Usage: \(invocation.programName) list [--json]"
            )
        }

        let data = ProxyDashboard.collect(context: invocation.context)

        if arguments.contains("--json") {
            invocation.io.writeStdout(String(data: ProxyDashboard.jsonData(data), encoding: .utf8)! + "\n")
            return 0
        }

        invocation.io.writeStdout(ProxyDashboard.renderListTable(data.apps))
        return 0
    }

    // MARK: - set / unset / test

    private static func handleSetCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        guard arguments.count >= 2 else {
            throw invocation.usageError("", "Usage: \(invocation.programName) set <app> <profile-name>")
        }

        let result = try ProxyOperations.configureAppWithProfile(
            context: invocation.context,
            appName: arguments[0],
            profileName: arguments[1]
        )

        let targetSuffix = invocation.context.fileExists(result.way) ? " in \(result.way)" : ""
        invocation.print("Configured \(result.selection.requestedName) with proxy profile \"\(result.profile.name)\"\(targetSuffix).")

        if result.selection.canonicalName == "zsh" || result.selection.canonicalName == ProxyConstants.environmentAppName {
            maybePrintZshShellHookHint(invocation)
        }
        return 0
    }

    private static func handleUnsetCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        guard let appName = arguments.first else {
            throw invocation.usageError("", "Usage: \(invocation.programName) unset <app> [--force]")
        }

        let optionArgs = Array(arguments.dropFirst())
        let unknownArgs = optionArgs.filter { $0 != "--force" }
        if !unknownArgs.isEmpty {
            throw invocation.usageError(
                "Unknown option(s): \(unknownArgs.joined(separator: ", "))",
                "Usage: \(invocation.programName) unset <app> [--force]"
            )
        }

        let interactiveConfirmation: ((ProxyState, String) -> Bool)? = invocation.io.stdinIsTTY()
            ? { current, subjectLabel in
                let warning = "Current \(subjectLabel) proxy settings (\(ProxyDisplay.describe(current))) do not match any saved jpmanager profile. They may have been modified by another app."
                if !promptConfirm(invocation, "\(warning) Unset anyway?") {
                    invocation.printError("Aborted.")
                    return false
                }
                return true
            }
            : nil

        let result = try ProxyOperations.clearAppProxy(
            context: invocation.context,
            appName: appName,
            force: optionArgs.contains("--force"),
            confirmUnsafeUnset: interactiveConfirmation
        )

        if result.aborted {
            return 1
        }

        invocation.print("Unset proxy settings for \(result.selection.requestedName) in \(result.selection.target.wayLabel).")

        if result.selection.canonicalName == "zsh" || result.selection.canonicalName == ProxyConstants.environmentAppName {
            maybePrintZshShellHookHint(invocation)
        }
        return 0
    }

    private static func handleTestCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        guard arguments.count >= 2 else {
            throw invocation.usageError("", "Usage: \(invocation.programName) test <app> <profile-name>")
        }

        let result = try ProxyOperations.testAppProfile(
            context: invocation.context,
            appName: arguments[0],
            profileName: arguments[1]
        )

        if result.mismatches.isEmpty {
            invocation.print("OK: \(result.selection.requestedName) matches proxy profile \"\(result.profile.name)\" in \(result.way).")
            return 0
        }

        invocation.printError(
            "Mismatch: \(result.selection.requestedName) config in \(result.way) does not match proxy profile \"\(result.profile.name)\"."
        )
        for mismatch in result.mismatches {
            invocation.printError(
                "\(mismatch.key.rawValue): expected \(mismatch.expected.isEmpty ? "-" : mismatch.expected), actual \(mismatch.actual.isEmpty ? "-" : mismatch.actual)"
            )
        }
        return 1
    }

    // MARK: - config (interactive selector)

    private static func handleConfigCommand(_ invocation: ProxyCLIInvocation) throws -> Int32 {
        guard invocation.io.stdinIsTTY() else {
            throw invocation.usageError("Interactive mode requires a TTY.", "")
        }

        while true {
            let data = ProxyDashboard.collect(context: invocation.context)
            let items = data.apps.map { "\($0.name): \($0.proxyDisplay)" } + ["Exit"]

            guard let selectedIndex = interactiveSelect(invocation, title: "App proxy configuration\n", items: items),
                  selectedIndex < data.apps.count else {
                return 0
            }

            let app = data.apps[selectedIndex]
            guard !data.profiles.isEmpty else {
                invocation.printError("No proxy profiles found. Run `\(invocation.programName) proxy` first.")
                return 1
            }

            let profileItems = data.profiles.map { "\($0.name)  \($0.proxyDisplay)" }
            guard let profileIndex = interactiveSelect(invocation, title: "Choose a proxy for \(app.name)\n", items: profileItems) else {
                continue
            }

            let selectedProfile = data.profiles[profileIndex]
            let stored = try ProxyOperations.findProxyProfileByName(context: invocation.context, profileName: selectedProfile.name)
            try ProxyOperations.resolveAppSelection(app.name, context: invocation.context).target.apply(stored.state)
            invocation.print("Configured \(app.name) with proxy profile \"\(selectedProfile.name)\".")
        }
    }

    // MARK: - shell hooks

    private static func handleShellInitCommand(_ invocation: ProxyCLIInvocation, _ shellName: String?) throws -> Int32 {
        guard let shellName else {
            invocation.printError("Usage: \(invocation.programName) shell-init <shell>")
            return 1
        }

        guard shellName == "zsh" else {
            invocation.printError("Unknown shell \"\(shellName)\". Available shells: zsh")
            return 1
        }

        invocation.io.writeStdout(ProxyShellCommands.buildZshShellInitScript(invocationCommand: ProxyShellCommands.currentInvocationCommand()))
        return 0
    }

    private static func handleShellApplyCommand(_ invocation: ProxyCLIInvocation, _ shellName: String?) throws -> Int32 {
        guard let shellName else {
            invocation.printError("Usage: \(invocation.programName) shell-apply <shell>")
            return 1
        }

        guard shellName == "zsh" else {
            invocation.printError("Unknown shell \"\(shellName)\". Available shells: zsh")
            return 1
        }

        guard let zshTarget = ProxyTargetLoader.load(context: invocation.context).targets.first(where: { $0.name == "zsh" }) else {
            invocation.printError("Target \"zsh\" is not available.")
            return 1
        }

        invocation.io.writeStdout(ProxyShellCommands.buildZshCurrentShellCommands(zshTarget.currentState()))
        return 0
    }

    // MARK: - login

    private static func handleLoginCommand(_ invocation: ProxyCLIInvocation, _ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw invocation.usageError("", "Usage: \(invocation.programName) login <enable|disable|status> [--json]")
        }

        let wantsJSON = arguments.contains("--json")

        switch action {
        case "enable":
            if let error = ProxyLoginService.enable() {
                invocation.printError("Failed to enable launch at login: \(error)")
                return 1
            }
            invocation.print("Launch at login enabled.")
            return 0

        case "disable":
            if let error = ProxyLoginService.disable() {
                invocation.printError("Failed to disable launch at login: \(error)")
                return 1
            }
            invocation.print("Launch at login disabled.")
            return 0

        case "status":
            let status = ProxyLoginService.currentStatus()
            if wantsJSON {
                let payload: [String: Any] = ["enabled": status == .enabled, "status": status.rawValue]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                invocation.io.writeStdout(String(data: data, encoding: .utf8)! + "\n")
            } else {
                invocation.print("Launch at login: \(status.rawValue)")
            }
            return 0

        default:
            throw invocation.usageError(
                "Unknown login action \"\(action)\".",
                "Usage: \(invocation.programName) login <enable|disable|status> [--json]"
            )
        }
    }
}
