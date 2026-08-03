import CoreGraphics
import Foundation

public struct TreemapTile: Identifiable, Sendable {
    /// Position in the layout. Same reason as the sunburst's: an aggregated
    /// tile has no node, so identity derived from one made every "others" tile
    /// indistinguishable from the rest.
    public var id: Int
    /// Node it represents, or nil for an aggregated "others" tile.
    public var node: Int32?
    public var rect: CGRect
    public var depth: Int
    /// Index into the categorical palette, inherited from the depth-1 ancestor.
    public var slot: Int
    public var siblingIndex: Int
    public var size: Int64
    public var mergedCount: Int
    /// The siblings it stands for, largest first — what "enter this tile"
    /// needs, and the same contract as the sunburst's aggregated slice.
    public var mergedNodes: [Int32] = []

    public var isOthers: Bool { node == nil }
}

/// Squarified treemap (Bruls, Huizing & van Wijk).
///
/// The naive "slice and dice" treemap is trivial to write and unusable in
/// practice: it produces slivers hundreds of times longer than they are wide,
/// whose area the eye cannot judge and whose edges cannot be clicked. This
/// keeps each rectangle as close to square as it can, which is the entire point
/// of preferring a treemap over a list.
public enum TreemapLayout {

    /// - Parameter children: draw only these, as if they were all the root
    ///   had — the tiles matching a slice the user stepped into elsewhere.
    public static func build(
        store: NodeStore,
        root: Int32,
        children: [Int32]? = nil,
        in bounds: CGRect,
        maxDepth: Int = 3,
        slotCount: Int = 8,
        useLogicalSize: Bool,
        minimumArea: Double = 24
    ) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        tiles.reserveCapacity(512)
        descend(
            store: store, parent: root, children: children,
            rect: bounds, depth: 1,
            slot: nil, maxDepth: maxDepth, slotCount: slotCount,
            useLogicalSize: useLogicalSize, minimumArea: minimumArea,
            into: &tiles
        )
        return tiles
    }

    private static func size(
        _ store: NodeStore, _ node: Int32, _ useLogical: Bool
    ) -> Int64 {
        useLogical ? store.totalLogical[Int(node)] : store.totalAlloc[Int(node)]
    }

    private static func descend(
        store: NodeStore,
        parent: Int32,
        children explicit: [Int32]? = nil,
        rect: CGRect,
        depth: Int,
        slot: Int?,
        maxDepth: Int,
        slotCount: Int,
        useLogicalSize: Bool,
        minimumArea: Double,
        into tiles: inout [TreemapTile]
    ) {
        guard depth <= maxDepth, rect.width > 1, rect.height > 1 else { return }
        let children = explicit ?? store.childrenSortedBySize(
            of: parent, useLogical: useLogicalSize
        )
        guard !children.isEmpty else { return }

        let available = Double(rect.width * rect.height)
        let parentSize = explicit.map { list in
            Double(list.reduce(Int64(0)) { $0 + size(store, $1, useLogicalSize) })
        } ?? Double(size(store, parent, useLogicalSize))
        guard parentSize > 0 else { return }

        // Tiles too small to see or click are pooled rather than drawn as
        // hairlines nobody can hit.
        var kept: [(node: Int32, value: Double, index: Int)] = []
        var mergedValue = 0.0
        var merged: [Int32] = []

        for (index, child) in children.enumerated() {
            let value = Double(size(store, child, useLogicalSize))
            guard value > 0 else { continue }
            let area = available * value / parentSize
            if area < minimumArea {
                mergedValue += value
                merged.append(child)
            } else {
                kept.append((child, value, index))
            }
        }
        guard !kept.isEmpty || !merged.isEmpty else { return }

        var values = kept.map(\.value)
        if !merged.isEmpty { values.append(mergedValue) }

        let rects = squarify(values: values, in: rect)

        for (offset, tile) in rects.enumerated() {
            let isMerged = !merged.isEmpty && offset == rects.count - 1
            if isMerged {
                tiles.append(TreemapTile(
                    id: tiles.count,
                    node: nil, rect: tile, depth: depth, slot: -1,
                    siblingIndex: children.count, size: Int64(mergedValue),
                    mergedCount: merged.count, mergedNodes: merged
                ))
                continue
            }
            let child = kept[offset]
            let childSlot = slot ?? (child.index < slotCount ? child.index : -1)
            tiles.append(TreemapTile(
                id: tiles.count,
                node: child.node, rect: tile, depth: depth, slot: childSlot,
                siblingIndex: child.index, size: Int64(child.value),
                mergedCount: 0
            ))

            if store.isDirectory(child.node), depth < maxDepth {
                // Children start *below* a reserved strip, so a parent's name
                // always has somewhere to sit. Without it the first child is
                // drawn straight over its parent's title.
                let inner = contentRect(of: tile)
                if inner.width > 10, inner.height > 10 {
                    descend(
                        store: store, parent: child.node, rect: inner,
                        depth: depth + 1, slot: childSlot, maxDepth: maxDepth,
                        slotCount: slotCount, useLogicalSize: useLogicalSize,
                        minimumArea: minimumArea, into: &tiles
                    )
                }
            }
        }
    }

    /// Area a directory tile leaves to its children: inset on every side, plus
    /// a strip at the top for the tile's own name.
    public static func contentRect(of tile: CGRect) -> CGRect {
        let inset: CGFloat = 3
        let header = headerHeight
        let rect = tile.insetBy(dx: inset, dy: inset)
        guard rect.height > header else { return .zero }
        return CGRect(
            x: rect.minX, y: rect.minY + header,
            width: rect.width, height: rect.height - header
        )
    }

    /// Height reserved for a directory tile's label.
    public static let headerHeight: CGFloat = 14

    // MARK: - Squarify

    /// Packs `values` into `rect`, proportionally, keeping tiles near-square.
    ///
    /// Rows are grown along the shorter side and closed as soon as adding
    /// another tile would make the worst aspect ratio in the row worse than it
    /// already is — the greedy step at the heart of the algorithm.
    static func squarify(values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, !values.isEmpty else {
            return Array(repeating: .zero, count: values.count)
        }

        // Work in area units so a row's sum is directly a slab of the rectangle.
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }

        var result: [CGRect] = []
        result.reserveCapacity(values.count)
        var remaining = rect
        var index = 0

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            guard side > 0 else {
                result.append(contentsOf:
                    Array(repeating: .zero, count: areas.count - index))
                break
            }

            var end = index
            var sum = 0.0
            var best = Double.infinity

            while end < areas.count {
                let candidate = sum + areas[end]
                let ratio = worstRatio(
                    areas[index...end], sum: candidate, side: side
                )
                if ratio > best { break }
                best = ratio
                sum = candidate
                end += 1
            }

            result.append(contentsOf: place(
                areas[index..<end], sum: sum, in: &remaining
            ))
            index = end
        }
        return result
    }

    /// Worst side-ratio in a row, the quantity the algorithm minimises.
    private static func worstRatio(
        _ row: ArraySlice<Double>, sum: Double, side: Double
    ) -> Double {
        guard sum > 0, let low = row.min(), let high = row.max(), low > 0 else {
            return .infinity
        }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * high / sum2, sum2 / (side2 * low))
    }

    /// Lays one row along the short side and shrinks `remaining` by it.
    private static func place(
        _ row: ArraySlice<Double>, sum: Double, in remaining: inout CGRect
    ) -> [CGRect] {
        guard sum > 0 else {
            return Array(repeating: .zero, count: row.count)
        }
        var rects: [CGRect] = []
        rects.reserveCapacity(row.count)

        if remaining.width < remaining.height {
            // Row across the top.
            let height = CGFloat(sum / Double(remaining.width))
            var x = remaining.minX
            for area in row {
                let width = CGFloat(area / sum) * remaining.width
                rects.append(CGRect(x: x, y: remaining.minY,
                                    width: width, height: height))
                x += width
            }
            remaining = CGRect(
                x: remaining.minX, y: remaining.minY + height,
                width: remaining.width,
                height: max(0, remaining.height - height)
            )
        } else {
            // Column down the left.
            let width = CGFloat(sum / Double(remaining.height))
            var y = remaining.minY
            for area in row {
                let height = CGFloat(area / sum) * remaining.height
                rects.append(CGRect(x: remaining.minX, y: y,
                                    width: width, height: height))
                y += height
            }
            remaining = CGRect(
                x: remaining.minX + width, y: remaining.minY,
                width: max(0, remaining.width - width),
                height: remaining.height
            )
        }
        return rects
    }

    /// Topmost tile containing `point`, which is the deepest one drawn there.
    public static func hitTest(tiles: [TreemapTile], point: CGPoint) -> TreemapTile? {
        tiles.last { $0.rect.contains(point) }
    }
}
