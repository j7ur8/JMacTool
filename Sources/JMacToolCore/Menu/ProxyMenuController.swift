import AppKit
import ServiceManagement

/// Owns the proxy-related sections of the JMacTool main menu: managed apps
/// with per-app profile switching and saved profiles are rendered directly in
/// the main menu, Launch at Login is a standalone item, and the Proxy submenu
/// keeps only the "jpmanager" CLI installer.
@MainActor
final class ProxyMenuController: NSObject {
    private let context: ProxyFileContext
    private var profileFormWindow: ProfileFormWindow?
    private weak var mainMenu: NSMenu?
    private weak var quitItem: NSMenuItem?
    private var dynamicItems: [NSMenuItem] = []

    init(context: ProxyFileContext = .live) {
        self.context = context
    }

    /// Registers the dynamic proxy sections that live directly in the main
    /// menu, inserted before the Quit item.
    func install(into menu: NSMenu, before quitItem: NSMenuItem) {
        mainMenu = menu
        self.quitItem = quitItem
        refreshDynamicSection()
    }

    /// Rebuilds apps/profiles state; called every time the menu opens.
    func refreshDynamicSection() {
        guard let mainMenu, let quitItem else {
            return
        }

        for item in dynamicItems {
            mainMenu.removeItem(item)
        }

        dynamicItems = makeDynamicItems()
        let quitIndex = mainMenu.index(of: quitItem)
        guard quitIndex != NSNotFound else {
            return
        }

        for (offset, item) in dynamicItems.enumerated() {
            mainMenu.insertItem(item, at: quitIndex + offset)
        }
    }

    // MARK: - Menu building

    private func makeDynamicItems() -> [NSMenuItem] {
        let data = ProxyDashboard.collect(context: context)
        let profiles = ProfileStore.ensureStore(context: context)

        var items: [NSMenuItem] = []

        items.append(sectionHeader("Managed Apps"))
        if profiles.isEmpty {
            items.append(disabledItem("No proxy profiles saved yet"))
        }
        for app in data.apps {
            let item = NSMenuItem(title: "\(app.name): \(app.alias)", action: nil, keyEquivalent: "")
            item.submenu = makeAppSubmenu(app: app, profiles: profiles)
            items.append(item)
        }

        items.append(.separator())
        items.append(sectionHeader("Profiles"))
        for stored in profiles {
            let item = NSMenuItem(title: stored.profile.name, action: nil, keyEquivalent: "")
            item.submenu = makeProfileSubmenu(profile: stored.profile)
            items.append(item)
        }
        let addItem = NSMenuItem(title: "Add Profile…", action: #selector(addProfile(_:)), keyEquivalent: "")
        addItem.target = self
        items.append(addItem)

        items.append(.separator())
        items.append(makeLaunchAtLoginItem())

        items.append(.separator())
        items.append(makeProxyItem())

        items.append(.separator())
        return items
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeAppSubmenu(app: ProxyDashboard.DashboardApp, profiles: [StoredProfile]) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(disabledItem("Proxy: \(app.proxyDisplay)"))
        submenu.addItem(disabledItem("Method: \(app.method.label)"))
        if !app.usedBy.isEmpty {
            submenu.addItem(disabledItem("Used by: \(app.usedBy.joined(separator: ", "))"))
        }
        submenu.addItem(.separator())

        for stored in profiles {
            let item = NSMenuItem(
                title: stored.profile.name,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ["app": app.name, "profile": stored.profile.name]
            item.state = app.matchedProfileName == stored.profile.name ? .on : .off
            submenu.addItem(item)
        }

        if !profiles.isEmpty {
            submenu.addItem(.separator())
        }

        let noneItem = NSMenuItem(title: "None", action: #selector(selectProfile(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = ["app": app.name, "profile": ""]
        noneItem.state = app.alias == "None" ? .on : .off
        submenu.addItem(noneItem)

        return submenu
    }

    private func makeProfileSubmenu(profile: ProxyProfile) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        submenu.addItem(disabledItem("http_proxy: \(profile.state.httpProxy.isEmpty ? "-" : profile.state.httpProxy)"))
        submenu.addItem(disabledItem("https_proxy: \(profile.state.httpsProxy.isEmpty ? "-" : profile.state.httpsProxy)"))
        submenu.addItem(disabledItem("socks5_proxy: \(profile.state.socks5Proxy.isEmpty ? "-" : profile.state.socks5Proxy)"))
        submenu.addItem(disabledItem("no_proxy: \(profile.state.noProxy.isEmpty ? "-" : profile.state.noProxy)"))
        submenu.addItem(.separator())

        let editItem = NSMenuItem(title: "Edit…", action: #selector(editProfile(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = profile.name
        submenu.addItem(editItem)

        return submenu
    }

    private func makeLaunchAtLoginItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = ProxyLoginService.isEnabled() ? .on : .off
        return item
    }

    private func makeProxyItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Proxy", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let installItem = NSMenuItem(
            title: "Install “jpmanager” Command…",
            action: #selector(installCLI(_:)),
            keyEquivalent: ""
        )
        installItem.target = self
        submenu.addItem(installItem)

        item.submenu = submenu
        return item
    }

    // MARK: - Actions

    private func runOperation(_ block: () throws -> Void) {
        do {
            try block()
        } catch let error as ProxyEngineError {
            presentError(message: error.message)
        } catch {
            presentError(message: String(describing: error))
        }
    }

    private func presentError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Proxy"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let app = info["app"],
              let profileName = info["profile"] else {
            return
        }

        runOperation {
            if profileName.isEmpty {
                _ = try ProxyOperations.clearAppProxy(
                    context: context,
                    appName: app,
                    force: true
                )
            } else {
                _ = try ProxyOperations.configureAppWithProfile(
                    context: context,
                    appName: app,
                    profileName: profileName
                )
            }
        }
    }

    @objc private func addProfile(_ sender: NSMenuItem) {
        openProfileForm(existing: nil)
    }

    @objc private func editProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else {
            return
        }

        let profiles = ProfileStore.ensureStore(context: context)
        guard let stored = ProfileStore.findProfileByName(profiles, name) else {
            presentError(message: "Proxy profile \"\(name)\" does not exist.")
            return
        }

        openProfileForm(
            existing: ProfileFormWindow.Fields(
                name: stored.profile.name,
                httpProxy: stored.profile.state.httpProxy,
                httpsProxy: stored.profile.state.httpsProxy,
                socks5Proxy: stored.profile.state.socks5Proxy,
                noProxy: stored.profile.state.noProxy
            ),
            originalName: name
        )
    }

    private func openProfileForm(existing: ProfileFormWindow.Fields?, originalName: String? = nil) {
        let window = ProfileFormWindow(existing: existing) { [weak self] fields in
            self?.saveProfile(fields: fields, originalName: originalName)
        }
        profileFormWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func saveProfile(fields: ProfileFormWindow.Fields, originalName: String?) {
        var profile = ProxyProfile(name: fields.name, state: .empty)
        profile.state.httpProxy = fields.httpProxy
        profile.state.httpsProxy = fields.httpsProxy
        profile.state.socks5Proxy = fields.socks5Proxy
        profile.state.noProxy = fields.noProxy

        func runSave(allowOverwrite: Bool) -> Bool {
            do {
                if let originalName {
                    _ = try ProfileStore.editProxyProfile(
                        originalName,
                        updates: ProfileStore.ProxyProfileUpdates(
                            name: fields.name,
                            httpProxy: fields.httpProxy,
                            httpsProxy: fields.httpsProxy,
                            socks5Proxy: fields.socks5Proxy,
                            noProxy: fields.noProxy
                        ),
                        context: context,
                        allowOverwrite: allowOverwrite
                    )
                } else {
                    _ = try ProfileStore.saveProxyProfile(profile, context: context, allowOverwrite: allowOverwrite)
                }
                profileFormWindow?.close()
                profileFormWindow = nil
                refreshDynamicSection()
                return true
            } catch let error as ProxyEngineError {
                if !allowOverwrite,
                   error.message.contains("already exists") {
                    let alert = NSAlert()
                    alert.messageText = "Proxy profile \"\(fields.name)\" already exists."
                    alert.informativeText = "Override the existing profile?"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Override")
                    alert.addButton(withTitle: "Cancel")

                    if alert.runModal() == .alertFirstButtonReturn {
                        return runSave(allowOverwrite: true)
                    }
                    return false
                }

                presentError(message: error.message)
                return false
            } catch {
                presentError(message: String(describing: error))
                return false
            }
        }

        _ = runSave(allowOverwrite: false)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if ProxyLoginService.isEnabled() {
            if let error = ProxyLoginService.disable() {
                presentError(message: "Failed to disable launch at login: \(error)")
            }
        } else if let error = ProxyLoginService.enable() {
            presentError(message: "Failed to enable launch at login: \(error)\n\nMake sure JMacTool.app is inside /Applications.")
        }
        sender.state = ProxyLoginService.isEnabled() ? .on : .off
    }

    @objc private func installCLI(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Install the “jpmanager” command"
        alert.informativeText = "Creates \(ProxyCLIInstaller.shimPath) so terminal commands and the zsh shell hook keep working. Writing to /usr/local/bin may require administrator permissions."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            switch try ProxyCLIInstaller.install() {
            case .alreadyInstalled:
                presentError(message: "The \(ProxyCLIInstaller.shimPath) command shim is already up to date.")
            case .installed, .replaced:
                let done = NSAlert()
                done.messageText = "Command installed"
                done.informativeText = "Run `eval \"$(jpmanager shell-init zsh)\"` in a shell to wire up instant proxy switching."
                done.alertStyle = .informational
                done.runModal()
            }
        } catch let error as ProxyEngineError {
            presentError(message: error.message)
        } catch {
            presentError(message: "Failed to install \(ProxyCLIInstaller.shimPath): \(error.localizedDescription)\n\nCreate /usr/local/bin with sudo or run `JMacTool install-cli` from a shell with the right permissions.")
        }
    }
}
