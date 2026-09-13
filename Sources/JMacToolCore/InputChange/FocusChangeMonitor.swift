import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Watches app/window focus changes and switches to an English input source
/// whenever the focus target changes, waiting for keyboard activity to settle
/// so terminal input and window shortcuts are not interrupted.
@MainActor
final class FocusChangeMonitor: NSObject {
    private struct FocusContext: Equatable {
        let appIdentifier: String
        let processIdentifier: pid_t
        let windowIdentity: String?
    }

    private struct FocusSnapshot {
        let context: FocusContext
        let windowIdentityState: WindowIdentityState
    }

    private enum RefreshReason {
        case started
        case workspaceActivation
        case axFocusedWindowChanged
        case axMainWindowChanged
        case axDelayedResample
        case polling
    }

    private enum WindowIdentityState {
        case confirmed
        case unavailable
    }

    private var timer: Timer?
    private var isObservingWorkspace = false
    private var currentFocusContext: FocusContext?
    private var pendingFocusContext: FocusContext?
    private var observedProcessIdentifier: pid_t?
    private var observedAppElement: AXUIElement?
    private var focusObserver: AXObserver?
    private var lastObserverBindingAttemptProcessIdentifier: pid_t?
    private var delayedRefreshWorkItem: DispatchWorkItem?
    private var pendingCommitWorkItem: DispatchWorkItem?
    private var lastKeyboardActivityAt: Date?
    private var keyboardActivityMonitor: KeyboardActivityMonitor?
    private let keyboardQuietWindow: TimeInterval = 0.15

    private(set) var isEnabled = false
    var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    func requestAccessibilityAccessIfNeeded() {
        guard !hasAccessibilityAccess else {
            return
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoringAccessIfNeeded() {
        guard !hasInputMonitoringAccess else {
            return
        }

        _ = CGRequestListenEventAccess()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        isEnabled = enabled

        if enabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        if !isObservingWorkspace {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(activeAppChanged),
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            isObservingWorkspace = true
        }

        if timer == nil {
            timer = Timer.scheduledTimer(
                timeInterval: 0.4,
                target: self,
                selector: #selector(timerFired),
                userInfo: nil,
                repeats: true
            )
            timer?.tolerance = 0.1

            if let timer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        syncKeyboardActivityMonitoringState()
        refreshFocusContext(reason: .started)
    }

    private func stopMonitoring() {
        if isObservingWorkspace {
            NSWorkspace.shared.notificationCenter.removeObserver(
                self,
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            isObservingWorkspace = false
        }

        timer?.invalidate()
        timer = nil
        delayedRefreshWorkItem?.cancel()
        delayedRefreshWorkItem = nil
        pendingCommitWorkItem?.cancel()
        pendingCommitWorkItem = nil
        currentFocusContext = nil
        pendingFocusContext = nil
        lastKeyboardActivityAt = nil
        stopKeyboardActivityMonitoring()
        stopObservingFocusedApp()
    }

    @objc private func activeAppChanged() {
        refreshFocusContext(reason: .workspaceActivation)
    }

    @objc private func timerFired() {
        refreshFocusContext(reason: .polling)
    }

    private func refreshFocusContext(reason: RefreshReason) {
        guard isEnabled else {
            return
        }

        if reason == .axFocusedWindowChanged || reason == .axMainWindowChanged {
            scheduleDelayedRefresh()
        }

        syncKeyboardActivityMonitoringState()
        ensureFocusedAppObserver()

        guard let snapshot = sampleCurrentFocusContext() else {
            return
        }

        handleFocusTransition(to: snapshot, reason: reason)
    }

    private func sampleCurrentFocusContext() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appIdentifier = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        guard hasAccessibilityAccess,
              let windowIdentity = AXWindowIdentity.focusedWindowIdentity(for: appElement) else {
            return FocusSnapshot(
                context: FocusContext(
                    appIdentifier: appIdentifier,
                    processIdentifier: app.processIdentifier,
                    windowIdentity: nil
                ),
                windowIdentityState: .unavailable
            )
        }

        return FocusSnapshot(
            context: FocusContext(
                appIdentifier: appIdentifier,
                processIdentifier: app.processIdentifier,
                windowIdentity: windowIdentity
            ),
            windowIdentityState: .confirmed
        )
    }

    private func handleFocusTransition(to snapshot: FocusSnapshot, reason _: RefreshReason) {
        guard let currentFocusContext else {
            currentFocusContext = snapshot.context
            return
        }

        let appChanged = currentFocusContext.processIdentifier != snapshot.context.processIdentifier ||
            currentFocusContext.appIdentifier != snapshot.context.appIdentifier

        if appChanged {
            cancelPendingFocusCommit()
            self.currentFocusContext = snapshot.context
            switchToEnglishNow()
            return
        }

        if currentFocusContext.windowIdentity == snapshot.context.windowIdentity {
            if currentFocusContext.windowIdentity == nil,
               snapshot.windowIdentityState == .confirmed {
                self.currentFocusContext = snapshot.context
            }

            cancelPendingIfResolved(by: snapshot.context)
            return
        }

        guard snapshot.windowIdentityState == .confirmed else {
            return
        }

        guard currentFocusContext.windowIdentity != nil else {
            self.currentFocusContext = snapshot.context
            cancelPendingIfResolved(by: snapshot.context)
            return
        }

        schedulePendingFocusCommit(for: snapshot.context)
    }

    private func ensureFocusedAppObserver() {
        guard hasAccessibilityAccess else {
            lastObserverBindingAttemptProcessIdentifier = nil
            stopObservingFocusedApp()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            stopObservingFocusedApp()
            return
        }

        if observedProcessIdentifier == app.processIdentifier, focusObserver != nil {
            return
        }

        if observedProcessIdentifier != app.processIdentifier {
            stopObservingFocusedApp()
        }

        guard lastObserverBindingAttemptProcessIdentifier != app.processIdentifier else {
            return
        }

        bindObserver(to: app)
    }

    private func bindObserver(to app: NSRunningApplication) {
        lastObserverBindingAttemptProcessIdentifier = app.processIdentifier

        var observer: AXObserver?
        let createResult = AXObserverCreate(app.processIdentifier, focusObserverCallback, &observer)
        guard createResult == .success, let observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let notifications = [
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString
        ]

        var addedAnyNotification = false

        for notification in notifications {
            let result = AXObserverAddNotification(observer, appElement, notification, refcon)
            if result == .success || result == .notificationAlreadyRegistered {
                addedAnyNotification = true
            }
        }

        guard addedAnyNotification else {
            return
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        focusObserver = observer
        observedAppElement = appElement
        observedProcessIdentifier = app.processIdentifier
    }

    private func stopObservingFocusedApp() {
        delayedRefreshWorkItem?.cancel()
        delayedRefreshWorkItem = nil

        if let focusObserver, let observedAppElement {
            AXObserverRemoveNotification(
                focusObserver,
                observedAppElement,
                kAXFocusedWindowChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                focusObserver,
                observedAppElement,
                kAXMainWindowChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(focusObserver),
                .commonModes
            )
        }

        focusObserver = nil
        observedAppElement = nil
        observedProcessIdentifier = nil
    }

    private func syncKeyboardActivityMonitoringState() {
        if isEnabled, hasInputMonitoringAccess {
            startKeyboardActivityMonitoringIfNeeded()
        } else {
            stopKeyboardActivityMonitoring()
        }
    }

    private func startKeyboardActivityMonitoringIfNeeded() {
        guard keyboardActivityMonitor == nil else {
            return
        }

        let monitor = KeyboardActivityMonitor()
        monitor.onActivity = { [weak self] in
            Task { @MainActor [weak self] in
                self?.recordKeyboardActivity()
            }
        }
        monitor.start()
        keyboardActivityMonitor = monitor
    }

    private func stopKeyboardActivityMonitoring() {
        keyboardActivityMonitor?.stop()
        keyboardActivityMonitor = nil
    }

    private func recordKeyboardActivity() {
        lastKeyboardActivityAt = Date()

        guard pendingFocusContext != nil else {
            return
        }

        schedulePendingCommitTimer()
    }

    private func schedulePendingFocusCommit(for context: FocusContext) {
        if pendingFocusContext != context {
            pendingFocusContext = context
        }

        schedulePendingCommitTimer()
    }

    private func schedulePendingCommitTimer() {
        guard pendingFocusContext != nil else {
            return
        }

        pendingCommitWorkItem?.cancel()

        let fireInterval = pendingCommitDelay()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.commitPendingFocusContextIfStable()
            }
        }

        pendingCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fireInterval, execute: workItem)
    }

    private func pendingCommitDelay(now: Date = Date()) -> TimeInterval {
        var fireDate = now.addingTimeInterval(keyboardQuietWindow)

        if hasInputMonitoringAccess,
           let lastKeyboardActivityAt {
            let quietDate = lastKeyboardActivityAt.addingTimeInterval(keyboardQuietWindow)
            if quietDate > fireDate {
                fireDate = quietDate
            }
        }

        return max(0, fireDate.timeIntervalSince(now))
    }

    private func commitPendingFocusContextIfStable() {
        guard let pendingFocusContext else {
            return
        }

        if hasInputMonitoringAccess,
           let lastKeyboardActivityAt,
           Date().timeIntervalSince(lastKeyboardActivityAt) < keyboardQuietWindow {
            schedulePendingCommitTimer()
            return
        }

        guard let snapshot = sampleCurrentFocusContext(),
              snapshot.windowIdentityState == .confirmed,
              snapshot.context == pendingFocusContext else {
            cancelPendingFocusCommit()
            return
        }

        currentFocusContext = pendingFocusContext
        cancelPendingFocusCommit()
        switchToEnglishNow()
    }

    private func cancelPendingIfResolved(by context: FocusContext) {
        guard let pendingFocusContext,
              pendingFocusContext == context else {
            return
        }

        cancelPendingFocusCommit()
    }

    private func cancelPendingFocusCommit() {
        pendingCommitWorkItem?.cancel()
        pendingCommitWorkItem = nil
        pendingFocusContext = nil
    }

    private func scheduleDelayedRefresh() {
        delayedRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshFocusContext(reason: .axDelayedResample)
            }
        }

        delayedRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    @objc fileprivate func handleAXNotificationFromCallback(_ notification: NSString) {
        handleAXNotification(named: notification as String)
    }

    private func handleAXNotification(named notification: String) {
        switch notification {
        case String(kAXFocusedWindowChangedNotification):
            refreshFocusContext(reason: .axFocusedWindowChanged)
        case String(kAXMainWindowChangedNotification):
            refreshFocusContext(reason: .axMainWindowChanged)
        default:
            break
        }
    }

    func switchToEnglishNow() {
        InputSourceSwitcher.switchToEnglishNow()
    }
}

private let focusObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else {
        return
    }

    let monitor = Unmanaged<FocusChangeMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.performSelector(onMainThread: #selector(FocusChangeMonitor.handleAXNotificationFromCallback(_:)), with: notification as NSString, waitUntilDone: false)
}
