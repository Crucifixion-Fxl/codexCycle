import AppKit

enum StatusIndicatorMetrics {
    static let ringLineWidth: CGFloat = 2.2
    static let trackLineWidth: CGFloat = 2
    static let glassInset: CGFloat = 1.5

    static func ringRadius(for minimumDimension: CGFloat) -> CGFloat {
        max(0, (minimumDimension - ringLineWidth) / 2)
    }

    static func glassDiameter(for minimumDimension: CGFloat) -> CGFloat {
        max(0, minimumDimension - glassInset * 2)
    }

    static func fontSize(forCharacterCount count: Int) -> CGFloat {
        switch count {
        case 1:
            11
        case 2:
            10
        default:
            8.6
        }
    }
}

final class StatusIndicatorView: NSView {
    private let glassContainer = NSView()
    private let overlayView = IndicatorOverlayView()
    private var nativeGlassView: NSView?

    var remainingPercent: Int? {
        didSet { overlayView.needsDisplay = true }
    }

    var isStale = true {
        didSet { overlayView.needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureGlass()
        overlayView.indicator = self
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView, positioned: .above, relativeTo: glassContainer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let diameter = StatusIndicatorMetrics.glassDiameter(
            for: min(bounds.width, bounds.height)
        )
        let frame = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        glassContainer.frame = frame
        nativeGlassView?.frame = glassContainer.bounds
        nativeGlassView?.layer?.cornerRadius = diameter / 2
        overlayView.frame = bounds
    }

    @objc private func displayOptionsChanged() {
        configureGlass()
        overlayView.needsDisplay = true
    }

    private var usesSolidAccessibilityFace: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private func configureGlass() {
        glassContainer.removeFromSuperview()
        nativeGlassView = nil
        glassContainer.subviews.forEach { $0.removeFromSuperview() }

        addSubview(glassContainer, positioned: .below, relativeTo: nil)
        glassContainer.wantsLayer = true
        glassContainer.layer?.masksToBounds = true
        glassContainer.layer?.backgroundColor = nil

        guard !usesSolidAccessibilityFace else {
            glassContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            needsLayout = true
            return
        }

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: glassContainer.bounds)
            glass.style = .clear
            glass.cornerRadius = glassContainer.bounds.width / 2
            glass.tintColor = NSColor.white.withAlphaComponent(0.04)
            glass.autoresizingMask = [.width, .height]
            glassContainer.addSubview(glass)
            nativeGlassView = glass
        } else {
            let effect = NSVisualEffectView(frame: glassContainer.bounds)
            effect.material = .menu
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = glassContainer.bounds.width / 2
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            glassContainer.addSubview(effect)
            nativeGlassView = effect
        }

        needsLayout = true
    }

    fileprivate func drawIndicator() {
        if usesSolidAccessibilityFace {
            drawSolidGlassFallback()
        } else if #unavailable(macOS 26.0) {
            drawGlassHighlight()
        }

        drawTrack()
        drawProgress()
        drawValue()
    }

    private func circleGeometry() -> (center: NSPoint, radius: CGFloat) {
        return (
            NSPoint(x: bounds.midX, y: bounds.midY),
            StatusIndicatorMetrics.ringRadius(
                for: min(bounds.width, bounds.height)
            )
        )
    }

    private func drawTrack() {
        let geometry = circleGeometry()
        let path = NSBezierPath()
        path.appendArc(
            withCenter: geometry.center,
            radius: geometry.radius,
            startAngle: 0,
            endAngle: 360
        )
        path.lineWidth = StatusIndicatorMetrics.trackLineWidth
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        path.stroke()
    }

    private func drawProgress() {
        guard let remainingPercent, remainingPercent > 0 else {
            return
        }

        let geometry = circleGeometry()
        let normalized = min(1, max(0, Double(remainingPercent) / 100))
        let segmentCount = max(1, Int(ceil(normalized * 120)))

        for index in 0..<segmentCount {
            let lower = normalized * Double(index) / Double(segmentCount)
            let upper = normalized * Double(index + 1) / Double(segmentCount)
            let midpointPercent = ((lower + upper) / 2) * 100
            let components = UsageGradient.color(at: midpointPercent)

            let path = NSBezierPath()
            path.appendArc(
                withCenter: geometry.center,
                radius: geometry.radius,
                startAngle: 90 - 360 * lower,
                endAngle: 90 - 360 * upper,
                clockwise: true
            )
            path.lineWidth = StatusIndicatorMetrics.ringLineWidth
            path.lineCapStyle = .round

            let color: NSColor
            if isStale {
                color = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
            } else {
                color = NSColor(
                    calibratedRed: components.red,
                    green: components.green,
                    blue: components.blue,
                    alpha: 1
                )
            }
            color.setStroke()
            path.stroke()
        }
    }

    private func drawValue() {
        let text = remainingPercent.map(String.init) ?? "—"
        let fontSize = StatusIndicatorMetrics.fontSize(
            forCharacterCount: text.count
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: isStale ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        attributed.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2 + 0.5
            )
        )
    }

    private func drawSolidGlassFallback() {
        let diameter = StatusIndicatorMetrics.glassDiameter(
            for: min(bounds.width, bounds.height)
        )
        let rect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    private func drawGlassHighlight() {
        let diameter = StatusIndicatorMetrics.glassDiameter(
            for: min(bounds.width, bounds.height)
        )
        let rect = NSRect(
            x: bounds.midX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.white.withAlphaComponent(0.28).setStroke()
        let highlight = NSBezierPath()
        highlight.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: diameter / 2 - 0.5,
            startAngle: 35,
            endAngle: 145
        )
        highlight.lineWidth = 0.7
        highlight.stroke()
    }
}

private final class IndicatorOverlayView: NSView {
    weak var indicator: StatusIndicatorView?

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        indicator?.drawIndicator()
    }
}
