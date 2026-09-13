# JMacTool

A single macOS menu bar utility that bundles everyday power tools:

- **Clear Screen** — covers every display with a black curtain, swallows keyboard/trackpad input, and locks the Touch Bar so the screen can be wiped physically. Click **Restore System** to exit.
- **Input Change** — switches to an English keyboard layout whenever the focused app or window changes, waiting for keyboard activity to settle so terminal input and shortcuts are not interrupted.
- **Proxy** — a native port of [jpmanager](https://github.com/j7ur8/jpmanager): manage proxy profiles and apply them to npm, git, pip, curl, wget, yarn, maven, gradle, conda, go, and your zsh environment. Fully compatible with existing `~/.jpmanager` data.

Requires macOS 13+. Build with Swift Package Manager (`swift build`, `./build.sh` for the app bundle).

## Proxy Management

Proxy profiles support `http_proxy`, `https_proxy`, `socks5_proxy`, and `no_proxy`. Profiles are stored one per file in `~/.jpmanager/profiles/`:

```yaml
# ~/.jpmanager/profiles/office.yaml
version: 1
profile:
  name: office
  http_proxy: http://127.0.0.1:7890
  https_proxy: http://127.0.0.1:7890
  socks5_proxy: ""
  no_proxy: localhost,127.0.0.1
```

### Built-In Targets

| App | Config file | Notes |
| --- | --- | --- |
| `environment` | `~/.zshrc` | shared shell proxy variables; `brew`, `gem`, `bundle`, `ruby` are aliases |
| `npm` | `~/.npmrc` | |
| `git` | `~/.gitconfig` | `http.proxy` / `https.proxy` |
| `pip` | `~/.config/pip/pip.conf` | |
| `curl` | `~/.curlrc` | |
| `wget` | `~/.wgetrc` | toggles `use_proxy` |
| `zsh` | `~/.zshrc` | managed `# >>> jpmanager proxy >>>` block; hidden from the dashboard |
| `maven` | `~/.m2/settings.xml` | managed `<proxy id="jpmanager">` node |
| `gradle` | `~/.gradle/gradle.properties` | `systemProp.*` host/port/user entries |
| `yarn` | `~/.yarnrc` | |
| `conda` | `~/.condarc` | `proxy_servers` section |
| `go` | `~/.config/go/env` | `HTTP_PROXY`, `ALL_PROXY`, ... |

Extra file-backed targets (or overrides of the built-ins, merged by `name`) can be added in `~/.jpmanager/targets/<target-name>.yaml`:

```yaml
version: 1
target:
  name: npm
  wayLabel: ~/.npmrc
  path: ~/.npmrc
  handler: ini-root
```

Supported v1 handlers: `ini-root`, `ini-section`, `managed-shell-env`, `line-kv`, `yarnrc`, `maven-settings`, `condarc-proxy-servers`.

### Commands

```bash
JMacTool proxy                       # interactive profile browser (TTY)
JMacTool proxy add --name <name> [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]
JMacTool proxy edit --name <existing-name> [--rename <new-name>] [--http-proxy <url>] [--https-proxy <url>] [--socks5-proxy <url>] [--no-proxy <value>] [--force]
JMacTool proxy remove <name> [--force]
JMacTool list [--json]
JMacTool set <app> <profile-name>
JMacTool unset <app> [--force]
JMacTool test <app> <profile-name>   # exit 0 on match, 1 on mismatch
JMacTool config                      # interactive app selector (TTY)
JMacTool shell-init zsh              # prints a zsh wrapper for instant session updates
JMacTool shell-apply zsh             # prints export/unset lines for the current session
JMacTool login <enable|disable|status> [--json]
JMacTool install-cli                 # installs /usr/local/bin/jpmanager shim
```

`unset zsh` / `unset environment` refuses to clear proxy settings that do not match any saved profile unless `--force` is passed (or confirmed interactively in a TTY).

The historical `jpmanager` command keeps working: the menu bar item **Proxy → Install "jpmanager" Command…** (or `JMacTool install-cli`) writes a `/usr/local/bin/jpmanager` shim that forwards to this binary, so existing scripts and shell hooks need no changes.

To make `set zsh` / `unset zsh` apply immediately in the current shell:

```bash
eval "$(jpmanager shell-init zsh)"
```

Add that line to `~/.zshrc` to persist it.

### Menu Bar

The JMacTool status-item menu shows the proxy manager at the top level:

- a **Managed Apps** section: every managed app with its matched profile, and a submenu to switch it to any saved profile (or `None`)
- a **Profiles** section: saved profiles with their values and an `Edit…` action, plus `Add Profile…`
- a **Launch at Login** toggle backed by `SMAppService`
- a **Proxy** submenu that keeps only the “jpmanager” command installer

## Project Layout

```
Sources/JMacToolApp/    executable entry (GUI, or CLI when invoked with arguments)
Sources/JMacToolCore/
  App/                  application delegate, constants, launcher
  Cleaning/             Clear Screen feature (windows, keyboard/Touch Bar suppression)
  InputChange/          focus monitoring, AX window identity, input source switching
  Menu/                 status-item menus and the profile form window
  Proxy/                native port of the jpmanager engine (store, targets, handlers, CLI)
  Support/              shared CGEventTap helper
Tests/JMacToolCoreTests/ XCTest coverage for the proxy engine and YAML/INI formats
```

## Build

```bash
swift build            # debug build
swift test             # run the test suite
./build.sh             # signed dist/JMacTool.app (universal binary: arm64 + x86_64)
```

The CLI lives in the same binary, so `dist/JMacTool.app/Contents/MacOS/JMacTool list --json` works from a shell as well.

### Installing a Release

Download `JMacTool-<tag>-macos.zip` from [Releases](https://github.com/j7ur8/JMacTool/releases), unpack it, and move `JMacTool.app` to `/Applications`. The binaries are ad-hoc signed, so macOS Gatekeeper may block the first launch — right-click the app and choose **Open** once, or clear the quarantine flag:

```bash
xattr -cr /Applications/JMacTool.app
```
