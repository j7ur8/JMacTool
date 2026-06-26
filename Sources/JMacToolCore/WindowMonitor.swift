import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class WindowMonitor: NSObject {
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
    private let englishSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US"
    ]
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
              let windowIdentity = focusedWindowIdentity(for: appElement) else {
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

    private func focusedWindowIdentity(for appElement: AXUIElement) -> String? {
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowResult == .success,
              let focusedWindowValue,
              let window = axElement(from: focusedWindowValue) else {
            return nil
        }

        return windowIdentity(for: window)
    }

    private func windowIdentity(for window: AXUIElement) -> String? {
        if let identifier = stringAttribute(kAXIdentifierAttribute as CFString, for: window),
           !identifier.isEmpty {
            return "axid:\(identifier)"
        }

        if let document = stringAttribute(kAXDocumentAttribute as CFString, for: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !document.isEmpty {
            return "doc:\(document)"
        }

        guard let role = stringAttribute(kAXRoleAttribute as CFString, for: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !role.isEmpty,
            let position = pointAttribute(kAXPositionAttribute as CFString, for: window),
            let size = sizeAttribute(kAXSizeAttribute as CFString, for: window) else {
            return nil
        }

        let subrole = stringAttribute(kAXSubroleAttribute as CFString, for: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = normalizedTitle(focusedWindowTitle(for: window))
        let frameIdentity = [
            role,
            subrole,
            "\(rounded(position.x)),\(rounded(position.y))",
            "\(rounded(size.width))x\(rounded(size.height))",
            title
        ].joined(separator: "|")

        return "fallback:\(frameIdentity)"
    }

    private func focusedWindowTitle(for window: AXUIElement) -> String {
        stringAttribute(kAXTitleAttribute as CFString, for: window) ?? ""
    }

    private func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    private func axElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func pointAttribute(_ attribute: CFString, for element: AXUIElement) -> CGPoint? {
        valueAttribute(attribute, expectedType: .cgPoint, for: element)
    }

    private func sizeAttribute(_ attribute: CFString, for element: AXUIElement) -> CGSize? {
        valueAttribute(attribute, expectedType: .cgSize, for: element)
    }

    private func valueAttribute<T>(
        _ attribute: CFString,
        expectedType: AXValueType,
        for element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == expectedType else {
            return nil
        }

        switch expectedType {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return nil
            }
            return point as? T
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return nil
            }
            return size as? T
        default:
            return nil
        }
    }

    private func normalizedTitle(_ title: String) -> String {
        let components = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)

        return components.joined(separator: " ").lowercased()
    }

    private func rounded(_ value: CGFloat) -> Int {
        Int(value.rounded())
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
        let filter = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String
        ] as CFDictionary

        guard let sourceList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        for preferredID in englishSourceIDs {
            if let source = sourceList.first(where: { inputSourceIdentifier(for: $0) == preferredID }) {
                TISSelectInputSource(source)
                return
            }
        }
    }

    private func inputSourceIdentifier(for source: TISInputSource) -> String? {
        guard let rawValue = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    }
}

private final class KeyboardActivityMonitor {
    var onActivity: (@Sendable () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        stop()

        guard CGPreflightListenEventAccess() else {
            return
        }

        let mask = Self.eventMask(for: [
            .keyDown,
            .flagsChanged
        ])

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<KeyboardActivityMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return monitor.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
        case .keyDown, .flagsChanged:
            onActivity?()
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private static func eventMask(for eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }
    }
}

private let focusObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else {
        return
    }

    let monitor = Unmanaged<WindowMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.performSelector(onMainThread: #selector(WindowMonitor.handleAXNotificationFromCallback(_:)), with: notification as NSString, waitUntilDone: false)
}
