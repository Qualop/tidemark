import AppKit
import QuartzCore
import TidemarkCore

struct HoverSection {
    let title: String
    let color: NSColor
    let active: Bool
    let windows: [QuotaWindow]
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

/// Hover card with every provider's quota. A droplet forms just above the middle of the
/// overlay, rises a little, then spreads into the card; blur, border and shadow share that one
/// animated shape. Everything is built on first hover, driven by Core Animation, and the
/// bitmap is dropped again when hidden.
final class HoverCardController {
    private static let margin: CGFloat = 24 // room for the shadow
    private static let width: CGFloat = 240
    private static let gap: CGFloat = 6
    /// Spread phase: Apple's "smooth" spring (critically damped, 0.25 s response). No bounce.
    private static let spreadStiffness: CGFloat = 631
    private static let spreadDamping: CGFloat = 50.2
    private static let riseDuration: CFTimeInterval = 0.07
    private static let radius: CGFloat = 12

    private let anchorFrame: () -> NSRect?
    private let sections: () -> [HoverSection]
    private let darkMode: () -> Bool
    private var panel: PassivePanel?
    private var blurView: NSVisualEffectView?
    private let shadow = CALayer()
    private let blurMask = CAShapeLayer()
    private let contentMask = CAShapeLayer()
    private let border = CAShapeLayer()
    private let tint = CALayer()
    private let inner = CALayer()
    private let content = CALayer()
    private var fills: [CALayer] = []
    private var cardRect = CGRect.zero
    private var monitor: Any?
    private var generation = 0
    private(set) var visible = false

    init(anchorFrame: @escaping () -> NSRect?, sections: @escaping () -> [HoverSection], darkMode: @escaping () -> Bool) {
        self.anchorFrame = anchorFrame
        self.sections = sections
        self.darkMode = darkMode
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
        guard visible, let panel, let anchor = anchorFrame() else { return }
        panel.setFrameOrigin(origin(for: panel.frame.size, anchor: anchor))
    }

    func hide(animated: Bool) {
        guard visible else { return }
        visible = false
        generation += 1
        let current = generation
        guard animated else {
            finishHide()
            return
        }
        let seed = dropletPath(rising: false)
        let ease = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current, !self.visible else { return }
            self.finishHide()
        }
        for layer in [blurMask, contentMask, border] {
            let shrink = CABasicAnimation(keyPath: "path")
            shrink.fromValue = layer.presentation()?.path ?? layer.path
            shrink.duration = 0.12
            shrink.timingFunction = ease
            layer.path = seed
            layer.add(shrink, forKey: "shape")
        }
        let shadowShrink = CABasicAnimation(keyPath: "shadowPath")
        shadowShrink.fromValue = shadow.presentation()?.shadowPath ?? shadow.shadowPath
        shadowShrink.duration = 0.12
        shadowShrink.timingFunction = ease
        shadow.shadowPath = seed
        shadow.add(shadowShrink, forKey: "shape")
        fade(inner, to: 0, duration: 0.06)
        fade(shadow, to: 0, duration: 0.12)
        CATransaction.commit()
    }

    // MARK: Private

    private func pointerMoved() {
        guard let anchor = anchorFrame() else {
            hide(animated: false)
            return
        }
        let inside = anchor.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if inside, !visible {
            show(anchor: anchor)
        } else if !inside, visible {
            hide(animated: true)
        }
    }

    private func show(anchor: NSRect) {
        visible = true
        generation += 1
        let panel = self.panel ?? makePanel()
        let dark = darkMode()
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.backingScaleFactor ?? 2
        let rendered = HoverCardRenderer.render(sections(), width: Self.width, dark: dark, scale: scale)
        let panelSize = CGSize(width: Self.width + Self.margin * 2, height: rendered.height + Self.margin * 2)
        cardRect = CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: rendered.height)
        panel.setFrame(NSRect(origin: origin(for: panelSize, anchor: anchor), size: panelSize), display: false)
        blurView?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let full = CGPath(roundedRect: cardRect, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [blurMask, contentMask, border, shadow, inner] { layer.removeAllAnimations() }
        for layer in [blurMask, contentMask, border] { layer.path = full }
        shadow.shadowPath = full
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: dark ? 0.5 : 0.2).cgColor
        shadow.opacity = 1
        border.strokeColor = (dark ? NSColor(calibratedWhite: 1, alpha: 0.12) : NSColor(calibratedWhite: 0, alpha: 0.10)).cgColor
        tint.frame = cardRect
        tint.backgroundColor = (dark
            ? NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.45)
            : NSColor(calibratedWhite: 1, alpha: 0.55)).cgColor
        inner.frame = cardRect
        inner.opacity = 1
        content.frame = inner.bounds
        content.contentsScale = scale
        content.contents = rendered.image
        inner.sublayers?.filter { $0 !== content }.forEach { $0.removeFromSuperlayer() }
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
            inner.addSublayer(track)
            fills.append(fill)
        }
        CATransaction.commit()

        panel.orderFrontRegardless()

        // Droplet: a seed forms above the overlay's centre, rises into a drop, then spreads.
        for layer in [blurMask, contentMask, border] { layer.add(dropletAnimation("path", to: full), forKey: "shape") }
        shadow.add(dropletAnimation("shadowPath", to: full), forKey: "shape")

        let now = CACurrentMediaTime()
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0
        reveal.toValue = 1
        reveal.beginTime = now + Self.riseDuration + 0.03
        reveal.duration = 0.12
        reveal.fillMode = .backwards
        inner.add(reveal, forKey: "fade")

        let settle = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        for (index, fill) in fills.enumerated() {
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = 0
            grow.toValue = fill.bounds.width
            grow.beginTime = now + Self.riseDuration + 0.05 + Double(index) * 0.02
            grow.duration = 0.26
            grow.timingFunction = settle
            grow.fillMode = .backwards
            fill.add(grow, forKey: "grow")
        }
    }

    /// Seed -> drop (quick ease-out), then drop -> card (critically damped spring).
    private func dropletAnimation(_ keyPath: String, to full: CGPath) -> CAAnimation {
        let rise = CABasicAnimation(keyPath: keyPath)
        rise.fromValue = dropletPath(rising: false)
        rise.toValue = dropletPath(rising: true)
        rise.duration = Self.riseDuration
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let spread = CASpringAnimation(keyPath: keyPath)
        spread.mass = 1
        spread.stiffness = Self.spreadStiffness
        spread.damping = Self.spreadDamping
        spread.fromValue = dropletPath(rising: true)
        spread.toValue = full
        spread.beginTime = Self.riseDuration
        spread.duration = 0.32 // the critically damped tail is under a point after this
        let group = CAAnimationGroup()
        group.animations = [rise, spread]
        group.duration = Self.riseDuration + spread.duration
        return group
    }

    /// The droplet the card grows from and shrinks back into, centred on the card's bottom
    /// edge (just above the middle of the overlay). Built with the same CGPath primitive as
    /// the card so the shapes interpolate cleanly.
    private func dropletPath(rising: Bool) -> CGPath {
        let size = rising ? CGSize(width: 16, height: 20) : CGSize(width: 10, height: 8)
        let lift: CGFloat = rising ? 5 : 0
        let rect = CGRect(x: cardRect.midX - size.width / 2, y: cardRect.minY + lift,
                          width: size.width, height: size.height)
        let radius = min(size.width, size.height) / 2 - 0.1
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func fade(_ layer: CALayer, to value: Float, duration: CFTimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = value
        animation.duration = duration
        layer.opacity = value
        layer.add(animation, forKey: "fade")
    }

    private func finishHide() {
        panel?.orderOut(nil)
        for layer in [blurMask, contentMask, border, shadow, inner] { layer.removeAllAnimations() }
        content.contents = nil // drop the bitmap while hidden
        inner.sublayers?.filter { $0 !== content }.forEach { $0.removeFromSuperlayer() }
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let container = NSView()
        container.wantsLayer = true

        let shadowHost = hostingView(root: shadow)
        shadow.shadowOpacity = 1
        shadow.shadowRadius = 16
        shadow.shadowOffset = CGSize(width: 0, height: -6)

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.mask = blurMask
        blur.autoresizingMask = [.width, .height]
        blurView = blur

        let contentRoot = CALayer()
        contentRoot.mask = contentMask
        content.contentsGravity = .resize
        inner.addSublayer(content)
        border.fillColor = nil
        border.lineWidth = 1
        contentRoot.addSublayer(tint)
        contentRoot.addSublayer(inner)
        contentRoot.addSublayer(border)
        let contentHost = hostingView(root: contentRoot)

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
        root.frame = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
        host.layer = layer
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        return host
    }

    private func origin(for size: CGSize, anchor: NSRect) -> NSPoint {
        // Card is centred over the overlay; its bottom edge sits just above it.
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

    static func render(_ sections: [HoverSection], width: CGFloat, dark: Bool, scale: CGFloat, now: Date = Date()) -> Output {
        var height: CGFloat = 12 + 8
        for (index, section) in sections.enumerated() {
            height += (index > 0 ? sectionGap : 0) + headerHeight + CGFloat(max(section.windows.count, 1)) * rowHeight
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
            text(section.title, titleFont, section.color).draw(at: NSPoint(x: inset + 14, y: y))
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
        NSGraphicsContext.restoreGraphicsState()
        return Output(image: context.makeImage(), height: height, bars: bars)
    }
}
