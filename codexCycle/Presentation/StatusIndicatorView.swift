import AppKit

enum StatusIndicatorMetrics {
    static let statusItemWidth: CGFloat = 34
    static let ringLineWidth: CGFloat = 2.2
    static let trackLineWidth: CGFloat = 2
    static let glassInset: CGFloat = 1.5

    static func ringRect(in bounds: NSRect) -> NSRect {
        safeInset(bounds, by: ringLineWidth / 2)
    }

    static func glassRect(in bounds: NSRect) -> NSRect {
        safeInset(bounds, by: glassInset)
    }

    static func fontSize(forCharacterCount count: Int) -> CGFloat {
        switch count {
        case 1:
            13
        case 2:
            12
        default:
            10.6
        }
    }

    private static func safeInset(_ bounds: NSRect, by inset: CGFloat) -> NSRect {
        guard
            bounds.origin.x.isFinite,
            bounds.origin.y.isFinite,
            bounds.width.isFinite,
            bounds.height.isFinite
        else {
            return .zero
        }

        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            return NSRect(
                x: bounds.midX,
                y: bounds.midY,
                width: 0,
                height: 0
            )
        }

        return bounds.insetBy(dx: inset, dy: inset)
    }
}

struct CapsuleRingGeometry {
    let rect: NSRect

    private var radius: CGFloat {
        max(0, min(rect.width, rect.height) / 2)
    }

    private var straightLength: CGFloat {
        max(0, rect.width - radius * 2)
    }

    var perimeter: CGFloat {
        straightLength * 2 + 2 * .pi * radius
    }

    func point(at fraction: Double) -> NSPoint {
        guard perimeter > 0 else {
            return NSPoint(x: rect.midX, y: rect.midY)
        }

        let progress = min(1, max(0, fraction))
        var distance = CGFloat(progress) * perimeter
        let halfStraight = straightLength / 2

        if distance <= halfStraight {
            return NSPoint(x: rect.midX + distance, y: rect.maxY)
        }
        distance -= halfStraight

        let arcLength = .pi * radius
        if distance <= arcLength {
            let angle = .pi / 2 - distance / radius
            return NSPoint(
                x: rect.maxX - radius + cos(angle) * radius,
                y: rect.midY + sin(angle) * radius
            )
        }
        distance -= arcLength

        if distance <= straightLength {
            return NSPoint(
                x: rect.maxX - radius - distance,
                y: rect.minY
            )
        }
        distance -= straightLength

        if distance <= arcLength {
            let angle = -.pi / 2 - distance / radius
            return NSPoint(
                x: rect.minX + radius + cos(angle) * radius,
                y: rect.midY + sin(angle) * radius
            )
        }
        distance -= arcLength

        return NSPoint(
            x: min(rect.midX, rect.minX + radius + distance),
            y: rect.maxY
        )
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
        glassContainer.frame = StatusIndicatorMetrics.glassRect(in: bounds)
        nativeGlassView?.frame = glassContainer.bounds
        let cornerRadius = glassContainer.bounds.height / 2
        nativeGlassView?.layer?.cornerRadius = cornerRadius
        if #available(macOS 26.0, *),
           let glass = nativeGlassView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
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
            glass.cornerRadius = glassContainer.bounds.height / 2
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
            effect.layer?.cornerRadius = glassContainer.bounds.height / 2
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            glassContainer.addSubview(effect)
            nativeGlassView = effect
        }

        needsLayout = true
    }

    fileprivate func drawIndicator() {
        guard
            bounds.width > StatusIndicatorMetrics.ringLineWidth,
            bounds.height > StatusIndicatorMetrics.ringLineWidth
        else {
            return
        }

        if usesSolidAccessibilityFace {
            drawSolidGlassFallback()
        } else if #unavailable(macOS 26.0) {
            drawGlassHighlight()
        }

        drawTrack()
        drawProgress()
        drawValue()
    }

    private func capsulePath(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(
            roundedRect: rect,
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        )
    }

    private func drawTrack() {
        let path = capsulePath(
            in: StatusIndicatorMetrics.ringRect(in: bounds)
        )
        path.lineWidth = StatusIndicatorMetrics.trackLineWidth
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        path.stroke()
    }

    private func drawProgress() {
        guard let remainingPercent, remainingPercent > 0 else {
            return
        }

        let geometry = CapsuleRingGeometry(
            rect: StatusIndicatorMetrics.ringRect(in: bounds)
        )
        let normalized = min(1, max(0, Double(remainingPercent) / 100))
        let segmentCount = max(
            1,
            Int(ceil(normalized * Double(geometry.perimeter * 2)))
        )

        for index in 0..<segmentCount {
            let lower = normalized * Double(index) / Double(segmentCount)
            let upper = normalized * Double(index + 1) / Double(segmentCount)
            let midpointPercent = ((lower + upper) / 2) * 100
            let components = UsageGradient.color(at: midpointPercent)
            let startPoint = geometry.point(at: lower)
            let endPoint = geometry.point(at: upper)

            let path = NSBezierPath()
            path.move(to: startPoint)
            path.line(to: endPoint)
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
        let rect = StatusIndicatorMetrics.glassRect(in: bounds)
        let path = capsulePath(in: rect)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        capsulePath(in: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    private func drawGlassHighlight() {
        let rect = StatusIndicatorMetrics.glassRect(in: bounds)
        NSColor.white.withAlphaComponent(0.28).setStroke()
        let highlight = NSBezierPath()
        highlight.move(
            to: NSPoint(
                x: rect.minX + rect.height / 2,
                y: rect.maxY - 0.5
            )
        )
        highlight.line(
            to: NSPoint(
                x: rect.maxX - rect.height / 2,
                y: rect.maxY - 0.5
            )
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
