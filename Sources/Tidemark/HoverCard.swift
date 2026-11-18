import AppKit
import GenieWarpMesh
import QuartzCore
import TidemarkCore

/// One app's recent reply speeds, one per model, measured from that app's own session log.
struct SpeedGroup {
    let app: String
    let models: [TokenSpeed]
}

struct HoverSection {
    let title: String
    let color: NSColor
    let active: Bool
    let windows: [QuotaWindow]
    /// Subscription plan, shown next to the provider name.
    var plan: String? = nil
    /// When the numbers were last refreshed; shown on the card once they are stale.
    var updatedAt: Date? = nil
}

/// Bar color shared with the inline overlay: red (empty) -> yellow -> green (full).
func quotaColor(_ remaining: Int) -> NSColor {
    let red = SIMD3<Double>(239, 68, 68)
    let yellow = SIMD3<Double>(234, 179, 8)
    let green = SIMD3<Double>(34, 197, 94)
    let color: SIMD3<Double>
    if remaining <= 50 {
        color = red + (yellow - red) * (max(0, Double(remaining - 1)) / 49)
    } else {
        color = yellow + (green - yellow) * (Double(remaining - 50) / 50)
    }
    return NSColor(calibratedRed: color.x / 255, green: color.y / 255, blue: color.z / 255, alpha: 1)
}

/// Hover card with every provider's quota. It comes out of the bars and goes back into them
/// with the macOS Genie effect (GenieWarpMesh, which warps the window in the WindowServer).
/// The card itself is static: one bitmap plus a few layers, built on first hover and
/// released when hidden.
final class HoverCardController {
    private static let margin: CGFloat = 12 // room for the shadow
    private static let width: CGFloat = 240
    private static let gap: CGFloat = 8
    private static let radius: CGFloat = 12

    private let anchorFrame: () -> NSRect?
    private let sections: () -> [HoverSection]
    private let speeds: () -> [SpeedGroup]
    private let darkMode: () -> Bool
    private let genie = GenieEffect()
    private var panel: PassivePanel?
    private var blurView: NSVisualEffectView?
    private let shadow = CALayer()
    private let surface = CALayer()
    private let content = CALayer()
    private var barLayers: [CALayer] = []
    private var fills: [CALayer] = []
    private var lastAnchor = NSRect.zero
    private var monitor: Any?
    private var generation = 0
    private var wantsVisible = false
    private var genieBusy = false
    private(set) var visible = false

    init(anchorFrame: @escaping () -> NSRect?, sections: @escaping () -> [HoverSection],
         speeds: @escaping () -> [SpeedGroup], darkMode: @escaping () -> Bool) {
        self.speeds = speeds
        self.anchorFrame = anchorFrame
        self.sections = sections
        self.darkMode = darkMode
        genie.adaptiveMesh = true
    }

    /// Listen to pointer movement only while Codex is frontmost.
    func setMonitoring(_ enabled: Bool) {
        if enabled {
            guard monitor == nil else { return }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.pointerMoved()
            }
        } else {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            hide(animated: false)
        }
    }

    func anchorMoved() {
        guard visible, !genieBusy, let panel, let anchor = anchorFrame() else { return }
        lastAnchor = anchor
        panel.setFrameOrigin(origin(for: panel.frame.size, anchor: anchor))
    }

    func hide(animated: Bool) {
        wantsVisible = false
        if animated {
            reconcile()
            return
        }
        guard visible else { return }
        generation += 1 // completions from a running warp no longer apply
        visible = false
        finishHide()
    }

    // MARK: Private

    private func pointerMoved() {
        guard let anchor = anchorFrame() else {
            hide(animated: false)
            return
        }
        setWanted(anchor.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation), anchor: anchor)
    }

    func setWanted(_ wanted: Bool, anchor: NSRect) {
        wantsVisible = wanted
        if wanted { lastAnchor = anchor }
        reconcile()
    }

    /// GenieEffect ignores calls while it is animating, so the wanted state is applied
    /// whenever the current warp finishes.
    private func reconcile() {
        guard !genieBusy else { return }
        if wantsVisible, !visible {
            present()
        } else if !wantsVisible, visible {
            dismiss()
        }
    }

    private func present() {
        let anchor = lastAnchor
        let panel = self.panel ?? makePanel()
        let dark = darkMode()
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.backingScaleFactor ?? 2
        let rendered = HoverCardRenderer.render(sections(), speeds: speeds(), width: Self.width, dark: dark, scale: scale)
        let card = CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: rendered.height)
        let panelSize = CGSize(width: Self.width + Self.margin * 2, height: rendered.height + Self.margin * 2)
        panel.setFrame(NSRect(origin: origin(for: panelSize, anchor: anchor), size: panelSize), display: false)
        layout(card: card, rendered: rendered, dark: dark, scale: scale)

        visible = true
        genieBusy = true
        generation += 1
        let token = generation
        genie.duration = 0.28
        genie.easingType = .easeOutCubic
        genie.restore(window: panel, from: target(for: anchor), direction: .bottom) { [weak self] in
            self?.warpFinished(token)
        }
        growBars()
    }

    private func dismiss() {
        guard let panel else { return }
        visible = false
        genieBusy = true
        generation += 1
        let token = generation
        genie.duration = 0.22
        genie.easingType = .easeInOutCubic
        genie.minimize(window: panel, to: target(for: anchorFrame() ?? lastAnchor), direction: .bottom) { [weak self] in
            guard let self else { return }
            if self.generation == token { self.finishHide() }
            self.warpFinished(token)
        }
    }

    private func warpFinished(_ token: Int) {
        genieBusy = false
        reconcile()
    }

    /// A narrow slit at the middle of the bars: what the card pours out of and back into.
    private func target(for anchor: NSRect) -> CGRect {
        // Two-line layout: the bar line; one-line layout: just under the row.
        CGRect(x: anchor.midX - 36, y: max(anchor.minY, anchor.maxY - 19) - 2, width: 72, height: 2)
    }

    private func layout(card: CGRect, rendered: HoverCardRenderer.Output, dark: Bool, scale: CGFloat) {
        blurView?.frame = card
        blurView?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.frame = card
        shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: card.size),
                                   cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: dark ? 0.5 : 0.22).cgColor
        surface.frame = card
        surface.backgroundColor = (dark
            ? NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.45)
            : NSColor(calibratedWhite: 1, alpha: 0.55)).cgColor
        surface.borderColor = (dark ? NSColor(calibratedWhite: 1, alpha: 0.12) : NSColor(calibratedWhite: 0, alpha: 0.10)).cgColor
        content.frame = surface.bounds
        content.contentsScale = scale
        content.contents = rendered.image

        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        fills.removeAll()
        let trackColor = (dark ? NSColor(calibratedWhite: 1, alpha: 0.13) : NSColor(calibratedWhite: 0, alpha: 0.08)).cgColor
        for bar in rendered.bars {
            // Renderer frames are top-down; layers are bottom-up.
            let frame = CGRect(x: bar.frame.minX, y: rendered.height - bar.frame.maxY,
                               width: bar.frame.width, height: bar.frame.height)
            let track = CALayer()
            track.frame = frame
            track.cornerRadius = frame.height / 2
            track.backgroundColor = trackColor
            let fill = CALayer()
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.bounds = CGRect(x: 0, y: 0, width: frame.width * CGFloat(bar.remaining) / 100, height: frame.height)
            fill.position = CGPoint(x: 0, y: frame.height / 2)
            fill.cornerRadius = frame.height / 2
            fill.backgroundColor = quotaColor(bar.remaining).cgColor
            track.addSublayer(fill)
            surface.addSublayer(track)
            barLayers.append(track)
            fills.append(fill)
        }
        CATransaction.commit()
    }

    private func growBars() {
        let now = CACurrentMediaTime()
        let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        for (index, fill) in fills.enumerated() {
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = 0
            grow.toValue = fill.bounds.width
            grow.beginTime = now + 0.12 + Double(index) * 0.02
            grow.duration = 0.26
            grow.timingFunction = settle
            grow.fillMode = .backwards
            fill.add(grow, forKey: "grow")
        }
    }

    private func finishHide() {
        panel?.orderOut(nil)
        content.contents = nil // drop the bitmap while hidden
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        fills.removeAll()
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    private func makePanel() -> PassivePanel {
        let panel = PassivePanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        // Belongs to the Space it is shown on (slides away with Codex/Claude when switching
        // Spaces) and is hidden by Mission Control, whose window shrinking cannot be followed.
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let container = NSView()
        container.wantsLayer = true

        shadow.shadowOpacity = 1
        shadow.shadowRadius = 9
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        let shadowHost = hostingView(root: shadow)

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(radius: Self.radius)
        blurView = blur

        surface.cornerRadius = Self.radius
        surface.masksToBounds = true
        surface.borderWidth = 1
        content.contentsGravity = .resize
        surface.addSublayer(content)
        let contentHost = hostingView(root: surface)

        for view in [shadowHost, blur, contentHost] { container.addSubview(view) }
        panel.contentView = container
        self.panel = panel
        return panel
    }

    /// Layer-hosting view: AppKit leaves the sublayers alone.
    private func hostingView(root: CALayer) -> NSView {
        let host = NSView()
        let layer = CALayer()
        layer.addSublayer(root)
        host.layer = layer
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
        return host
    }

    /// Stretchable rounded-rect mask for the blur view.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func origin(for size: CGSize, anchor: NSRect) -> NSPoint {
        // Card is centred over the bars; its bottom edge sits just above them.
        var x = anchor.midX - size.width / 2
        let y = anchor.maxY + Self.gap - Self.margin
        if let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame {
            x = min(max(x, visible.minX - Self.margin + 6), visible.maxX - size.width + Self.margin - 6)
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }
}

/// Draws the card's static text into a single bitmap and reports where the bars go.
enum HoverCardRenderer {
    struct Bar {
        let frame: CGRect // top-down card coordinates
        let remaining: Int
    }

    struct Output {
        let image: CGImage?
        let height: CGFloat
        let bars: [Bar]
    }

    private static let inset: CGFloat = 14
    private static let headerHeight: CGFloat = 21
    private static let rowHeight: CGFloat = 18
    private static let sectionGap: CGFloat = 17
    private static let speedHeader: CGFloat = 17
    private static let groupHeader: CGFloat = 17
    private static let groupFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static func render(_ sections: [HoverSection], speeds: [SpeedGroup] = [], width: CGFloat, dark: Bool,
                       scale: CGFloat, now: Date = Date()) -> Output {
        var height: CGFloat = 12 + 8
        for (index, section) in sections.enumerated() {
            height += (index > 0 ? sectionGap : 0) + headerHeight + CGFloat(max(section.windows.count, 1)) * rowHeight
        }
        if !speeds.isEmpty {
            height += sectionGap + speedHeader
            for group in speeds { height += groupHeader + CGFloat(max(group.models.count, 1)) * rowHeight }
        }

        let pixelWidth = Int((width * scale).rounded(.up))
        let pixelHeight = Int((height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Output(image: nil, height: height, bars: []) }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        let primary = dark ? NSColor(calibratedWhite: 0.95, alpha: 1) : NSColor(calibratedWhite: 0.08, alpha: 1)
        let secondary = dark ? NSColor(calibratedWhite: 0.66, alpha: 1) : NSColor(calibratedWhite: 0.40, alpha: 1)
        let divider = dark ? NSColor(calibratedWhite: 1, alpha: 0.10) : NSColor(calibratedWhite: 0, alpha: 0.08)
        let accent = dark
            ? NSColor(calibratedRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0, green: 122 / 255, blue: 1, alpha: 1)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let resetFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        var bars: [Bar] = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        }

        var y: CGFloat = 12
        for (index, section) in sections.enumerated() {
            if index > 0 {
                y += 8
                divider.setFill()
                NSRect(x: inset, y: y, width: width - inset * 2, height: 0.5).fill()
                y += sectionGap - 8
            }

            // The dot marks the provider of the model selected in Codex.
            let dot = NSRect(x: inset, y: y + 4.5, width: 7, height: 7)
            if section.active {
                accent.withAlphaComponent(0.22).setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -2.5, dy: -2.5)).fill()
                accent.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                secondary.withAlphaComponent(0.7).setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            // Only the provider in use gets its colour; the other one is grey.
            let title = text(section.title, titleFont, section.active ? section.color : secondary)
            title.draw(at: NSPoint(x: inset + 14, y: y))
            if let plan = section.plan {
                text(plan, resetFont, secondary).draw(at: NSPoint(x: inset + 14 + title.size().width + 6, y: y + 2.5))
            }
            if let updated = section.updatedAt, now.timeIntervalSince(updated) > 120 {
                let stale = text(L10n.updatedAgo(updated, now: now), resetFont, secondary)
                stale.draw(at: NSPoint(x: width - inset - stale.size().width, y: y + 2.5))
            }
            y += headerHeight

            if section.windows.isEmpty {
                text(L10n.noData, labelFont, secondary).draw(at: NSPoint(x: inset, y: y + 2))
                y += rowHeight
            }
            for window in section.windows {
                text(window.label, labelFont, secondary).draw(at: NSPoint(x: inset, y: y + 2))
                bars.append(Bar(frame: CGRect(x: 40, y: y + 7, width: 72, height: 4), remaining: window.remaining))
                let percent = text("\(window.remaining)%", percentFont, primary)
                percent.draw(at: NSPoint(x: width - 84 - percent.size().width, y: y + 1.5))
                let reset = text(L10n.resetText(window.resetAt, now: now), resetFont, secondary)
                reset.draw(at: NSPoint(x: width - inset - reset.size().width, y: y + 2.5))
                y += rowHeight
            }
        }
        if !speeds.isEmpty {
            y += 8
            divider.setFill()
            NSRect(x: inset, y: y, width: width - inset * 2, height: 0.5).fill()
            y += sectionGap - 8
            text(L10n.speedTitle, labelFont, secondary).draw(at: NSPoint(x: inset, y: y))
            y += speedHeader
            for group in speeds {
                text(group.app, groupFont, primary.withAlphaComponent(0.9)).draw(at: NSPoint(x: inset, y: y + 1))
                y += groupHeader
                if group.models.isEmpty {
                    text("--", labelFont, secondary).draw(at: NSPoint(x: inset + 8, y: y + 2))
                    y += rowHeight
                }
                for speed in group.models {
                    let name = speed.model.isEmpty ? "?" : speed.model
                    text(name, labelFont, secondary).draw(at: NSPoint(x: inset + 8, y: y + 2))
                    let value = text("\(Int(speed.tokensPerSecond.rounded())) tok/s", percentFont, primary)
                    value.draw(at: NSPoint(x: width - 84 - value.size().width, y: y + 1.5))
                    let age = text(L10n.ago(speed.at, now: now), resetFont, secondary)
                    age.draw(at: NSPoint(x: width - inset - age.size().width, y: y + 2.5))
                    y += rowHeight
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return Output(image: context.makeImage(), height: height, bars: bars)
    }
}
