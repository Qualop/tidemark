import AppKit
import TidemarkCore

final class UsageOverlayView: NSView {
    private let config: OverlayConfig
    private(set) var snapshot: UsageSnapshot = .unavailable
    private(set) var darkMode = false
    /// Responsive layouts, widest first. The overlay picks the widest that fits the free
    /// space between the row's controls, so it never covers them.
    enum Layout: Equatable {
        case twoLine            // Codex: label and value above each bar
        case bars(CGFloat)      // one line: "5h ━━ 20% | 7d ━━ 41%" with this bar length
        case text               // one line without bars: "5h 20% | 7d 41%"
        case single             // only the tighter of the two: "5h 20%"
    }

    private(set) var layout: Layout = .twoLine
    var compact: Bool { layout != .twoLine }
    static let compactBarMax: CGFloat = 90  // same length as the two-line bars
    static let compactBarMin: CGFloat = 36
    /// One item = label, 4 pt, bar, 9 pt, value. Items are kept tight inside and
    /// separated by a wider gap with a thin divider, so "5h ━ 20%" reads as one unit.
    private static let compactLabel: CGFloat = 15
    private static let compactLabelGap: CGFloat = 4
    private static let compactValueGap: CGFloat = 9
    private static let compactValue: CGFloat = 28
    private static let compactItemSpacing: CGFloat = 28
    private static var compactItemFixed: CGFloat { compactLabel + compactLabelGap + compactValueGap + compactValue }

    private static var textItem: CGFloat { compactLabel + compactLabelGap + compactValue }

    /// Logical (unscaled) size of each layout.
    static func logicalSize(config: OverlayConfig, layout: Layout) -> NSSize {
        switch layout {
        case .twoLine: return NSSize(width: config.width, height: config.height)
        case .bars(let bar): return NSSize(width: (compactItemFixed + bar) * 2 + compactItemSpacing, height: 18)
        case .text: return NSSize(width: textItem * 2 + compactItemSpacing, height: 18)
        case .single: return NSSize(width: textItem, height: 18)
        }
    }

    /// Widest layout that fits the given logical width, or nil when nothing fits.
    static func layout(fitting width: CGFloat, preferTwoLine: Bool, config: OverlayConfig) -> Layout? {
        if preferTwoLine, width >= config.width { return .twoLine }
        let bar = ((width - compactItemFixed * 2 - compactItemSpacing) / 2).rounded(.down)
        if bar >= compactBarMin { return .bars(min(bar, compactBarMax)) }
        if width >= textItem * 2 + compactItemSpacing { return .text }
        if width >= textItem { return .single }
        return nil
    }

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

    func update(layout: Layout) {
        guard self.layout != layout else { return }
        self.layout = layout
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        switch layout {
        case .twoLine:
            drawItem(logicalX: 0, title: "5h", remaining: snapshot.fiveHourRemaining)
            drawItem(logicalX: 120, title: "7d", remaining: snapshot.weeklyRemaining)
        case .bars, .text:
            let bar: CGFloat
            if case .bars(let length) = layout { bar = length } else { bar = 0 }
            let item = bar > 0 ? Self.compactItemFixed + bar : Self.textItem
            drawCompactItem(logicalX: 0, title: "5h", remaining: snapshot.fiveHourRemaining, bar: bar)
            drawCompactItem(logicalX: item + Self.compactItemSpacing, title: "7d", remaining: snapshot.weeklyRemaining, bar: bar)
            drawCompactDivider(logicalX: item + Self.compactItemSpacing / 2)
        case .single:
            // The tighter window is the one worth seeing.
            let five = snapshot.fiveHourRemaining, week = snapshot.weeklyRemaining
            if let week, five == nil || week < five! {
                drawCompactItem(logicalX: 0, title: "7d", remaining: week, bar: 0)
            } else {
                drawCompactItem(logicalX: 0, title: "5h", remaining: five, bar: 0)
            }
        }
    }

    /// "5h ━━━━ 77%" on one line, vertically centred in the view.
    private func drawCompactItem(logicalX: CGFloat, title: String, remaining: Int?, bar: CGFloat) {
        let scale = CGFloat(config.visualScale)
        let midY = bounds.height / 2
        let titleColor = darkMode
            ? NSColor(calibratedRed: 166 / 255, green: 166 / 255, blue: 166 / 255, alpha: 1)
            : NSColor(calibratedRed: 105 / 255, green: 105 / 255, blue: 105 / 255, alpha: 1)
        let valueColor: NSColor = remaining == nil
            ? (darkMode ? NSColor(calibratedWhite: 145 / 255, alpha: 1) : NSColor(calibratedWhite: 126 / 255, alpha: 1))
            : (darkMode ? NSColor(calibratedWhite: 236 / 255, alpha: 1) : NSColor(calibratedWhite: 36 / 255, alpha: 1))
        let trackColor = darkMode
            ? NSColor(calibratedRed: 75 / 255, green: 75 / 255, blue: 75 / 255, alpha: 1)
            : NSColor(calibratedRed: 218 / 255, green: 218 / 255, blue: 218 / 255, alpha: 1)

        let titleString = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium), .foregroundColor: titleColor,
        ])
        let valueString = NSAttributedString(string: remaining.map { "\($0)%" } ?? "--", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * scale, weight: .semibold), .foregroundColor: valueColor,
        ])
        var x = logicalX * scale
        let titleSize = titleString.size()
        titleString.draw(at: NSPoint(x: x, y: midY - titleSize.height / 2))
        x += min(titleSize.width, Self.compactLabel * scale) + Self.compactLabelGap * scale

        if bar > 0 {
            let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let thickness = max(1 / backingScale, round(3 * scale * backingScale) / backingScale)
            let barWidth = bar * scale
            let barY = (midY - thickness / 2).rounded(.down)
            trackColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barWidth, height: thickness),
                         xRadius: thickness / 2, yRadius: thickness / 2).fill()
            if let remaining, remaining > 0 {
                quotaColor(remaining).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barWidth * CGFloat(remaining) / 100, height: thickness),
                             xRadius: thickness / 2, yRadius: thickness / 2).fill()
            }
            x += barWidth + Self.compactValueGap * scale
        }
        let valueSize = valueString.size()
        valueString.draw(at: NSPoint(x: x, y: midY - valueSize.height / 2))
    }

    private func drawCompactDivider(logicalX: CGFloat) {
        let scale = CGFloat(config.visualScale)
        let height = 10 * scale
        (darkMode ? NSColor(calibratedWhite: 1, alpha: 0.16) : NSColor(calibratedWhite: 0, alpha: 0.14)).setFill()
        NSRect(x: (logicalX * scale).rounded(), y: (bounds.height - height) / 2, width: 1, height: height).fill()
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
