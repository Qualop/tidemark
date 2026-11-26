import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement
import TidemarkCore

private let overlayAXCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let controller = Unmanaged<OverlayController>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    DispatchQueue.main.async {
        controller.handleAccessibilityNotification(name)
    }
}

final class OverlayController: NSObject, NSApplicationDelegate {
    private let config = OverlayConfig.load()
    private var processLock: ProcessLock?
    private var target: NSRunningApplication?
    private var locator: AccessibilityLocator?
    private var observer: AXObserver?
    private var panel: PassivePanel!
    private var overlayView: UsageOverlayView!
    private var trackingTimer: Timer?
    private var usageTimer: Timer?
    private var providerQuotaTimer: Timer?
    private var permissionTimer: Timer?
    private var composerElement: AXUIElement?
    private var footerAnchorElement: AXUIElement?
    private var footerLeftElement: AXUIElement?
    private var currentWindowElement: AXUIElement?
    private var lastComposerFrame: CGRect?
    private var lastFooterAnchorFrame: CGRect?
    private var lastFooterLeftFrame: CGRect?
    private var lastWindowFrame: CGRect?
    private var lastFoundAt = Date.distantPast
    private var lastWindowChangedAt = Date.distantPast
    private var lastValidationRescanAt = Date.distantPast
    private var lastThemeCheckAt = Date.distantPast
    private var nextRescanAt = Date.distantPast
    private var rescanFailures = 0
    private var burstUntil = Date.distantPast
    private var windowResolvedAt = Date.distantPast
    private var trustCheckedAt = Date.distantPast
    private var trusted = false
    private var currentInterval: TimeInterval = 0
    private lazy var hoverCard = HoverCardController(
        anchorFrame: { [weak self] in
            guard let self, self.panel.isVisible else { return nil }
            return self.panel.frame
        },
        sections: { [weak self] in self?.hoverSections() ?? [] },
        speeds: { [weak self] in self?.speedGroups() ?? [] },
        darkMode: { [weak self] in self?.overlayView.darkMode ?? false }
    )
    private var needsRescan = true
    private var settleRescanPending = false
    private var activeTracking = false
    private var permissionPrompted = false
    private var usageRefreshInFlight = false
    private var quotaSource: QuotaSource = .openAI
    /// The Claude app keeps its own choice (Claude models, or GPT models added by OpenCodex).
    private var claudeQuotaSource: QuotaSource = .openCodexProvider("anthropic")
    private var openAISnapshot: UsageSnapshot = .unavailable
    private var openAIWindows: [QuotaWindow] = []
    private var claudeDirect: (windows: [QuotaWindow], at: Date)?
    private var claudeAppUsage: (remaining: Int, at: Date)?
    /// Remembered across launches so Codex shows the right slots before Claude is opened.
    private var claudePlan: String? = UserDefaults.standard.string(forKey: "LastClaudePlan")
    private var claudePlanCheckedAt = Date.distantPast
    private var openAIPlan: String?
    private var claudeHidesFiveHour: Bool {
        PlanRules.hidesFiveHour(provider: "claude", plan: claudePlan, rules: config.noFiveHourPlans)
    }
    private var gptHidesFiveHour: Bool {
        PlanRules.hidesFiveHour(provider: "gpt", plan: openAIPlan, rules: config.noFiveHourPlans)
    }
    private var usageElement: AXUIElement?
    private var lastUsageReadAt = Date.distantPast
    private var geminiWindows: [QuotaWindow] = []
    private let claudeFetcher = ClaudeQuotaFetcher()
    /// Each app's reply speed, from its own session log (FSEvents; idle when nothing is written).
    private let codexSpeed = TokenSpeedMonitor(app: .codex)
    private let claudeSpeed = TokenSpeedMonitor(app: .claude)
    private var activityWorkItem: DispatchWorkItem?
    private var lastUsageFetchAt = Date.distantPast
    private var openAIFetchedAt: Date?
    private var claudeRefreshInFlight = false
    private var sourceStatus: [String: String] = [:]
    private let geminiFetcher = GeminiQuotaFetcher()
    private var lastModelLabel: String?
    private var lastModelReadAt = Date.distantPast
    private var lastAnchorOwnText: String?
    private var lastFullModelReadAt = Date.distantPast
    private lazy var usageFetcher = UsageFetcher(
        maximumAttempts: config.usageMaxAttempts,
        retryDelayMilliseconds: config.usageRetryDelayMs
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lock = ProcessLock(url: OverlayPaths.overlayLock) else {
            NSApp.terminate(nil)
            return
        }
        processLock = lock
        NSApp.setActivationPolicy(.prohibited)
        createPanel()
        observeWorkspace()
        LoginItem.registerOnFirstLaunch()
        attachIfTargetRunning()
    }

    func applicationWillTerminate(_ notification: Notification) {
        trackingTimer?.invalidate()
        usageTimer?.invalidate()
        providerQuotaTimer?.invalidate()
        permissionTimer?.invalidate()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private func createPanel() {
        let size = NSSize(width: config.width * config.visualScale, height: config.height * config.visualScale)
        panel = PassivePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        // Belongs to the Space it is shown on (slides away with Codex/Claude when switching
        // Spaces) and is hidden by Mission Control, whose window shrinking cannot be followed.
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        hidePanel()

        overlayView = UsageOverlayView(config: config)
        panel.contentView = overlayView
        updateTheme()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(targetLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(targetTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(targetActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(targetDeactivated(_:)), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged(_:)),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    private var targetIsClaude: Bool { target?.bundleIdentifier == OverlayPaths.claudeBundleIdentifier }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "x %.0f y %.0f w %.0f h %.0f", rect.minX, rect.minY, rect.width, rect.height)
    }

    /// In the Claude app the bars always show Claude limits; in Codex they follow the picker.
    private var effectiveSource: QuotaSource { targetIsClaude ? claudeQuotaSource : quotaSource }

    private static func isTarget(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return OverlayPaths.targetBundleIdentifiers.contains(id)
    }

    /// Tidemark stays resident but does nothing until Codex or Claude is running.
    private func attachIfTargetRunning(preferring preferred: NSRunningApplication? = nil) {
        guard target == nil, attachToRunningTarget(preferring: preferred) else { return }
        applyLayoutMode()
        codexSpeed.onReply = { [weak self] in self?.activityRefresh() }
        claudeSpeed.onReply = { [weak self] in self?.activityRefresh() }
        codexSpeed.start()
        claudeSpeed.start()
        startUsageSchedule()
        continueWhenAccessibilityIsAvailable()
    }

    /// Starting layout per app; show() then adapts it to the free space in the row.
    private func applyLayoutMode() {
        apply(layout: targetIsClaude ? .bars(UsageOverlayView.compactBarMax) : .twoLine)
    }

    private func apply(layout requested: UsageOverlayView.Layout) {
        // Ignore bar-length jitter under 2 pt so resizing windows doesn't flicker.
        var layout = requested
        if case .bars(let new) = requested, case .bars(let old) = overlayView.layout, abs(new - old) < 2 { layout = overlayView.layout }
        overlayView.update(layout: layout)
        let plan = overlayView.snapshot.showsPlan ? overlayView.snapshot.plan : nil
        let logical = UsageOverlayView.logicalSize(config: config, layout: layout, plan: plan,
                                                   longLabel: overlayView.snapshot.longLabel)
        let size = NSSize(width: logical.width * config.visualScale, height: logical.height * config.visualScale)
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        overlayView.frame = NSRect(origin: .zero, size: size)
    }

    /// Target quit (or another target came to the front): drop the AX observer, timers and
    /// the mouse monitor. Usage polling stops only when no target app is left running.
    private func detach(keepUsage: Bool = false) {
        guard target != nil || trackingTimer != nil else { return }
        for timer in [trackingTimer, permissionTimer] { timer?.invalidate() }
        trackingTimer = nil
        permissionTimer = nil
        if !keepUsage {
            codexSpeed.stop()
            claudeSpeed.stop()
            usageTimer?.invalidate()
            providerQuotaTimer?.invalidate()
            usageTimer = nil
            providerQuotaTimer = nil
        }
        currentInterval = 0
        activeTracking = false
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        hidePanel()
        hoverCard.setMonitoring(false)
        target = nil
        locator = nil
        composerElement = nil
        footerAnchorElement = nil
        footerLeftElement = nil
        currentWindowElement = nil
        lastComposerFrame = nil
        lastFooterAnchorFrame = nil
        lastFooterLeftFrame = nil
        lastWindowFrame = nil
        lastAnchorOwnText = nil
        lastModelLabel = nil
        usageElement = nil
        needsRescan = true
        nextRescanAt = .distantPast
        rescanFailures = 0
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    private func attachToRunningTarget(preferring preferred: NSRunningApplication?) -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter { Self.isTarget($0) && !$0.isTerminated }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let application = running.first(where: { $0 == preferred })
            ?? running.first(where: { $0 == frontmost })
            ?? running.first
        else { return false }
        target = application
        locator = AccessibilityLocator(processIdentifier: application.processIdentifier)
        if application.bundleIdentifier == OverlayPaths.claudeBundleIdentifier {
            // Electron only builds its accessibility tree when asked to.
            AXUIElementSetAttributeValue(locator!.application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return true
    }

    private func continueWhenAccessibilityIsAvailable() {
        guard AXIsProcessTrusted() else {
            hidePanel()
            if !permissionPrompted {
                permissionPrompted = true
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, AXIsProcessTrusted() else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.beginAccessibilityTracking()
            }
            return
        }
        beginAccessibilityTracking()
    }

    private func beginAccessibilityTracking() {
        guard let target, let locator else { return }
        var createdObserver: AXObserver?
        if AXObserverCreate(target.processIdentifier, overlayAXCallback, &createdObserver) == .success,
           let createdObserver {
            observer = createdObserver
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            let application = locator.application
            for notification in [
                kAXFocusedWindowChangedNotification,
                kAXWindowCreatedNotification,
            ] {
                _ = AXObserverAddNotification(createdObserver, application, notification as CFString, pointer)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        }
        setTracking(active: target.isActive && !target.isHidden)
        tick()
    }

    private func registerElementNotifications(
        window: AXUIElement,
        composer: AXUIElement,
        footerAnchor: AXUIElement?,
        footerLeft: AXUIElement?
    ) {
        guard let observer else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var elements = [window, composer]
        if let footerAnchor { elements.append(footerAnchor) }
        if let footerLeft { elements.append(footerLeft) }
        for element in elements {
            for notification in [
                kAXMovedNotification,
                kAXResizedNotification,
                kAXUIElementDestroyedNotification,
            ] {
                _ = AXObserverAddNotification(observer, element, notification as CFString, pointer)
            }
        }
        if let footerAnchor {
            for notification in [kAXValueChangedNotification, kAXTitleChangedNotification] {
                _ = AXObserverAddNotification(observer, footerAnchor, notification as CFString, pointer)
            }
        }
    }

    func handleAccessibilityNotification(_ name: String) {
        if name == (kAXValueChangedNotification as String) || name == (kAXTitleChangedNotification as String) {
            readModelLabelFromAnchor(force: true)
            return
        }
        if name == (kAXUIElementDestroyedNotification as String)
            || name == (kAXWindowCreatedNotification as String)
            || name == (kAXFocusedWindowChangedNotification as String) {
            needsRescan = true
            nextRescanAt = .distantPast
            rescanFailures = 0
            windowResolvedAt = .distantPast
        }
        if name == (kAXMovedNotification as String) || name == (kAXResizedNotification as String) {
            lastWindowChangedAt = Date()
            settleRescanPending = true
            startBurst()
        }
        tick()
    }

    /// Follow the window at the configured fast rate only while something is moving.
    private func startBurst(_ seconds: TimeInterval = 0.6) {
        burstUntil = max(burstUntil, Date().addingTimeInterval(seconds))
        setTracking(active: activeTracking)
    }

    private func setTracking(active: Bool) {
        activeTracking = active
        hoverCard.setMonitoring(active)
        let interval: TimeInterval
        if !active {
            interval = 0.5
        } else if Date() < burstUntil {
            interval = Double(config.trackingIntervalMs) / 1_000
        } else {
            interval = 0.1
        }
        guard interval != currentInterval || trackingTimer == nil else { return }
        currentInterval = interval
        trackingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = interval >= 0.1 ? interval * 0.2 : 0
        trackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func tick() {
        autoreleasepool { tickBody() }
    }

    private func tickBody() {
        guard let target, !target.isTerminated else {
            detach()
            return
        }
        let shouldTrack = target.isActive && !target.isHidden
        setTracking(active: shouldTrack)
        guard shouldTrack else {
            hidePanel()
            return
        }
        if Date().timeIntervalSince(trustCheckedAt) >= 2 {
            trustCheckedAt = Date()
            trusted = AXIsProcessTrusted()
        }
        guard trusted else {
            hidePanel()
            return
        }
        guard let locator else {
            hidePanel()
            return
        }

        // Resolving the focused window costs extra round trips; the focused-window
        // notification forces it, otherwise once a second is plenty.
        if currentWindowElement == nil || Date().timeIntervalSince(windowResolvedAt) >= 1 {
            windowResolvedAt = Date()
            let resolved = locator.currentWindow()
            if let resolved, let currentWindowElement, CFEqual(currentWindowElement, resolved) {
                // unchanged
            } else {
                currentWindowElement = resolved
                composerElement = nil
                footerAnchorElement = nil
                footerLeftElement = nil
                needsRescan = true
                nextRescanAt = .distantPast
            }
        }
        guard let window = currentWindowElement else {
            retainOrHideLastPosition()
            return
        }
        let windowState = locator.windowState(window)
        guard !windowState.minimized, let windowFrame = windowState.frame,
              windowFrame.width >= 500, windowFrame.height >= 350 else {
            currentWindowElement = nil
            retainOrHideLastPosition()
            return
        }

        if let previousWindowFrame = lastWindowFrame,
           !approximatelyEqual(previousWindowFrame, windowFrame, tolerance: 0.25) {
            lastWindowChangedAt = Date()
            settleRescanPending = true
            startBurst()
        }

        if settleRescanPending,
           Date().timeIntervalSince(lastWindowChangedAt) * 1_000 >= Double(config.resizeSettleMs) {
            needsRescan = true
            settleRescanPending = false
        }

        if let composerElement,
           let exactFrame = locator.frame(of: composerElement),
           plausibleComposer(exactFrame, inside: windowFrame) {
            if let lastComposerFrame, !approximatelyEqual(lastComposerFrame, exactFrame, tolerance: 0.25) {
                startBurst(0.3) // composer is growing/shrinking while typing
            }
            let exactFooterFrame = footerAnchorElement.flatMap { locator.frame(of: $0) }
                ?? predictedFooterFrame(using: windowFrame)
            let exactFooterLeftFrame = footerLeftElement.flatMap { locator.frame(of: $0) }
                ?? predictedFooterLeftFrame(using: windowFrame)
            show(
                composerAXFrame: exactFrame,
                footerAnchorAXFrame: exactFooterFrame,
                footerLeftAXFrame: exactFooterLeftFrame
            )
            lastComposerFrame = exactFrame
            if let exactFooterFrame { lastFooterAnchorFrame = exactFooterFrame }
            if let exactFooterLeftFrame { lastFooterLeftFrame = exactFooterLeftFrame }
            lastWindowFrame = windowFrame
            lastFoundAt = Date()
        } else if let predicted = predictedFrame(using: windowFrame) {
            show(
                composerAXFrame: predicted,
                footerAnchorAXFrame: predictedFooterFrame(using: windowFrame),
                footerLeftAXFrame: predictedFooterLeftFrame(using: windowFrame)
            )
            lastWindowFrame = windowFrame
            needsRescan = true
        } else {
            retainOrHideLastPosition()
        }

        // A tree walk is the expensive part of the overlay. Broken elements, destroyed
        // notifications and an unreadable model popup already force a rescan,
        // so the periodic safety net can be infrequent.
        if Date().timeIntervalSince(lastValidationRescanAt) >= 10 {
            lastValidationRescanAt = Date()
            needsRescan = true
        }

        if needsRescan, Date() >= nextRescanAt {
            lastValidationRescanAt = Date()
            if let located = locator.locateComposer(in: window) {
                rescanFailures = 0
                nextRescanAt = Date().addingTimeInterval(0.1)
                lastAnchorOwnText = nil
                composerElement = located.element
                footerAnchorElement = located.footerAnchorElement
                footerLeftElement = located.footerLeftElement
                currentWindowElement = located.window
                lastComposerFrame = located.frame
                lastFooterAnchorFrame = located.footerAnchorFrame
                lastFooterLeftFrame = located.footerLeftFrame
                lastWindowFrame = located.windowFrame
                lastFoundAt = Date()
                needsRescan = false
                updateModelLabel(located.modelLabel)
                usageElement = located.usageElement
                readClaudeAppUsage()
                // The Claude plan rarely changes: look it up once every 10 minutes.
                if targetIsClaude, Date().timeIntervalSince(claudePlanCheckedAt) > 600 {
                    claudePlanCheckedAt = Date()
                    if let plan = locator.claudeAccountPlan(in: window), plan != claudePlan {
                        claudePlan = plan
                        UserDefaults.standard.set(plan, forKey: "LastClaudePlan")
                        applyCurrentSnapshot()
                    }
                }
                SanitizedStatus.writeLayout([
                    "app": target.bundleIdentifier ?? "",
                    "composer": Self.describe(located.frame),
                    "modelSelector": located.footerAnchorFrame.map(Self.describe) ?? "none",
                    "selectorRole": located.footerAnchorElement.map { locator.role(of: $0) } ?? "none",
                    "leftControl": located.footerLeftFrame.map(Self.describe) ?? "none",
                    "modelLabel": located.modelLabel ?? "",
                ])
                registerElementNotifications(
                    window: located.window,
                    composer: located.element,
                    footerAnchor: located.footerAnchorElement,
                    footerLeft: located.footerLeftElement
                )
                show(
                    composerAXFrame: located.frame,
                    footerAnchorAXFrame: located.footerAnchorFrame,
                    footerLeftAXFrame: located.footerLeftFrame
                )
            } else {
                // Back off while the composer is absent (settings page, loading, ...).
                rescanFailures += 1
                nextRescanAt = Date().addingTimeInterval(min(0.25 * pow(2, Double(rescanFailures - 1)), 4))
            }
            _ = malloc_zone_pressure_relief(nil, 0)
        }

        if Date().timeIntervalSince(lastThemeCheckAt) >= 2 {
            lastThemeCheckAt = Date()
            updateTheme()
        }

        if targetIsClaude, Date().timeIntervalSince(lastUsageReadAt) >= 5 {
            readClaudeAppUsage()
        }

        // Cheap re-read of the already located model popup; the full tree rescan is much slower.
        if Date().timeIntervalSince(lastModelReadAt) >= 0.1 {
            readModelLabelFromAnchor()
        }
    }

    private func readModelLabelFromAnchor(force: Bool = false) {
        lastModelReadAt = Date()
        guard let locator, let footerAnchorElement else { return }
        // Claude can change the account suffix in a child while the popup's own label
        // stays the same. Check the children periodically for that picker.
        let own = locator.ownText(footerAnchorElement)
        if !force, own == lastAnchorOwnText,
           (!targetIsClaude && !own.isEmpty) || Date().timeIntervalSince(lastFullModelReadAt) < 0.5 {
            return
        }
        lastAnchorOwnText = own
        lastFullModelReadAt = Date()
        let label = locator.visibleText(footerAnchorElement)
        if label.isEmpty {
            needsRescan = true // popup was likely re-rendered; find the new element
        } else {
            updateModelLabel(label)
        }
    }

    private func predictedFrame(using currentWindowFrame: CGRect) -> CGRect? {
        guard let composer = lastComposerFrame, let previousWindow = lastWindowFrame,
              Date().timeIntervalSince(lastFoundAt) * 1_000 <= Double(config.composerMissingGraceMs)
        else { return nil }
        let deltaX = currentWindowFrame.minX - previousWindow.minX
        let deltaY = currentWindowFrame.minY - previousWindow.minY
        let deltaWidth = currentWindowFrame.width - previousWindow.width
        let deltaHeight = currentWindowFrame.height - previousWindow.height
        return CGRect(
            x: composer.minX + deltaX,
            y: composer.minY + deltaY + deltaHeight,
            width: max(300, composer.width + deltaWidth),
            height: composer.height
        )
    }

    private func predictedFooterFrame(using currentWindowFrame: CGRect) -> CGRect? {
        guard let anchor = lastFooterAnchorFrame, let previousWindow = lastWindowFrame,
              Date().timeIntervalSince(lastFoundAt) * 1_000 <= Double(config.composerMissingGraceMs)
        else { return nil }
        return anchor.offsetBy(
            dx: currentWindowFrame.minX - previousWindow.minX,
            dy: currentWindowFrame.minY - previousWindow.minY
                + currentWindowFrame.height - previousWindow.height
        )
    }

    private func predictedFooterLeftFrame(using currentWindowFrame: CGRect) -> CGRect? {
        guard let left = lastFooterLeftFrame, let previousWindow = lastWindowFrame,
              Date().timeIntervalSince(lastFoundAt) * 1_000 <= Double(config.composerMissingGraceMs)
        else { return nil }
        return left.offsetBy(
            dx: currentWindowFrame.minX - previousWindow.minX,
            dy: currentWindowFrame.minY - previousWindow.minY
                + currentWindowFrame.height - previousWindow.height
        )
    }

    private func retainOrHideLastPosition() {
        guard let lastComposerFrame,
              Date().timeIntervalSince(lastFoundAt) * 1_000 <= Double(config.composerMissingGraceMs)
        else {
            hidePanel()
            return
        }
        show(
            composerAXFrame: lastComposerFrame,
            footerAnchorAXFrame: lastFooterAnchorFrame,
            footerLeftAXFrame: lastFooterLeftFrame
        )
        needsRescan = true
    }

    private func show(
        composerAXFrame: CGRect,
        footerAnchorAXFrame: CGRect? = nil,
        footerLeftAXFrame: CGRect? = nil
    ) {
        // Without the control row there is no safe spot: hide rather than cover text or buttons.
        guard footerAnchorAXFrame != nil else {
            hidePanel()
            return
        }
        let composer = appKitRect(fromAccessibilityRect: composerAXFrame)
        // Free space on the control row: from the last left-side control (or the composer's
        // left edge) to the model picker, with 12 pt breathing room on each side.
        var freeSpan: (left: CGFloat, right: CGFloat)?
        if let footerAnchorAXFrame {
            let left = footerLeftAXFrame?.maxX ?? composerAXFrame.minX
            freeSpan = (left, footerAnchorAXFrame.minX)
            let room = (footerAnchorAXFrame.minX - left - 24) / config.visualScale
            let plan = overlayView.snapshot.showsPlan ? overlayView.snapshot.plan : nil
            guard let layout = UsageOverlayView.layout(fitting: room, preferTwoLine: !targetIsClaude, config: config, plan: plan,
                                                       longLabel: overlayView.snapshot.longLabel) else {
                hidePanel() // too narrow for even "5h 20%": never cover the controls
                return
            }
            apply(layout: layout)
        }
        let size = panel.frame.size
        let verticalCenter: CGFloat
        if let footerAnchorAXFrame {
            // Align the visible labels + bars (logical y=0...19.5 in the two-line layout,
            // the whole view in the one-line layout) with the footer controls.
            let visibleContentCenterFromTop = overlayView.compact ? size.height / 2 : 10 * config.visualScale
            verticalCenter = appKitRect(fromAccessibilityRect: footerAnchorAXFrame).midY
                + visibleContentCenterFromTop - size.height / 2
        } else {
            verticalCenter = composer.minY + config.bottomOffset
        }
        let horizontalCenter = freeSpan.map { ($0.left + $0.right) / 2 } ?? composer.midX
        let origin = NSPoint(
            x: horizontalCenter - size.width / 2 + config.horizontalOffset,
            y: verticalCenter - size.height / 2
        )
        if abs(panel.frame.origin.x - origin.x) > 0.1 || abs(panel.frame.origin.y - origin.y) > 0.1 {
            panel.setFrameOrigin(origin)
            if hoverCard.visible { hoverCard.anchorMoved() }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func appKitRect(fromAccessibilityRect rect: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private func plausibleComposer(_ rect: CGRect, inside window: CGRect) -> Bool {
        rect.width >= 300 && rect.height >= 24 && rect.height <= 600 && rect.intersects(window)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func updateTheme() {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        overlayView.update(darkMode: appearance == .darkAqua)
    }

    private func startUsageSchedule() {
        guard usageTimer == nil else {
            applyCurrentSnapshot()
            return
        }
        refreshUsage()
        usageTimer = Timer.scheduledTimer(
            withTimeInterval: Double(config.usageRefreshIntervalMs) / 1_000,
            repeats: true
        ) { [weak self] _ in
            self?.refreshUsage()
        }
        RunLoop.main.add(usageTimer!, forMode: .common)

        // OpenCodex refreshes its provider quota cache itself; re-reading the file is cheap.
        providerQuotaTimer?.invalidate()
        providerQuotaTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, case .openCodexProvider = self.effectiveSource else { return }
            self.applyCurrentSnapshot()
        }
        RunLoop.main.add(providerQuotaTimer!, forMode: .common)
    }

    private func updateModelLabel(_ label: String?) {
        // Keep the previous choice when the selector text is momentarily unreadable.
        guard let label, !label.isEmpty, label != lastModelLabel else { return }
        lastModelLabel = label
        let source = targetIsClaude ? QuotaSource.forClaudeApp(modelLabel: label) : QuotaSource.from(modelLabel: label)
        SanitizedStatus.writeModel(label: label, source: source)
        if targetIsClaude {
            guard source != claudeQuotaSource else { return }
            claudeQuotaSource = source
            claudeAppUsage = nil
        } else {
            guard source != quotaSource else { return }
            quotaSource = source
        }
        applyCurrentSnapshot()
    }

    private func applyCurrentSnapshot() {
        switch effectiveSource {
        case .openAI:
            overlayView.update(snapshot: openAISnapshot)
        case .openCodexProvider("anthropic"):
            overlayView.update(snapshot: UsageSnapshot(windows: claudeWindows(now: Date()), plan: claudePlan,
                                                       hideFiveHour: claudeHidesFiveHour))
        case .openCodexProvider(let provider):
            overlayView.update(snapshot: OpenCodexQuotaReader.snapshot(provider: provider) ?? .unavailable)
        }
    }

    /// Claude limits from the freshest source: Claude Code's login (opt-in Keychain) or
    /// OpenCodex's cache, whichever was refreshed last; the Claude app's own live usage
    /// indicator replaces the 5h value whenever it is newer than both.
    private func claudeReading(now: Date) -> (windows: [QuotaWindow], updatedAt: Date?, source: String) {
        var base: (windows: [QuotaWindow], updatedAt: Date?, source: String) = ([], nil, "none")
        if let claudeDirect, now.timeIntervalSince(claudeDirect.at) < 600, !claudeDirect.windows.isEmpty {
            base = (claudeDirect.windows, claudeDirect.at, "direct")
        }
        let cache = OpenCodexQuotaReader.reading(provider: "anthropic", now: now)
        if !cache.windows.isEmpty, base.windows.isEmpty || (cache.updatedAt ?? .distantPast) > (base.updatedAt ?? .distantPast) {
            base = (cache.windows, cache.updatedAt, "opencodex")
        }
        if let app = claudeAppUsage, now.timeIntervalSince(app.at) < 1_800, app.at > (base.updatedAt ?? .distantPast) {
            let reset = base.windows.first { $0.label == "5h" }?.resetAt
            let windows = [QuotaWindow(label: "5h", remaining: app.remaining, resetAt: reset)]
                + base.windows.filter { $0.label != "5h" }
            return (windows, base.updatedAt ?? app.at, base.windows.isEmpty ? "claude-app" : base.source + "+claude-app")
        }
        return base
    }

    private func claudeWindows(now: Date) -> [QuotaWindow] { claudeReading(now: now).windows }

    private func claudeSourceName(now: Date) -> String { claudeReading(now: now).source }

    /// A reply just finished in Codex or Claude: usage changed, so refresh soon (debounced,
    /// and the ChatGPT request at most every 15 s) instead of waiting for the next minute.
    private func activityRefresh() {
        activityWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.target != nil else { return }
            if Date().timeIntervalSince(self.lastUsageFetchAt) >= 15 {
                self.refreshUsage()
            } else {
                self.applyCurrentSnapshot()
            }
        }
        activityWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    /// Cheap read of the Claude app's usage control (one batched AX request).
    private func readClaudeAppUsage() {
        lastUsageReadAt = Date()
        guard targetIsClaude, claudeQuotaSource == .openCodexProvider("anthropic"),
              let locator, let usageElement,
              let remaining = ClaudeAppUsageParser.fiveHourRemaining(from: locator.ownText(usageElement)) else { return }
        let changed = claudeAppUsage?.remaining != remaining
        claudeAppUsage = (remaining, Date())
        if changed {
            sourceStatus["claude"] = claudeSourceName(now: Date())
            SanitizedStatus.writeSources(sourceStatus)
            applyCurrentSnapshot()
        }
    }

    /// Per app, the models used in the last day with their latest speed; the app in front first.
    private func speedGroups() -> [SpeedGroup] {
        let codex = SpeedGroup(app: "Codex", models: codexSpeed.recentModels())
        let claude = SpeedGroup(app: "Claude", models: claudeSpeed.recentModels())
        return targetIsClaude ? [claude, codex] : [codex, claude]
    }

    private func hidePanel() {
        panel.orderOut(nil)
        hoverCard.hide(animated: false)
    }

    private func hoverSections() -> [HoverSection] {
        let now = Date()
        let dark = overlayView.darkMode
        // Provider colours: Claude terracotta, GPT emerald; lifted a little in dark mode.
        let claudeColor = dark
            ? NSColor(calibratedRed: 236 / 255, green: 145 / 255, blue: 112 / 255, alpha: 1)
            : NSColor(calibratedRed: 201 / 255, green: 100 / 255, blue: 66 / 255, alpha: 1)
        let gptColor = dark
            ? NSColor(calibratedRed: 52 / 255, green: 199 / 255, blue: 155 / 255, alpha: 1)
            : NSColor(calibratedRed: 13 / 255, green: 138 / 255, blue: 106 / 255, alpha: 1)
        let otherColor = dark
            ? NSColor(calibratedRed: 160 / 255, green: 140 / 255, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 99 / 255, green: 82 / 255, blue: 220 / 255, alpha: 1)
        // Direct ChatGPT response first; OpenCodex's per-account cache only as a fallback.
        let gpt = openAIWindows.isEmpty ? CodexAccountQuotaReader.activeWindows(now: now) : openAIWindows
        let source = effectiveSource
        var sections = [
            HoverSection(
                title: "GPT",
                color: gptColor,
                active: source == .openAI,
                windows: gptHidesFiveHour ? gpt.filter { $0.label != "5h" } : gpt,
                plan: PlanRules.displayName(openAIPlan),
                updatedAt: openAIWindows.isEmpty ? nil : openAIFetchedAt
            ),
        ]
        // Claude appears whenever Claude Code or OpenCodex has a Claude login (or it is selected).
        let claude = claudeReading(now: now)
        let claudeActive = source == .openCodexProvider("anthropic")
        if !claude.windows.isEmpty || claudeActive {
            sections.insert(HoverSection(title: "Claude", color: claudeColor, active: claudeActive,
                                         windows: claudeHidesFiveHour ? claude.windows.filter { $0.label != "5h" } : claude.windows,
                                         plan: claudePlan, updatedAt: claude.updatedAt), at: 0)
        }
        // Gemini appears when Gemini CLI is signed in.
        var geminiActive = false
        if case .openCodexProvider(let provider) = source, ["google", "gemini"].contains(provider) { geminiActive = true }
        if !geminiWindows.isEmpty {
            let geminiColor = dark
                ? NSColor(calibratedRed: 138 / 255, green: 180 / 255, blue: 248 / 255, alpha: 1)
                : NSColor(calibratedRed: 26 / 255, green: 115 / 255, blue: 232 / 255, alpha: 1)
            sections.append(HoverSection(title: "Gemini", color: geminiColor, active: geminiActive, windows: geminiWindows))
        }
        if case .openCodexProvider(let provider) = source, provider != "anthropic",
           !(geminiActive && !geminiWindows.isEmpty) {
            sections.append(HoverSection(
                title: provider.capitalized,
                color: otherColor,
                active: true,
                windows: OpenCodexQuotaReader.windows(provider: provider, now: now)
            ))
        }
        return sections
    }

    /// Claude and Gemini each update the bars as soon as their own answer arrives.
    private func refreshDirectQuota() {
        if !claudeRefreshInFlight {
            claudeRefreshInFlight = true
            Task { [weak self] in
                guard let self else { return }
                let windows = await self.claudeFetcher.claudeWindows(useKeychain: self.config.claudeKeychain)
                await MainActor.run {
                    self.claudeRefreshInFlight = false
                    if let windows { self.claudeDirect = (windows, Date()) }
                    self.sourceStatus["claude"] = self.claudeSourceName(now: Date())
                    SanitizedStatus.writeSources(self.sourceStatus)
                    self.applyCurrentSnapshot()
                }
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let windows = await self.geminiFetcher.geminiWindows()
            await MainActor.run {
                self.geminiWindows = windows
                self.sourceStatus["gemini"] = windows.isEmpty ? "none" : "direct"
                SanitizedStatus.writeSources(self.sourceStatus)
            }
        }
    }

    private func refreshUsage() {
        lastUsageFetchAt = Date()
        refreshDirectQuota()
        guard !usageRefreshInFlight else { return }
        usageRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let result = await self.usageFetcher.refresh()
            await MainActor.run {
                self.openAIWindows = result?.windows ?? []
                if let plan = result?.plan { self.openAIPlan = plan }
                self.openAISnapshot = result == nil ? .unavailable
                    : UsageSnapshot(windows: self.openAIWindows, plan: PlanRules.displayName(self.openAIPlan),
                                    hideFiveHour: self.gptHidesFiveHour)
                if result != nil { self.openAIFetchedAt = Date() }
                self.sourceStatus["codexSpeed"] = self.codexSpeed.latest.map { "\(Int($0.tokensPerSecond.rounded())) tok/s" } ?? "none"
                self.sourceStatus["claudeSpeed"] = self.claudeSpeed.latest.map { "\(Int($0.tokensPerSecond.rounded())) tok/s" } ?? "none"
                self.sourceStatus["gpt"] = result != nil ? "direct"
                    : (CodexAccountQuotaReader.activeWindows(now: Date()).isEmpty ? "none" : "opencodex")
                SanitizedStatus.writeSources(self.sourceStatus)
                self.applyCurrentSnapshot()
                self.usageRefreshInFlight = false
                _ = malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    @objc private func targetTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isTarget(app), app == target else { return }
        let othersRunning = NSWorkspace.shared.runningApplications.contains { Self.isTarget($0) && $0 != app && !$0.isTerminated }
        detach(keepUsage: othersRunning)
        if othersRunning { attachIfTargetRunning() }
    }

    @objc private func targetLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isTarget(app) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attachIfTargetRunning() }
    }

    @objc private func targetActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isTarget(app) else { return }
        if let target, target != app {
            detach(keepUsage: true) // switch between Codex and Claude
        }
        attachIfTargetRunning(preferring: app)
        guard target != nil else { return }
        if Date().timeIntervalSince(lastUsageFetchAt) >= 15 { refreshUsage() } // fresh numbers on return
        setTracking(active: true)
        needsRescan = true
        tick()
    }

    @objc private func targetDeactivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isTarget(app), app == target else { return }
        hidePanel()
        setTracking(active: false)
    }

    @objc private func systemAppearanceChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateTheme() }
    }

}

/// Opens Tidemark at login. Checked on every launch: a registration that never took
/// (or was dropped after an ad-hoc re-sign) is retried, while one the user switched off
/// in System Settings (`requiresApproval`) is left alone. Skipped when a LaunchAgent
/// already starts Tidemark (it sets TIDEMARK_LAUNCH_AGENT).
enum LoginItem {
    static func registerOnFirstLaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard ProcessInfo.processInfo.environment["TIDEMARK_LAUNCH_AGENT"] == nil else { return }
        let service = SMAppService.mainApp
        guard service.status == .notRegistered || service.status == .notFound else { return }
        try? service.register()
    }
}

@main
enum TidemarkMain {
    static func main() {
        let application = NSApplication.shared
        let controller = OverlayController()
        application.delegate = controller
        application.run()
    }
}
