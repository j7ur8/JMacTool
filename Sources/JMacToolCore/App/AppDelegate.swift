import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let cleaningModeController = CleaningModeController()
    private let windowMonitor = FocusChangeMonitor()
    private let arrowKeyMapper = ArrowKeyMapper()
    private let proxyMenuController = ProxyMenuController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clearScreenMenuItem = NSMenuItem(title: "Clear Screen", action: #selector(clearScreen), keyEquivalent: "")
    private let inputChangeMenuItem = NSMenuItem()
    private let inputChangeView = CheckmarkMenuItemView(title: "Input Change")
    private let arrowKeyMenuItem = NSMenuItem()
    private let arrowKeyMenuItemView = CheckmarkMenuItemView(title: "Option+IJKL → Arrow Keys")
    private let updateController = AppUpdater()
    private let checkUpdatesMenuItem = NSMenuItem(
        title: "Check for Updates…",
        action: #selector(checkForUpdates(_:)),
        keyEquivalent: ""
    )
    private var hasShownArrowKeyAccessibilityAlert = false
    private let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
    private var hasShownAccessibilityAlert = false
    private var hasShownInputMonitoringAlert = false
    private var restoredInputChangePreference: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.isAutomaticCustomizeTouchBarMenuItemEnabled = false

        configureStatusItem()
        configureControllers()
        restoreInputChangeState()
        validateInputChangeConfigurationOnLaunch()
        restoreArrowKeyMappingState()
        refreshUI()
        scheduleAutomaticUpdateCheck()
    }

    /// Silent update check on launch; only app-bundle installs participate
    /// (the raw `swift build` binary has no Info.plist version).
    private func scheduleAutomaticUpdateCheck() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { await self?.runUpdateCheck(userInitiated: false) }
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        Task { await runUpdateCheck(userInitiated: true) }
    }

    private func runUpdateCheck(userInitiated: Bool) async {
        guard !updateController.isBusy else {
            return
        }

        if userInitiated {
            checkUpdatesMenuItem.title = "Checking for Updates…"
            checkUpdatesMenuItem.isEnabled = false
        }
        defer {
            if userInitiated {
                checkUpdatesMenuItem.title = "Check for Updates…"
                checkUpdatesMenuItem.isEnabled = true
            }
        }

        do {
            guard let update = try await UpdateChecker.fetchLatestRelease() else {
                if userInitiated {
                    let alert = NSAlert()
                    alert.messageText = "You're up to date"
                    alert.informativeText = "JMacTool \(UpdateChecker.currentAppVersion()) is the latest version."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                return
            }

            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "JMacTool \(update.version) is available"
            alert.informativeText = "Install and relaunch now? The new version replaces the app in place and restarts automatically.\n\nPermissions (Accessibility, Input Monitoring) are preserved when the app is signed with the stable identity."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install & Relaunch")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }

            try await updateController.downloadAndPrepareInstall(update)
            NSApp.terminate(nil)
        } catch {
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "Update failed"
                alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaningModeController.stop()
        windowMonitor.setEnabled(false)
        arrowKeyMapper.setEnabled(false)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = makeStatusImage()
            button.imagePosition = .imageOnly
            button.toolTip = AppConstants.appName
        }

        clearScreenMenuItem.target = self
        checkUpdatesMenuItem.target = self
        quitMenuItem.target = self

        inputChangeView.onClick = { [weak self] in
            self?.toggleInputChange()
        }
        inputChangeMenuItem.view = inputChangeView

        arrowKeyMenuItemView.onClick = { [weak self] in
            self?.toggleArrowKeyMapping()
        }
        arrowKeyMenuItem.view = arrowKeyMenuItemView

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(clearScreenMenuItem)
        menu.addItem(inputChangeMenuItem)
        menu.addItem(arrowKeyMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)
        proxyMenuController.install(into: menu, before: quitMenuItem, updatesItem: checkUpdatesMenuItem)
        statusItem.menu = menu
    }

    private func configureControllers() {
        cleaningModeController.onStateChange = { [weak self] _ in
            self?.refreshUI()
        }
    }

    private func restoreInputChangeState() {
        let storedValue = UserDefaults.standard.object(forKey: AppConstants.inputChangeEnabledDefaultsKey) as? Bool
        restoredInputChangePreference = storedValue
        windowMonitor.setEnabled(storedValue ?? true)
    }

    private func validateInputChangeConfigurationOnLaunch() {
        guard windowMonitor.isEnabled else {
            return
        }

        guard restoredInputChangePreference == true else {
            return
        }

        if windowMonitor.hasAccessibilityAccess {
            maybeRequestInputMonitoringForInputChange()
            windowMonitor.switchToEnglishNow()
            return
        }

        showInputChangeAccessibilityAlertIfNeeded()
        windowMonitor.requestAccessibilityAccessIfNeeded()
    }

    private func refreshUI() {
        let isCleaning = cleaningModeController.isRunning
        NSApp.setActivationPolicy(isCleaning ? .regular : .accessory)
        let tooltip = inputChangeTooltip()
        inputChangeView.update(isEnabled: windowMonitor.isEnabled, toolTip: tooltip)
        inputChangeMenuItem.toolTip = tooltip
        let mappingActive = arrowKeyMapper.isEnabled && arrowKeyMapper.isTapRunning
        arrowKeyMenuItemView.update(
            isEnabled: mappingActive,
            toolTip: mappingActive
                ? "Option+I/J/K/L are arrow keys; Option+N/M jump by word."
                : "Option+IJKL arrow-key mapping is inactive (disabled, permissions missing, or the app was rebuilt)."
        )

        updateStatusItemImage()
    }

    /// The status icon does not track cleaning mode: the curtain and the hidden
    /// menu bar cover it for the whole session, so a cleaning symbol would never
    /// be on screen where it mattered.
    private func updateStatusItemImage() {
        guard let button = statusItem.button else {
            return
        }

        button.image = makeStatusImage()
        button.title = button.image == nil ? "JT" : ""
    }

    private func makeStatusImage() -> NSImage? {
        let symbolNames = ["display", "rectangle"]

        for symbolName in symbolNames {
            if let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: AppConstants.appName
            ) {
                image.isTemplate = true
                return image
            }
        }

        return nil
    }

    private func restoreArrowKeyMappingState() {
        let stored = UserDefaults.standard.object(forKey: AppConstants.arrowKeyMappingEnabledDefaultsKey) as? Bool ?? false
        guard stored else {
            return
        }

        if arrowKeyMapper.hasAccessibilityAccess {
            arrowKeyMapper.setEnabled(true)
            if !arrowKeyMapper.isTapRunning {
                arrowKeyMapper.setEnabled(false)
                showArrowKeyTapFailureAlert()
            }
        } else {
            showArrowKeyAccessibilityAlertIfNeeded()
            arrowKeyMapper.requestAccessibilityAccessIfNeeded()
        }
    }

    private func showArrowKeyTapFailureAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Option+IJKL → Arrow Keys 未生效"
        alert.informativeText = "缺少权限：\(arrowKeyMapper.missingPermissionDescription ?? "未知原因")。授权后重新打开开关即可。注意：映射仅在 JMacTool 运行期间有效。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func toggleArrowKeyMapping() {
        let next = !arrowKeyMapper.isEnabled

        if next {
            if !arrowKeyMapper.hasAccessibilityAccess {
                showArrowKeyAccessibilityAlertIfNeeded()
                arrowKeyMapper.requestAccessibilityAccessIfNeeded()
            }

            if !arrowKeyMapper.hasInputMonitoringAccess {
                arrowKeyMapper.requestInputMonitoringAccessIfNeeded()
            }

            arrowKeyMapper.setEnabled(true)
        } else {
            arrowKeyMapper.setEnabled(false)
        }

        if arrowKeyMapper.isEnabled, !arrowKeyMapper.isTapRunning {
            arrowKeyMapper.setEnabled(false)
            showArrowKeyTapFailureAlert()
        }

        UserDefaults.standard.set(arrowKeyMapper.isEnabled, forKey: AppConstants.arrowKeyMappingEnabledDefaultsKey)
        refreshUI()
    }

    private func showArrowKeyAccessibilityAlertIfNeeded() {
        guard !hasShownArrowKeyAccessibilityAlert else {
            return
        }

        hasShownArrowKeyAccessibilityAlert = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "Option+IJKL → Arrow Keys rewrites keyboard events system-wide, which requires JMacTool in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func clearScreen() {
        cleaningModeController.requestInputMonitoringAccessIfNeeded()
        cleaningModeController.start()
    }

    private func toggleInputChange() {
        let nextValue = !windowMonitor.isEnabled

        if nextValue {
            if !windowMonitor.hasAccessibilityAccess {
                showInputChangeAccessibilityAlertIfNeeded()
                windowMonitor.requestAccessibilityAccessIfNeeded()
            }

            maybeRequestInputMonitoringForInputChange()

            windowMonitor.setEnabled(true)
            windowMonitor.switchToEnglishNow()
        } else {
            windowMonitor.setEnabled(false)
        }

        restoredInputChangePreference = nextValue
        UserDefaults.standard.set(nextValue, forKey: AppConstants.inputChangeEnabledDefaultsKey)
        refreshUI()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        proxyMenuController.refreshDynamicSection()
    }

    private func showInputChangeAccessibilityAlertIfNeeded() {
        guard !hasShownAccessibilityAlert else {
            return
        }

        hasShownAccessibilityAlert = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "Input Change can still switch to English when you move to another app. To detect window switches inside the same app, enable JMacTool in System Settings > Privacy & Security > Accessibility."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func maybeRequestInputMonitoringForInputChange() {
        guard !windowMonitor.hasInputMonitoringAccess else {
            return
        }

        showInputChangeInputMonitoringAlertIfNeeded()
        windowMonitor.requestInputMonitoringAccessIfNeeded()
    }

    private func showInputChangeInputMonitoringAlertIfNeeded() {
        guard !hasShownInputMonitoringAlert else {
            return
        }

        hasShownInputMonitoringAlert = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Input Monitoring Improves Reliability"
        alert.informativeText = "Accessibility lets Input Change detect same-app window switches. Input Monitoring helps avoid interrupting terminal input and window shortcuts while still switching to English after the focus change settles."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func inputChangeTooltip() -> String {
        if windowMonitor.isEnabled {
            if windowMonitor.hasAccessibilityAccess && windowMonitor.hasInputMonitoringAccess {
                return "Input Change is enabled. Accessibility supports same-app window detection, and Input Monitoring helps avoid interrupting terminal input and shortcuts."
            }

            if windowMonitor.hasAccessibilityAccess {
                return "Input Change is enabled. Accessibility supports same-app window detection, but Input Monitoring is not granted, so terminal and shortcut protection is reduced."
            }

            return "Input Change is enabled. App switches work now, but same-app window switches require Accessibility. Input Monitoring further improves shortcut and terminal reliability."
        }

        return "Input Change is disabled."
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
