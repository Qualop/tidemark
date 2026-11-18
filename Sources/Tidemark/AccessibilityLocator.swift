import AppKit
import ApplicationServices
import TidemarkCore

struct LocatedComposer {
    let element: AXUIElement
    let frame: CGRect
    let footerAnchorElement: AXUIElement?
    let footerAnchorFrame: CGRect?
    let footerLeftElement: AXUIElement?
    let footerLeftFrame: CGRect?
    let modelLabel: String?
    /// Claude app's "Usage: 77% ..." control, when present.
    let usageElement: AXUIElement?
    let window: AXUIElement
    let windowFrame: CGRect
}

private typealias Candidate = (element: AXUIElement, frame: CGRect, score: Double)

/// Every AX read is a round trip into the Codex renderer, so reads are batched with
/// AXUIElementCopyMultipleAttributeValues and tree walks stop as soon as possible.
final class AccessibilityLocator {
    let application: AXUIElement

    init(processIdentifier: pid_t) {
        application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
    }

    // MARK: Cheap reads used by the tracking loop

    func currentWindow() -> AXUIElement? {
        if let focused: AXUIElement = attribute(application, kAXFocusedWindowAttribute as CFString),
           isUsableWindow(focused) {
            return focused
        }
        if let main: AXUIElement = attribute(application, kAXMainWindowAttribute as CFString),
           isUsableWindow(main) {
            return main
        }
        let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute as CFString) ?? []
        return windows.first(where: isUsableWindow)
    }

    /// Frame and minimized flag of a window in one round trip.
    func windowState(_ window: AXUIElement) -> (frame: CGRect?, minimized: Bool) {
        let values = copyValues(window, [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute])
        return (makeFrame(values[0], values[1]), (values[2] as? NSNumber)?.boolValue ?? false)
    }

    func frame(of element: AXUIElement) -> CGRect? {
        let values = copyValues(element, [kAXPositionAttribute, kAXSizeAttribute])
        return makeFrame(values[0], values[1])
    }

    func role(of element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute as CFString) ?? ""
    }

    /// The control's own title/value/description in one round trip; cheap enough to poll.
    func ownText(_ element: AXUIElement) -> String {
        copyValues(element, [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute])
            .compactMap { $0 as? String }
            .joined(separator: " ")
    }

    /// Title/value/description of a control plus its descendants, collapsed to one line.
    /// Open menus are skipped so the list of other models never leaks into the label.
    func visibleText(_ element: AXUIElement) -> String {
        var parts: [String] = []
        var visited = 0
        func collect(_ node: AXUIElement, depth: Int) {
            guard depth <= 4, visited < 40 else { return }
            visited += 1
            let values = copyValues(node, [
                kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute,
            ])
            let role = values[0] as? String ?? ""
            if role == (kAXMenuRole as String) || role == (kAXMenuItemRole as String) || role == "AXListBox" { return }
            for case let text as String in values[1...3] {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !parts.contains(trimmed) { parts.append(trimmed) }
            }
            for child in values[4] as? [AXUIElement] ?? [] { collect(child, depth: depth + 1) }
        }
        collect(element, depth: 0)
        return parts.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Locating the composer (expensive, run rarely)

    func locateComposer(in window: AXUIElement) -> LocatedComposer? {
        guard let windowFrame = frame(of: window), windowFrame.width >= 500, windowFrame.height >= 350 else {
            return nil
        }

        var editables: [Candidate] = []
        var visited = 0
        var done = false
        findEditables(from: window, windowFrame: windowFrame, depth: 0, visited: &visited, done: &done, output: &editables)
        guard let editable = editables.max(by: { $0.score < $1.score }) else { return nil }
        let container = bestContainer(startingAt: editable.element, editableFrame: editable.frame, windowFrame: windowFrame)

        // The control row is inside the composer (Codex, Claude chat) or right under it
        // (Claude Code). Search the composer first, then up to seven ancestors (a tall Claude
        // composer resolves to a deeply nested text box, several levels below the row).
        // Horizontal limits come from the element being searched: with a tall composer the
        // container can be the inner text box while the row is aligned to the outer box.
        var root: AXUIElement? = container.element
        var footers: [Candidate] = []
        var anchor: Candidate?
        var bounds = container.frame
        for _ in 0..<8 {
            guard let current = root else { break }
            bounds = (CFEqual(current, container.element) ? container.frame : frame(of: current)) ?? container.frame
            footers = footerControls(under: current, bottom: container.frame.maxY, bounds: bounds)
            anchor = bestAnchor(footers, editable: editable.frame, bounds: bounds)
            if anchor != nil { break }
            root = attribute(current, kAXParentAttribute as CFString)
        }
        let footerLeft = anchor.flatMap { anchor in
            footers
                .filter {
                    $0.frame.maxX <= anchor.frame.minX
                        && $0.frame.minX >= bounds.minX - 8
                        && $0.frame.maxX < bounds.midX
                        && abs($0.frame.midY - anchor.frame.midY) <= 12
                }
                .max(by: { $0.frame.maxX < $1.frame.maxX })
        }
        let modelLabel = modelSelectorLabel(
            anchor: anchor?.element,
            candidates: footers
        )
        let usageElement = footers.first { candidate in
            ClaudeAppUsageParser.fiveHourRemaining(from: ownText(candidate.element)) != nil
        }?.element
        return LocatedComposer(
            element: container.element,
            frame: container.frame,
            footerAnchorElement: anchor?.element,
            footerAnchorFrame: anchor?.frame,
            footerLeftElement: footerLeft?.element,
            footerLeftFrame: footerLeft?.frame,
            modelLabel: modelLabel,
            usageElement: usageElement,
            window: window,
            windowFrame: windowFrame
        )
    }

    private func findEditables(
        from element: AXUIElement,
        windowFrame: CGRect,
        depth: Int,
        visited: inout Int,
        done: inout Bool,
        output: inout [Candidate]
    ) {
        guard !done, depth <= 48, visited < 12_000 else { return }
        visited += 1

        let values = copyValues(element, [kAXRoleAttribute, kAXChildrenAttribute])
        let role = values[0] as? String ?? ""
        if role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String),
           let candidateFrame = frame(of: element),
           candidateFrame.width >= 300,
           candidateFrame.height >= 16,
           candidateFrame.height <= 600,
           candidateFrame.intersects(windowFrame) {
            let bottomGap = abs(windowFrame.maxY - candidateFrame.maxY)
            var score = 0.0
            score += role == (kAXTextAreaRole as String) ? 120 : 70
            score += min(candidateFrame.width / 12, 100)
            score += bottomGap < windowFrame.height * 0.35 ? 160 : 0
            score += candidateFrame.midY > windowFrame.midY ? 100 : 0
            let metadata = searchableMetadata(element).lowercased()
            let named = metadata.contains("composer") || metadata.contains("prosemirror")
            if named { score += 500 }
            if metadata.contains("prompt") || metadata.contains("message") || metadata.contains("요청") { score += 180 }
            output.append((element, candidateFrame, score))
            // The walk runs back to front, so the first text area in the bottom part of the
            // window is the composer; anything visited later sits above it.
            let inBottomRegion = bottomGap < windowFrame.height * 0.35 && candidateFrame.midY > windowFrame.midY
            if inBottomRegion, named || role == (kAXTextAreaRole as String) { done = true; return }
        }

        // Chromium places the composer near the end of the web-area tree.
        for child in (values[1] as? [AXUIElement] ?? []).reversed() {
            findEditables(from: child, windowFrame: windowFrame, depth: depth + 1, visited: &visited, done: &done, output: &output)
            if done { return }
        }
    }

    /// Buttons and popups on a row near the composer's bottom edge (AX coordinates: y grows down),
    /// horizontally within the searched element.
    private func footerControls(under root: AXUIElement, bottom: CGFloat, bounds: CGRect) -> [Candidate] {
        var output: [Candidate] = []
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 20, visited < 1_500 else { return }
            visited += 1
            let values = copyValues(element, [kAXRoleAttribute, kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute])
            let role = values[0] as? String ?? ""
            if isFooterControlRole(role),
               let controlFrame = makeFrame(values[2], values[3]),
               controlFrame.height >= 16,
               controlFrame.height <= 80,
               controlFrame.width >= 16,
               controlFrame.width <= 420,
               controlFrame.midY >= bottom - 60,
               controlFrame.midY <= bottom + 48,
               controlFrame.minX >= bounds.minX - 8,
               controlFrame.maxX <= bounds.maxX + 8 {
                let metadata = controlMetadata(element).lowercased()
                // Position only breaks ties (< 200); being the model picker is what counts.
                var score = min(max((controlFrame.midY - bounds.minY) / 10, 0), 100)
                score += controlFrame.midX > bounds.midX ? 100 : 0
                // Model names change; the composer model selector remains a popup control.
                if role == (kAXPopUpButtonRole as String), controlFrame.width >= 70 { score += 3_000 }
                if metadata.contains("model") || metadata.contains("모델") || QuotaSource.looksLikeModelLabel(metadata) {
                    score += 800
                }
                output.append((element, controlFrame, score))
            }
            for child in values[1] as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return output
    }

    /// The model picker: a wide popup or a control naming a model (send buttons do not qualify,
    /// so the search keeps climbing until it reaches the real control row).
    private func bestAnchor(_ footers: [Candidate], editable: CGRect, bounds: CGRect) -> Candidate? {
        footers
            .filter {
                $0.score >= Self.selectorScore
                    && $0.frame.midY >= editable.midY
                    && $0.frame.minX >= bounds.midX
                    && $0.frame.maxX <= bounds.maxX + 8
            }
            .max(by: { $0.score < $1.score })
    }

    /// Text of the composer's model selector, preferring the popup used as the footer anchor.
    private func modelSelectorLabel(anchor: AXUIElement?, candidates: [Candidate]) -> String? {
        // The anchor is the model popup itself, so trust its text even for names like
        // "6.1 Sol" that carry no provider or "gpt" marker.
        if let anchor {
            let text = visibleText(anchor)
            if !text.isEmpty { return text }
        }
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let text = visibleText(candidate.element)
            if QuotaSource.looksLikeModelLabel(text) { return text }
        }
        return nil
    }

    private static let selectorScore: Double = 700

    private func isFooterControlRole(_ role: String) -> Bool {
        role == (kAXButtonRole as String)
            || role == (kAXPopUpButtonRole as String)
            || role == "AXMenuButton"
            || role == "AXMenuItem"
    }

    private func controlMetadata(_ element: AXUIElement) -> String {
        copyValues(element, [
            kAXIdentifierAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
            kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXValueAttribute,
        ]).compactMap { $0 as? String }.joined(separator: " ")
    }

    private func bestContainer(
        startingAt editable: AXUIElement,
        editableFrame: CGRect,
        windowFrame: CGRect
    ) -> (element: AXUIElement, frame: CGRect) {
        var current = editable
        var fallback = (element: editable, frame: editableFrame)
        var fallbackScore = -Double.infinity

        for depth in 0..<24 {
            let values = copyValues(current, [
                kAXIdentifierAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute,
                kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute,
            ])
            let metadata = values[0...3].compactMap { $0 as? String }.joined(separator: " ").lowercased()
            if let currentFrame = makeFrame(values[4], values[5]) {
                if metadata.contains("composer-surface-chrome") {
                    return (current, currentFrame)
                }
                let bottomGap = abs(windowFrame.maxY - currentFrame.maxY)
                let widthDelta = abs(currentFrame.width - editableFrame.width)
                var score = 0.0
                if currentFrame.width >= editableFrame.width { score += 80 }
                if widthDelta <= 180 { score += 60 }
                if currentFrame.height >= 70 && currentFrame.height <= 450 { score += 120 }
                if bottomGap <= 80 { score += 160 }
                if currentFrame.maxY >= editableFrame.maxY + 32,
                   currentFrame.height <= 450 { score += 120 }
                if depth > 0 { score += 20 }
                if metadata.contains("composer") { score += 400 }
                if score > fallbackScore {
                    fallback = (current, currentFrame)
                    fallbackScore = score
                }
            }
            guard let parent = values[6], CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        return fallback
    }

    private func searchableMetadata(_ element: AXUIElement) -> String {
        copyValues(element, [
            kAXIdentifierAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute,
        ]).compactMap { $0 as? String }.joined(separator: " ")
    }

    private func isUsableWindow(_ window: AXUIElement) -> Bool {
        let state = windowState(window)
        guard !state.minimized, let candidateFrame = state.frame else { return false }
        return candidateFrame.width >= 500 && candidateFrame.height >= 350
    }

    // MARK: Low-level helpers

    private func copyValues(_ element: AXUIElement, _ names: [String]) -> [AnyObject?] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result
        ) == .success,
            let array = result as [AnyObject]?,
            array.count == names.count
        else { return Array(repeating: nil, count: names.count) }
        return array.map { value in
            // Missing attributes come back as AXValues wrapping an AXError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    private func makeFrame(_ positionObject: AnyObject?, _ sizeObject: AnyObject?) -> CGRect? {
        guard let positionObject, let sizeObject,
              CFGetTypeID(positionObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionObject as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeObject as! AXValue, .cgSize, &size),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }
}
