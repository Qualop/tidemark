import AppKit
import TidemarkCore

final class UsageOverlayView: NSView {
    private let config: OverlayConfig
    private(set) var snapshot: UsageSnapshot = .unavailable
    private(set) var darkMode = false

    override var isOpaque: Bool { false }

    init(config: OverlayConfig) {
        self.config = config
        let size = NSSize(width: config.width * config.visualScale, height: config.height * config.visualScale)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(snapshot: UsageSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        needsDisplay = true
    }

    func update(darkMode: Bool) {
        guard self.darkMode != darkMode else { return }
        self.darkMode = darkMode
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawItem(logicalX: 0, title: "5h", remaining: snapshot.fiveHourRemaining)
        drawItem(logicalX: 120, title: "7d", remaining: snapshot.weeklyRemaining)
    }

    private func drawItem(logicalX: CGFloat, title: String, remaining: Int?) {
        let scale = CGFloat(config.visualScale)
        let logicalItemWidth: CGFloat = 101
        let contentWidth = logicalItemWidth * 0.90
        let contentInset = (logicalItemWidth - contentWidth) / 2
        let left = (logicalX + contentInset) * scale
        let width = contentWidth * scale

        let titleColor = darkMode
            ? NSColor(calibratedRed: 166 / 255, green: 166 / 255, blue: 166 / 255, alpha: 1)
            : NSColor(calibratedRed: 105 / 255, green: 105 / 255, blue: 105 / 255, alpha: 1)
        let valueColor: NSColor
        if remaining == nil {
            valueColor = darkMode
                ? NSColor(calibratedRed: 145 / 255, green: 145 / 255, blue: 145 / 255, alpha: 1)
                : NSColor(calibratedRed: 126 / 255, green: 126 / 255, blue: 126 / 255, alpha: 1)
        } else {
            valueColor = darkMode
                ? NSColor(calibratedRed: 236 / 255, green: 236 / 255, blue: 236 / 255, alpha: 1)
                : NSColor(calibratedRed: 36 / 255, green: 36 / 255, blue: 36 / 255, alpha: 1)
        }
        let trackColor = darkMode
            ? NSColor(calibratedRed: 75 / 255, green: 75 / 255, blue: 75 / 255, alpha: 1)
            : NSColor(calibratedRed: 218 / 255, green: 218 / 255, blue: 218 / 255, alpha: 1)

        let titleFont = NSFont.systemFont(ofSize: 7.5 * scale, weight: .regular)
        let valueFont = NSFont.systemFont(ofSize: 8.25 * scale, weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph,
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: valueColor,
            .paragraphStyle: paragraph,
        ]
        let valueText = remaining.map { "\($0)%" } ?? "--"
        let titleString = NSAttributedString(string: title, attributes: titleAttributes)
        let valueString = NSAttributedString(string: valueText, attributes: valueAttributes)
        let titleSize = titleString.size()
        let valueSize = valueString.size()
        let topInset = 0.5 * scale

        titleString.draw(at: NSPoint(x: left, y: bounds.height - topInset - titleSize.height))
        valueString.draw(at: NSPoint(x: left + width - valueSize.width, y: bounds.height - topInset - valueSize.height))

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let idealThickness = 2.5 * scale
        let thickness = max(1 / backingScale, round(idealThickness * backingScale) / backingScale)
        let barTop = 17 * scale
        let barY = bounds.height - barTop - thickness
        let trackRect = NSRect(x: left, y: barY, width: width, height: thickness)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: thickness / 2, yRadius: thickness / 2)
        trackColor.setFill()
        track.fill()

        guard let remaining, remaining > 0 else { return }
        let activeWidth = width * CGFloat(remaining) / 100
        let activeRect = NSRect(x: left, y: barY, width: activeWidth, height: thickness)
        let active = NSBezierPath(roundedRect: activeRect, xRadius: thickness / 2, yRadius: thickness / 2)
        quotaColor(remaining).setFill()
        active.fill()
    }

}

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
