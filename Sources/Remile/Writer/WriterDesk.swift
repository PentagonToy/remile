import AppKit

/// The page viewport and its optional rulers share native scroll coordinates.
@MainActor final class WriterDesk: NSView {
    let scroll = NSScrollView()
    private let horizontal = WriterRuler(horizontal: true)
    private let vertical = WriterRuler(horizontal: false)
    private weak var model: WriterModel?
    private var applying = false
    private var observations: [NSObjectProtocol] = []
    private var centredSize: CGSize = .zero
    private var centredZoom: CGFloat = 0
    private var fitScheduled = false
    private var fittedViewport: CGSize = .zero
    private var fittedPaper: CGSize = .zero
    init(model: WriterModel) {
        self.model = model
        super.init(frame: .zero)
        model.desk = self
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.25; scroll.maxMagnification = 2
        scroll.backgroundColor = NSColor(RemileStyle.background)
        let canvas = WriterCanvas(model: model); canvas.autoresizingMask = [.width]
        scroll.documentView = canvas; model.canvas = canvas
        horizontal.canvas = canvas; vertical.canvas = canvas
        addSubview(scroll); addSubview(horizontal); addSubview(vertical)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleFit() }
        })
        for name in [NSView.boundsDidChangeNotification, NSScrollView.didEndLiveMagnifyNotification] {
            let object: Any = name == NSView.boundsDidChangeNotification ? scroll.contentView : scroll
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    if abs((self.model?.zoom ?? 1) - self.scroll.magnification) > 0.001 { self.model?.setZoom(self.scroll.magnification) }
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
        scheduleFit()
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
    private func scheduleFit() {
        let size = scroll.contentView.frame.size
        guard let model, model.fitMode != nil, !fitScheduled, size.width > 0, size.height > 0,
              abs(size.width - fittedViewport.width) > 0.5 || abs(size.height - fittedViewport.height) > 0.5
                  || model.pageSize != fittedPaper else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitScheduled = false
            if let mode = self.model?.fitMode { self.fitPage(mode) }
        }
    }
    func fitPage(_ mode: PageFit) {
        guard let model, let canvas = scroll.documentView as? WriterCanvas else { return }
        let size = scroll.contentView.frame.size, insets = WriterCanvas.pageInsets
        guard size.width > 0, size.height > 0 else { return }
        let visible = scroll.documentVisibleRect
        let page = canvas.sheets.min { abs($0.frame.midY - visible.midY) < abs($1.frame.midY - visible.midY) }
        let width = size.width / (model.pageSize.width + 2 * insets.width)
        let height = size.height / (model.pageSize.height + 2 * insets.height)
        fittedViewport = size; fittedPaper = model.pageSize
        applying = true; defer { applying = false }
        model.setZoom(mode.scale(width: width, height: height), fit: mode)
        if abs(scroll.magnification - model.zoom) > 0.001 {
            scroll.setMagnification(model.zoom, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        }
        alignViewport(force: true, centredPage: mode == .width ? nil : page)
    }
    private func alignViewport(force: Bool = false, centredPage: WriterPaper? = nil) {
        let size = scroll.contentView.frame.size, zoom = scroll.magnification
        let centreHorizontally = force || abs(size.width - centredSize.width) > 0.5 || abs(zoom - centredZoom) > 0.001
        guard size.width > 0, centreHorizontally || abs(size.height - centredSize.height) > 0.5,
              let canvas = scroll.documentView as? WriterCanvas else { return }
        canvas.fitViewport()
        let visible = scroll.documentVisibleRect
        guard visible.width > 0, let page = canvas.sheets.first else { return }
        let x = centreHorizontally
            ? min(max(0, canvas.bounds.width - visible.width), max(0, page.frame.midX - visible.width / 2))
            : visible.minX
        let y = centredPage.map { min(max(0, canvas.bounds.height - visible.height), max(0, $0.frame.midY - visible.height / 2)) } ?? visible.minY
        scroll.contentView.scroll(to: CGPoint(x: x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        centredSize = size; centredZoom = zoom
    }
    func suspend() {
        if model?.desk === self { model?.desk = nil }
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
