import Foundation
import ServiceManagement

/// Launch-at-login support via SMAppService, replacing jpmanager's
/// hand-written LaunchAgent management for the integrated app.
enum ProxyLoginService {
    enum Status: String, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown
    }

    static func currentStatus() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    static func isEnabled() -> Bool {
        currentStatus() == .enabled
    }

    /// Returns an error message on failure, nil on success.
    @discardableResult
    static func enable() -> String? {
        do {
            try SMAppService.mainApp.register()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message on failure, nil on success.
    @discardableResult
    static func disable() -> String? {
        do {
            try SMAppService.mainApp.unregister()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
