import SwiftUI

/// Each row fills the banner width, including a final row with fewer cards.
struct HomeCardLayout: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrangement(width proposedWidth: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard !subviews.isEmpty else { return (.zero, []) }
        let idealWidth = CGFloat(subviews.count) * minimumWidth + CGFloat(subviews.count - 1) * spacing
        let width = max(0, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth)
        let columns = min(subviews.count, max(1, Int((width + spacing) / (minimumWidth + spacing))))
        var frames: [CGRect] = [], y: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let count = min(columns, subviews.count - start)
            let cardWidth = max(0, (width - CGFloat(count - 1) * spacing) / CGFloat(count))
            let height = (start..<(start + count)).map { subviews[$0].sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height }.max() ?? 0
            for column in 0..<count { frames.append(CGRect(x: CGFloat(column) * (cardWidth + spacing), y: y, width: cardWidth, height: height)) }
            y += height + spacing
        }
        return (CGSize(width: width, height: max(0, y - spacing)), frames)
    }
}
