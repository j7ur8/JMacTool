import Foundation

/// App/profile operations (`set`/`unset`/`test`) ported from the jpmanager
/// app-operations module, including the safe-unset rule for zsh/environment.
enum ProxyOperations {
    struct AppSelection {
        var target: ProxyTarget
        var requestedName: String
        var canonicalName: String
    }

    struct ConfigureResult {
        var selection: AppSelection
        var profile: ProxyProfile
        var way: String
    }

    struct ClearResult {
        var selection: AppSelection
        var way: String
        var aborted: Bool
    }

    struct TestResult {
        var selection: AppSelection
        var profile: ProxyProfile
        var way: String
        var mismatches: [(key: ProxyStateKey, actual: String, expected: String)]
    }

    static func availableAppNames(context: ProxyFileContext) -> [String] {
        let registry = ProxyTargetRegistry.loadOrDefault(context: context)
        return registry.targets.map(\.name) + registry.aliases.keys.sorted()
    }

    static func buildUnknownAppError(_ appName: String, context: ProxyFileContext) -> ProxyEngineError {
        ProxyEngineError(
            message: "Unknown app \"\(appName)\". Available apps: \(availableAppNames(context: context).joined(separator: ", "))"
        )
    }

    static func resolveAppSelection(_ appName: String, context: ProxyFileContext) throws -> AppSelection {
        let normalizedName = appName.trimmingCharacters(in: .whitespaces)
        let (targets, aliases) = ProxyTargetLoader.load(context: context)

        let canonicalName = aliases[normalizedName] ?? normalizedName
        guard let target = targets.first(where: { $0.name == canonicalName }) else {
            throw buildUnknownAppError(appName, context: context)
        }

        return AppSelection(
            target: target,
            requestedName: normalizedName.isEmpty ? canonicalName : normalizedName,
            canonicalName: canonicalName
        )
    }

    static func findProxyProfileByName(
        context: ProxyFileContext,
        profileName: String
    ) throws -> StoredProfile {
        let profiles = ProfileStore.ensureStore(context: context)
        guard let stored = ProfileStore.findProfileByName(profiles, profileName) else {
            throw ProxyEngineError(message: "Unknown proxy profile \"\(profileName)\".")
        }
        return stored
    }

    static func configureAppWithProfile(
        context: ProxyFileContext,
        appName: String,
        profileName: String
    ) throws -> ConfigureResult {
        let selection = try resolveAppSelection(appName, context: context)
        let stored = try findProxyProfileByName(context: context, profileName: profileName)

        selection.target.apply(stored.state)

        return ConfigureResult(
            selection: selection,
            profile: stored.profile,
            way: selection.target.wayLabel
        )
    }

    static func environmentProxySubjectLabel(_ appName: String) -> String {
        appName == "zsh" ? "zsh" : "environment"
    }

    static func clearAppProxy(
        context: ProxyFileContext,
        appName: String,
        force: Bool,
        confirmUnsafeUnset: ((ProxyState, String) -> Bool)? = nil
    ) throws -> ClearResult {
        let selection = try resolveAppSelection(appName, context: context)
        let isEnvironment = selection.canonicalName == "zsh"
            || selection.canonicalName == ProxyConstants.environmentAppName

        if isEnvironment {
            let profiles = ProfileStore.ensureStore(context: context)
            let current = selection.target.currentState()
            let matchesSavedProfile = ProxyDashboard.findMatchingProxyProfile(selection.target, profiles: profiles, currentState: current) != nil
            let subjectLabel = environmentProxySubjectLabel(selection.requestedName)

            if ExpectedState.hasAnyProxyState(current), !matchesSavedProfile, !force {
                let warning = "Current \(subjectLabel) proxy settings (\(ProxyDisplay.describe(current))) do not match any saved jpmanager profile."

                guard let confirmUnsafeUnset else {
                    throw ProxyEngineError(
                        message: "\(warning). Re-run with `\(ProxyConstants.legacyCommandName) unset \(selection.requestedName) --force` to unset anyway."
                    )
                }

                if !confirmUnsafeUnset(current, subjectLabel) {
                    return ClearResult(
                        selection: selection,
                        way: selection.target.wayLabel,
                        aborted: true
                    )
                }
            }
        }

        selection.target.clear()
        return ClearResult(selection: selection, way: selection.target.wayLabel, aborted: false)
    }

    static func testAppProfile(
        context: ProxyFileContext,
        appName: String,
        profileName: String
    ) throws -> TestResult {
        let selection = try resolveAppSelection(appName, context: context)
        let stored = try findProxyProfileByName(context: context, profileName: profileName)

        let current = selection.target.currentState()
        let mismatches = ExpectedState.diff(actual: current, expected: selection.target.expectedState(for: stored.state))

        return TestResult(
            selection: selection,
            profile: stored.profile,
            way: selection.target.wayLabel,
            mismatches: mismatches
        )
    }
}
