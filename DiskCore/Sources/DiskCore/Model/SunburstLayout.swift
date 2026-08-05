import Foundation

/// One drawn slice.
public struct Arc: Identifiable {
    /// Position in the layout, and the only reliable identity a slice has.
    ///
    /// Deriving it from the node does not work: an aggregated slice has no
    /// node, so every "others" wedge looked like every other one. Comparing
    /// them lit them all up together on hover, and worse, a context menu opened
    /// on one of them still pointed at whatever real folder was hovered before.
    public var id: Int
    /// Node it represents, or `nil` for an aggregated "others" slice.
    public var node: Int32?
    public var ring: Int
    public var startAngle: Double
    public var endAngle: Double
    /// Index into the categorical palette, inherited from the ring-1 ancestor.
    /// `-1` means the neutral "others" colour.
    public var slot: Int
    public var size: Int64
    /// How many siblings an "others" slice stands for.
    public var mergedCount: Int
    /// The siblings it stands for, largest first. Without these the slice is a
    /// dead end: it is the one place on the chart where content is hidden, so
    /// it has to be able to say what it is hiding.
    public var mergedNodes: [Int32] = []
    /// Rank among its siblings, used to nudge lightness so that neighbours in
    /// the same branch stay distinguishable without inventing a new hue.
    public var siblingIndex: Int

    public var sweep: Double { endAngle - startAngle }
    public var midAngle: Double { (startAngle + endAngle) / 2 }
    public var isOthers: Bool { node == nil }
}

/// Turns a subtree into a flat list of slices ready to draw.
///
/// Two limits keep this honest and fast. Slices thinner than `minimumSweep`
/// are merged into one "others" slice per parent — below about a third of a
/// degree a slice is a hairline nobody can click, and drawing tens of thousands
/// of them costs frames while telling the reader nothing. And the ring depth is
/// capped, because past five rings the arcs are too thin to carry a label.
public enum SunburstLayout {

    public static func build(
        store: NodeStore,
        root: Int32,
        maxRings: Int = 4,
        slotCount: Int = 8,
        useLogicalSize: Bool,
        filter: SearchMask? = nil,
        minimumSweep: Double = 0.006 // ≈ 0.34°
    ) -> [Arc] {
        build(
            store: store, root: root, children: nil,
            maxRings: maxRings, slotCount: slotCount,
            useLogicalSize: useLogicalSize, filter: filter,
            minimumSweep: minimumSweep
        )
    }

    /// - Parameter children: draw only these, as if they were all the root had.
    ///   This is how an "others" slice becomes somewhere you can go: the same
    ///   chart, restricted to what the slice stood for.
    /// - Parameter filter: when set, draw only the branches a search keeps, at
    ///   the size of what they retain rather than what they hold.
    public static func build(
        store: NodeStore,
        root: Int32,
        children: [Int32]?,
        maxRings: Int = 4,
        slotCount: Int = 8,
        useLogicalSize: Bool,
        filter: SearchMask? = nil,
        minimumSweep: Double = 0.006
    ) -> [Arc] {
        var arcs: [Arc] = []
        arcs.reserveCapacity(1024)

        let total = children.map { list in
            list.reduce(Int64(0)) {
                $0 + store.size(of: $1, useLogical: useLogicalSize, through: filter)
            }
        } ?? store.size(of: root, useLogical: useLogicalSize, through: filter)
        guard total > 0 else { return [] }

        descend(
            store: store, parent: root, children: children, ring: 1,
            startAngle: -.pi / 2, // twelve o'clock
            availableSweep: 2 * .pi,
            parentSize: total,
            slot: nil,
            maxRings: maxRings,
            slotCount: slotCount,
            useLogicalSize: useLogicalSize,
            filter: filter,
            minimumSweep: minimumSweep,
            into: &arcs
        )
        return arcs
    }

    private static func descend(
        store: NodeStore,
        parent: Int32,
        children explicit: [Int32]?,
        ring: Int,
        startAngle: Double,
        availableSweep: Double,
        parentSize: Int64,
        slot: Int?,
        maxRings: Int,
        slotCount: Int,
        useLogicalSize: Bool,
        filter: SearchMask?,
        minimumSweep: Double,
        into arcs: inout [Arc]
    ) {
        guard ring <= maxRings, parentSize > 0 else { return }
        let children = explicit ?? store.childrenSortedBySize(
            of: parent, useLogical: useLogicalSize, through: filter
        )
        guard !children.isEmpty else { return }

        var angle = startAngle
        var mergedSize: Int64 = 0
        var merged: [Int32] = []

        for (index, child) in children.enumerated() {
            let childSize = store.size(
                of: child, useLogical: useLogicalSize, through: filter
            )
            guard childSize > 0 else { continue }

            let sweep = availableSweep * Double(childSize) / Double(parentSize)

            // Past the eighth sibling there is no ninth hue by design — those
            // are drawn in neutral greys instead. Only slices too thin to see
            // fold into "others": the eight-hue limit is about telling
            // categories apart, never about hiding one.
            let childSlot = slot ?? (index < slotCount ? index : -1)
            if sweep < minimumSweep {
                mergedSize += childSize
                merged.append(child)
                continue
            }

            arcs.append(Arc(
                id: arcs.count,
                node: child,
                ring: ring,
                startAngle: angle,
                endAngle: angle + sweep,
                slot: childSlot,
                size: childSize,
                mergedCount: 0,
                siblingIndex: index
            ))

            if store.isDirectory(child) {
                descend(
                    store: store, parent: child, children: nil, ring: ring + 1,
                    startAngle: angle, availableSweep: sweep,
                    parentSize: childSize, slot: childSlot,
                    maxRings: maxRings, slotCount: slotCount,
                    useLogicalSize: useLogicalSize, filter: filter,
                    minimumSweep: minimumSweep, into: &arcs
                )
            }
            angle += sweep
        }

        if !merged.isEmpty {
            let sweep = availableSweep * Double(mergedSize) / Double(parentSize)
            if sweep > 0.0005 {
                arcs.append(Arc(
                    id: arcs.count,
                    node: nil,
                    ring: ring,
                    startAngle: angle,
                    endAngle: angle + sweep,
                    slot: -1,
                    size: mergedSize,
                    mergedCount: merged.count,
                    mergedNodes: merged,
                    siblingIndex: children.count
                ))
            }
        }
    }

    /// Finds the slice under a point expressed relative to the centre.
    ///
    /// Polar lookup: the radius picks the ring, then a scan within that ring
    /// picks the slice. Rings hold few enough arcs after merging that this stays
    /// comfortably interactive.
    public static func hitTest(
        arcs: [Arc], point: CGPoint, innerRadius: Double, ringWidth: Double
    ) -> Arc? {
        let distance = (point.x * point.x + point.y * point.y).squareRoot()
        guard distance > innerRadius else { return nil }
        let ring = Int((distance - innerRadius) / ringWidth) + 1

        var theta = atan2(point.y, point.x)
        // Layout starts at -π/2; normalise into [-π/2, 3π/2) to match.
        if theta < -.pi / 2 { theta += 2 * .pi }

        return arcs.first { arc in
            arc.ring == ring && theta >= arc.startAngle && theta < arc.endAngle
        }
    }
}
