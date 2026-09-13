import Foundation

/// zsh shell integration helpers (`shell-init`/`shell-apply`) ported from
/// jpmanager's shell-commands module.
enum ProxyShellCommands {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Absolute path of the currently running JMacTool binary, used by the
    /// generated shell wrapper.
    static func currentInvocationCommand() -> String {
        if let url = Bundle.main.executableURL, !url.path.isEmpty {
            return shellQuote(url.path)
        }

        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else {
            return shellQuote(ProxyConstants.legacyCommandName)
        }

        let fileManager = FileManager.default
        var resolved = argv0
        if !argv0.hasPrefix("/") {
            resolved = fileManager.currentDirectoryPath + "/" + argv0
        }
        if fileManager.fileExists(atPath: resolved) {
            return shellQuote(resolved)
        }
        return shellQuote(ProxyConstants.legacyCommandName)
    }

    static func buildZshCurrentShellCommands(_ state: ProxyState) -> String {
        let httpsValue = state.httpsProxy.isEmpty ? state.httpProxy : state.httpsProxy
        let entries: [(String, String)] = [
            ("http_proxy", state.httpProxy),
            ("https_proxy", httpsValue),
            ("HTTP_PROXY", state.httpProxy),
            ("HTTPS_PROXY", httpsValue),
            ("ALL_PROXY", state.socks5Proxy),
            ("all_proxy", state.socks5Proxy),
            ("no_proxy", state.noProxy),
            ("NO_PROXY", state.noProxy)
        ]

        return entries
            .map { key, value -> String in
                value.isEmpty ? "unset \(key)" : "export \(key)=\(shellQuote(value))"
            }
            .joined(separator: "\n") + "\n"
    }

    static func buildZshShellInitScript(invocationCommand: String) -> String {
        [
            "jpmanager() {",
            "  local exit_code",
            "  JPMANAGER_ZSH_SHELL_HOOK=1 \(invocationCommand) \"$@\"",
            "  exit_code=$?",
            "  if [[ $exit_code -eq 0 ]]; then",
            "    if [[ \"$1\" == \"set\" && \"$2\" == \"zsh\" ]]; then",
            "      eval \"$(\(invocationCommand) shell-apply zsh)\"",
            "    elif [[ \"$1\" == \"unset\" && \"$2\" == \"zsh\" ]]; then",
            "      eval \"$(\(invocationCommand) shell-apply zsh)\"",
            "    fi",
            "  fi",
            "  return $exit_code",
            "}",
            ""
        ].joined(separator: "\n")
    }
}
