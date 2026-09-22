import AppKit
import ServiceManagement

/// Owns the proxy-related sections of the JMacTool main menu: managed apps
/// with per-app profile switching and saved profiles are rendered directly in
/// the main menu, and Launch at Login and Check for Updates share one group.
/// The command line ships inside the app bundle itself, so no shell installer
/// is offered here.
@MainActor
final class ProxyMenuController: NSObject {
    private let context: ProxyFileContext
    /// The one form window this controller ever shows; re-targeted in place for
    /// every Add/Edit request so duplicates are impossible.
    private(set) var profileFormWindow: ProfileFormWindow?
    private weak var mainMenu: NSMenu?
    private weak var quitItem: NSMenuItem?
    private weak var updatesItem: NSMenuItem?
    private weak var launchAtLoginView: CheckmarkMenuItemView?
    private var dynamicItems: [NSMenuItem] = []

    init(context: ProxyFileContext = .live) {
        self.context = context
    }

    /// Registers the dynamic proxy sections that live directly in the main
    /// menu, inserted before the Quit item. `updatesItem` is placed in the
    /// same group as Launch at Login.
    func install(into menu: NSMenu, before quitItem: NSMenuItem, updatesItem: NSMenuItem? = nil) {
        mainMenu = menu
        self.quitItem = quitItem
        self.updatesItem = updatesItem
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
        if let updatesItem {
            items.append(updatesItem)
        }

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
        let item = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
        let view = CheckmarkMenuItemView(title: "Launch at Login")
        view.setEnabledState(ProxyLoginService.isEnabled())
        view.onClick = { [weak self] in
            self?.toggleLaunchAtLogin()
        }
        item.view = view
        launchAtLoginView = view
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
        let window = profileFormWindow ?? makeProfileFormWindow()
        profileFormWindow = window
        window.present(existing: existing) { [weak self] fields in
            self?.saveProfile(fields: fields, originalName: originalName)
        }
        // Closing the form hides the app again (see `profileFormDidClose`), so
        // undo that first; unhide is a no-op while the app is visible.
        NSApp.unhide(nil)
        // The click that reached this action is the user gesture AppKit needs
        // to activate a status-item app; without it the window cannot become key
        // and the text fields would not accept typing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The action still runs while the status menu is tracking, which can
        // swallow the activation request and leave the form behind the frontmost
        // app. Re-assert it once the menu has closed; this is a no-op whenever
        // the synchronous attempt already worked.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.profileFormWindow === window else {
                return
            }

            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func makeProfileFormWindow() -> ProfileFormWindow {
        ProfileFormWindow { [weak self] in
            self?.profileFormDidClose()
        }
    }

    private func profileFormDidClose() {
        profileFormWindow = nil
        refreshDynamicSection()

        // A windowless accessory app keeps keyboard focus, which would swallow
        // whatever the user types next; hand activation back once the form is
        // gone.
        if NSApp.isActive, NSApp.windows.isEmpty {
            NSApp.hide(nil)
        }
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
                // Closing runs `profileFormDidClose`, which clears the reference
                // and refreshes the menu sections.
                profileFormWindow?.close()
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

    @objc private func toggleLaunchAtLogin() {
        if ProxyLoginService.isEnabled() {
            if let error = ProxyLoginService.disable() {
                presentError(message: "Failed to disable launch at login: \(error)")
            }
        } else if let error = ProxyLoginService.enable() {
            presentError(message: "Failed to enable launch at login: \(error)\n\nMake sure JMacTool.app is inside /Applications.")
        }
        launchAtLoginView?.setEnabledState(ProxyLoginService.isEnabled())
    }
}
