import AppKit

/// The page viewport and its optional rulers share native scroll coordinates.
@MainActor final class WriterDesk: NSView {
    let scroll = NSScrollView()
    private let horizontal = WriterRuler(horizontal: true)
    private let vertical = WriterRuler(horizontal: false)
    private weak var model: WriterModel?
    private var applying = false
    private var observations: [NSObjectProtocol] = []
    private var centredWidth: CGFloat = 0
    private var centredZoom: CGFloat = 0
    init(model: WriterModel) {
        self.model = model
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.25; scroll.maxMagnification = 2
        scroll.backgroundColor = NSColor(RemileStyle.background)
        let canvas = WriterCanvas(model: model); canvas.autoresizingMask = [.width]
        scroll.documentView = canvas; model.canvas = canvas
        horizontal.canvas = canvas; vertical.canvas = canvas
        addSubview(scroll); addSubview(horizontal); addSubview(vertical)
        scroll.contentView.postsBoundsChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSScrollView.didEndLiveMagnifyNotification] {
            let object: Any = name == NSView.boundsDidChangeNotification ? scroll.contentView : scroll
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    if abs((self.model?.zoom ?? 1) - self.scroll.magnification) > 0.001 { self.model?.zoom = self.scroll.magnification }
                    self.horizontal.needsDisplay = true; self.vertical.needsDisplay = true
                }
            })
        }
        canvas.rebuild(); update()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let edge: CGFloat = model?.showRulers == true ? 24 : 0
        scroll.frame = CGRect(x: 0, y: edge, width: max(0, bounds.width - edge), height: max(0, bounds.height - edge))
        horizontal.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - edge), height: edge)
        vertical.frame = CGRect(x: bounds.width - edge, y: edge, width: edge, height: max(0, bounds.height - edge))
        horizontal.needsDisplay = true; vertical.needsDisplay = true
        alignViewport()
    }
    func update() {
        applying = true; defer { applying = false }
        horizontal.isHidden = model?.showRulers != true; vertical.isHidden = horizontal.isHidden
        needsLayout = true; layoutSubtreeIfNeeded()
        if let zoom = model?.zoom, abs(scroll.magnification - zoom) > 0.001 {
            let rect = scroll.documentVisibleRect
            scroll.setMagnification(zoom, centeredAt: CGPoint(x: rect.midX, y: rect.midY))
        }
        (scroll.documentView as? WriterCanvas)?.synchronise()
        alignViewport()
    }
    private func alignViewport() {
        let width = scroll.contentSize.width, zoom = scroll.magnification
        guard width > 0, abs(width - centredWidth) > 0.5 || abs(zoom - centredZoom) > 0.001,
              let canvas = scroll.documentView as? WriterCanvas else { return }
        canvas.fitViewport()
        let visible = scroll.documentVisibleRect
        guard visible.width > 0, let page = canvas.sheets.first else { return }
        let x = min(max(0, canvas.bounds.width - visible.width), max(0, page.frame.midX - visible.width / 2))
        scroll.contentView.scroll(to: CGPoint(x: x, y: visible.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        centredWidth = width; centredZoom = zoom
    }
    func suspend() {
        observations.forEach { NotificationCenter.default.removeObserver($0) }; observations = []
        (scroll.documentView as? WriterCanvas)?.suspend(); scroll.documentView = nil
    }
    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// Read-only centimetre marks. Rulers never change margins or document content.
@MainActor private final class WriterRuler: NSView {
    weak var canvas: WriterCanvas?
    let horizontal: Bool
    init(horizontal: Bool) { self.horizontal = horizontal; super.init(frame: .zero); setAccessibilityLabel(horizontal ? "Horizontal ruler in centimetres" : "Vertical ruler in centimetres") }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(RemileStyle.editorBar).setFill(); bounds.fill()
        guard let canvas, !canvas.sheets.isEmpty else { return }
        let page = canvas.sheets[min(canvas.currentPage, canvas.sheets.count - 1)]
        let length = horizontal ? page.bounds.width : page.bounds.height
        let ink = NSColor(RemileStyle.secondaryInk)
        let path = NSBezierPath(); path.lineWidth = 0.5
        for half in 0...Int(length / (72 / 2.54 / 2)) {
            let distance = CGFloat(half) * 72 / 2.54 / 2
            let point = convert(horizontal ? CGPoint(x: distance, y: 0) : CGPoint(x: 0, y: distance), from: page)
            let coordinate = horizontal ? point.x : point.y
            guard coordinate >= 0, coordinate <= (horizontal ? bounds.width : bounds.height) else { continue }
            let major = half.isMultiple(of: 2), tick: CGFloat = major ? 7 : 4
            path.move(to: horizontal ? CGPoint(x: coordinate, y: bounds.height) : CGPoint(x: 0, y: coordinate))
            path.line(to: horizontal ? CGPoint(x: coordinate, y: bounds.height - tick) : CGPoint(x: tick, y: coordinate))
            if major {
                let label = String(half / 2) as NSString
                label.draw(at: horizontal ? CGPoint(x: coordinate + 3, y: 2) : CGPoint(x: 9, y: coordinate + 2), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: ink])
            }
        }
        ink.setStroke(); path.stroke()
    }
}
