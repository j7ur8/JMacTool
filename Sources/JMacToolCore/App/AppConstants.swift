import AppKit
import Foundation

enum AppConstants {
    static let appName = "JMacTool"
    static let bundleIdentifier = "local.codex.JMacTool"
    static let inputChangeEnabledDefaultsKey = "JMacTool.inputChangeEnabled"
    static let exitButtonTitle = "Restore System"
    static let presentationOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableAppleMenu,
        .disableProcessSwitching,
        .disableHideApplication
    ]
}
