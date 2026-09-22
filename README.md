# JMacTool

A single macOS menu bar utility that bundles everyday power tools:

- **Clear Screen** — covers every display with a black curtain, swallows keyboard/trackpad input, and locks the Touch Bar so the screen can be wiped physically. Click **Restore System** to exit.
- **Input Change** — switches to an English keyboard layout whenever the focused app or window changes, waiting for keyboard activity to settle so terminal input and shortcuts are not interrupted.
- **Option+IJKL → Arrow Keys** — system-wide arrow-key navigation on the letter keys (Option+N/M jump by word), a built-in replacement for the common Karabiner rule.
- **Proxy** — a native port of [jpmanager](https://github.com/j7ur8/jpmanager): manage proxy profiles and apply them to npm, git, pip, curl, wget, yarn, maven, gradle, conda, go, your zsh environment, and the macOS system proxy. Fully compatible with existing `~/.jpmanager` data.

Requires macOS 13+. Build with Swift Package Manager (`swift build`, `./build.sh` for the app bundle). The bundle is universal: Apple silicon Macs run the native arm64 slice, Intel Macs the x86_64 one.

## Updates

The menu has a **Check for Updates…** item and JMacTool also checks the [GitHub Releases](https://github.com/j7ur8/JMacTool/releases) feed once at launch. When a newer release is found you can install it in place: the app is downloaded, its code signature is verified, and a small detached script replaces the bundle and relaunches it. No Gatekeeper prompt appears because the download is not quarantined.

Automatic replacement requires running from `JMacTool.app` (not a raw `swift build` binary).

### Keeping permissions across updates

macOS binds Accessibility/Input Monitoring grants to the app's code-signing identity. Ad-hoc signatures change on every build, which is why permissions used to reset. Run this once on your Mac to create a fixed self-signed identity:

```bash
./Scripts/setup-code-signing.sh
```

After that, local builds sign with `JMacTool Local` automatically, and one final re-grant of the permissions is all you will ever need. To keep CI release artifacts on the same identity, add the two GitHub repository secrets the script prints (`MACOS_SIGNING_P12`, `MACOS_SIGNING_PASSWORD`); without them CI falls back to ad-hoc and updates will ask for permissions again.

## Option+IJKL → Arrow Keys

Toggle **Option+IJKL → Arrow Keys** in the menu to rewrite keyboard events system-wide:

| Keys | Result |
| --- | --- |
| `Option + I` / `J` / `K` / `L` | plain up / left / down / right |
| `Option + N` / `M` | `Option + ←` / `Option + →` (word-wise jump) |
| combos | other modifiers (Shift/Cmd/…) are preserved |

The toggle needs the app in System Settings → Privacy & Security → **Accessibility** (and Input Monitoring for reliable event handling) and is remembered across launches. If Karabiner-Elements is also running the same rule, disable one of the two to keep a single source of truth.

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
| `system` | macOS Network Proxies | applies via `networksetup` on the default-route service; `no_proxy` becomes the bypass domain list |

Extra file-backed targets (or overrides of the built-ins, merged by `name`) can be added in `~/.jpmanager/targets/<target-name>.yaml`:

```yaml
version: 1
target:
  name: npm
  wayLabel: ~/.npmrc
  path: ~/.npmrc
  handler: ini-root
```

Supported v1 handlers: `ini-root`, `ini-section`, `managed-shell-env`, `line-kv`, `yarnrc`, `maven-settings`, `condarc-proxy-servers`, `system-proxy`.

### Commands

The command line is the app binary itself, so `JMacTool` below stands for the bundled executable:

```bash
JMACTOOL=/Applications/JMacTool.app/Contents/MacOS/JMacTool
```

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
```

`unset zsh` / `unset environment` refuses to clear proxy settings that do not match any saved profile unless `--force` is passed (or confirmed interactively in a TTY).

Nothing is installed outside the bundle. If existing scripts call the historical `jpmanager` name, point your own alias or symlink at the bundled binary:

```bash
alias jpmanager="$JMACTOOL"          # add to ~/.zshrc to make it permanent
```

To make `set zsh` / `unset zsh` apply immediately in the current shell:

```bash
eval "$("$JMACTOOL" shell-init zsh)"
```

Add that line to `~/.zshrc` to persist it.

### Menu Bar

The JMacTool status-item menu shows the proxy manager at the top level:

- a **Managed Apps** section: every managed app with its matched profile, and a submenu to switch it to any saved profile (or `None`)
- a **Profiles** section: saved profiles with their values and an `Edit…` action, plus `Add Profile…`
- a **Launch at Login** toggle backed by `SMAppService`, grouped with `Check for Updates…`

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

`./build.sh` cross-compiles both slices and aborts if the bundle ends up missing one, so Apple silicon Macs never silently fall back to Rosetta 2. To build a subset while iterating locally, set `JMACTOOL_ARCHS`, e.g. `JMACTOOL_ARCHS=arm64 ./build.sh`.

The CLI is the same binary, so `dist/JMacTool.app/Contents/MacOS/JMacTool list --json` runs the commands above straight from a build.

### Installing a Release

Download `JMacTool-<tag>-macos.zip` from [Releases](https://github.com/j7ur8/JMacTool/releases), unpack it, and move `JMacTool.app` to `/Applications`. The binaries are signed with the self-signed `JMacTool Local` certificate and are not notarized, so Gatekeeper blocks the first launch (the error surfaces as `-10810` when launched with `open`). The reliable bypass is clearing the quarantine flag that the downloaded zip carries:

```bash
xattr -cr /Applications/JMacTool.app
open /Applications/JMacTool.app
```

Alternatively, launch once via **System Settings → Privacy & Security → Open Anyway**. The right-click → **Open** bypass was removed in macOS 15. This is only needed on first install; in-app updates download without the quarantine flag, so Gatekeeper never sees them.
