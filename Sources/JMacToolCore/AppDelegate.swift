import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let cleaningModeController = CleaningModeController()
    private let windowMonitor = WindowMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let clearScreenMenuItem = NSMenuItem(title: "Clear Screen", action: #selector(clearScreen), keyEquivalent: "")
    private let inputChangeMenuItem = NSMenuItem()
    private let inputChangeView = InputChangeMenuItemView()
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
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleaningModeController.stop()
        windowMonitor.setEnabled(false)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = makeStatusImage(isCleaning: false)
            button.imagePosition = .imageOnly
            button.toolTip = AppConstants.appName
        }

        clearScreenMenuItem.target = self
        quitMenuItem.target = self

        inputChangeView.onClick = { [weak self] in
            self?.toggleInputChange()
        }
        inputChangeMenuItem.view = inputChangeView

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(clearScreenMenuItem)
        menu.addItem(inputChangeMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)
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

        if let button = statusItem.button {
            button.image = makeStatusImage(isCleaning: isCleaning)
            button.title = button.image == nil ? "JT" : ""
        }
    }

    private func makeStatusImage(isCleaning: Bool) -> NSImage? {
        let symbolNames = isCleaning
            ? ["sparkles", "display.trianglebadge.exclamationmark", "moon.stars.fill"]
            : ["display", "sparkles", "rectangle"]

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
