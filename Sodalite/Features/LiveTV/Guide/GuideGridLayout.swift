#if !os(macOS)
// The guide grid is a UICollectionView driven by the focus engine. macOS has neither, and the Mac draws the channel lineup instead (GuideView).
import UIKit

/// Per-program geometry, supplied by the view controller from `GuideViewModel`.
protocol GuideGridLayoutDelegate: AnyObject {
    func guideRowCount() -> Int
    func guideItemCount(section: Int) -> Int
    /// Content-space x and width in the program area's own coordinates (x 0 is the axis start).
    func guideItemXWidth(section: Int, item: Int) -> (x: CGFloat, width: CGFloat)
}

/// Program cells only. The channel column and the ruler are sibling views, so this layout owns no
/// pinned supplementaries and therefore never invalidates on scroll.
final class GuideGridLayout: UICollectionViewLayout {

    static let nowLineKind = "GuideNowLine"
    static let gridLineKind = "GuideGridLine"

    weak var delegate: GuideGridLayoutDelegate?

    var rowHeight: CGFloat = 100
    /// Axis span times points per minute.
    var totalWidth: CGFloat = 0
    var nowX: CGFloat = 0
    /// Content-space x of every half-hour line, matching the ruler's chip edges.
    var gridlineXs: [CGFloat] = []

    private var cellAttributes: [[UICollectionViewLayoutAttributes]] = []
    private var gridlineAttributes: [UICollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let delegate else {
            cellAttributes = []
            gridlineAttributes = []
            return
        }
        let sections = delegate.guideRowCount()
        contentHeight = CGFloat(sections) * rowHeight
        cellAttributes = (0..<sections).map { section in
            let y = CGFloat(section) * rowHeight
            return (0..<delegate.guideItemCount(section: section)).map { item in
                let (x, width) = delegate.guideItemXWidth(section: section, item: item)
                let attributes = UICollectionViewLayoutAttributes(
                    forCellWith: IndexPath(item: item, section: section))
                attributes.frame = CGRect(x: x, y: y, width: max(width, 1), height: rowHeight)
                return attributes
            }
        }
        // Gridlines span the full content height at zIndex -1 so programs and the now line draw on top.
        gridlineAttributes = gridlineXs.enumerated().map { index, x in
            let attributes = UICollectionViewLayoutAttributes(
                forDecorationViewOfKind: Self.gridLineKind, with: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: x, y: 0, width: 1, height: contentHeight)
            attributes.zIndex = -1
            return attributes
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(totalWidth, 1), height: contentHeight)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section < cellAttributes.count,
              indexPath.item < cellAttributes[indexPath.section].count else { return nil }
        return cellAttributes[indexPath.section][indexPath.item]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let sectionCount = cellAttributes.count
        guard sectionCount > 0, rowHeight > 0 else { return [] }
        var result = gridlineAttributes.filter { $0.frame.intersects(rect) }
        let firstRow = max(0, Int(rect.minY / rowHeight))
        let lastRow = min(sectionCount - 1, Int(rect.maxY / rowHeight))
        if firstRow <= lastRow {
            for section in firstRow...lastRow {
                result.append(contentsOf: cellAttributes[section].filter { $0.frame.intersects(rect) })
            }
        }
        if let now = nowLineAttributes(), now.frame.intersects(rect) { result.append(now) }
        return result
    }

    override func layoutAttributesForDecorationView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        switch elementKind {
        case Self.nowLineKind:
            nowLineAttributes()
        case Self.gridLineKind:
            indexPath.item < gridlineAttributes.count ? gridlineAttributes[indexPath.item] : nil
        default:
            nil
        }
    }

    private func nowLineAttributes() -> UICollectionViewLayoutAttributes? {
        guard contentHeight > 0, nowX >= 0, nowX <= totalWidth else { return nil }
        let attributes = UICollectionViewLayoutAttributes(
            forDecorationViewOfKind: Self.nowLineKind, with: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: nowX - 1, y: 0, width: 2, height: contentHeight)
        attributes.zIndex = 3
        return attributes
    }
}
#endif
