import Foundation

struct WriterGuide: Equatable {
    enum Axis { case x, y }
    var axis: Axis
    var position: CGFloat
}

/// Alignment is page-local and bounded by the current page's objects and text rows.
enum WriterAlignment {
    static func constrained(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        abs(point.x - anchor.x) >= abs(point.y - anchor.y) ? CGPoint(x: point.x, y: anchor.y) : CGPoint(x: anchor.x, y: point.y)
    }
    static func snap(_ bounds: CGRect, page: CGSize, neighbours: [CGRect], baselines: [CGFloat], tolerance: CGFloat) -> (CGPoint, [WriterGuide]) {
        let xTargets = [CGFloat(56), page.width / 2, page.width - 56] + neighbours.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let yTargets = [CGFloat(56), page.height / 2, page.height - 56] + neighbours.flatMap { [$0.minY, $0.midY, $0.maxY] } + baselines.prefix(256)
        func nearest(_ origins: [CGFloat], _ targets: [CGFloat], axis: WriterGuide.Axis) -> (CGFloat, WriterGuide?) {
            var delta = tolerance + 1, guide: WriterGuide?
            for origin in origins { for target in targets where abs(target - origin) < abs(delta) { delta = target - origin; guide = WriterGuide(axis: axis, position: target) } }
            return abs(delta) <= tolerance ? (delta, guide) : (0, nil)
        }
        let x = nearest([bounds.minX, bounds.midX, bounds.maxX], xTargets, axis: .x)
        let y = nearest([bounds.minY, bounds.midY, bounds.maxY], yTargets, axis: .y)
        return (CGPoint(x: x.0, y: y.0), [x.1, y.1].compactMap { $0 })
    }
}
