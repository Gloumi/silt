import DiskCore
import Foundation

/// One drawn slice.
struct Arc: Identifiable {
    /// Node it represents, or `nil` for an aggregated "others" slice.
    var node: Int32?
    var ring: Int
    var startAngle: Double
    var endAngle: Double
    /// Index into the categorical palette, inherited from the ring-1 ancestor.
    /// `-1` means the neutral "others" colour.
    var slot: Int
    var size: Int64
    /// How many siblings an "others" slice stands for.
    var mergedCount: Int
    /// Rank among its siblings, used to nudge lightness so that neighbours in
    /// the same branch stay distinguishable without inventing a new hue.
    var siblingIndex: Int

    var id: Int { (ring << 24) ^ Int(node ?? -1) ^ Int(startAngle * 1000) }
    var sweep: Double { endAngle - startAngle }
    var midAngle: Double { (startAngle + endAngle) / 2 }
    var isOthers: Bool { node == nil }
}

/// Turns a subtree into a flat list of slices ready to draw.
///
/// Two limits keep this honest and fast. Slices thinner than `minimumSweep`
/// are merged into one "others" slice per parent — below about a third of a
/// degree a slice is a hairline nobody can click, and drawing tens of thousands
/// of them costs frames while telling the reader nothing. And the ring depth is
/// capped, because past five rings the arcs are too thin to carry a label.
enum SunburstLayout {

    static func build(
        store: NodeStore,
        root: Int32,
        maxRings: Int = 5,
        useLogicalSize: Bool,
        minimumSweep: Double = 0.006 // ≈ 0.34°
    ) -> [Arc] {
        var arcs: [Arc] = []
        arcs.reserveCapacity(1024)

        let total = size(store, root, useLogicalSize)
        guard total > 0 else { return [] }

        descend(
            store: store, parent: root, ring: 1,
            startAngle: -.pi / 2, // twelve o'clock
            availableSweep: 2 * .pi,
            parentSize: total,
            slot: nil,
            maxRings: maxRings,
            useLogicalSize: useLogicalSize,
            minimumSweep: minimumSweep,
            into: &arcs
        )
        return arcs
    }

    private static func size(
        _ store: NodeStore, _ node: Int32, _ useLogical: Bool
    ) -> Int64 {
        useLogical ? store.totalLogical[Int(node)] : store.totalAlloc[Int(node)]
    }

    private static func descend(
        store: NodeStore,
        parent: Int32,
        ring: Int,
        startAngle: Double,
        availableSweep: Double,
        parentSize: Int64,
        slot: Int?,
        maxRings: Int,
        useLogicalSize: Bool,
        minimumSweep: Double,
        into arcs: inout [Arc]
    ) {
        guard ring <= maxRings, parentSize > 0 else { return }
        let children = store.childrenSortedBySize(
            of: parent, useLogical: useLogicalSize
        )
        guard !children.isEmpty else { return }

        var angle = startAngle
        var mergedSize: Int64 = 0
        var mergedCount = 0

        for (index, child) in children.enumerated() {
            let childSize = size(store, child, useLogicalSize)
            guard childSize > 0 else { continue }

            let sweep = availableSweep * Double(childSize) / Double(parentSize)

            // Past the eighth sibling there is no ninth hue by design, and
            // hairline slices are unusable — both fold into "others".
            let childSlot = slot ?? (index < Palette.slotCount ? index : -1)
            if sweep < minimumSweep || (ring == 1 && index >= Palette.slotCount) {
                mergedSize += childSize
                mergedCount += 1
                continue
            }

            arcs.append(Arc(
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
                    store: store, parent: child, ring: ring + 1,
                    startAngle: angle, availableSweep: sweep,
                    parentSize: childSize, slot: childSlot,
                    maxRings: maxRings, useLogicalSize: useLogicalSize,
                    minimumSweep: minimumSweep, into: &arcs
                )
            }
            angle += sweep
        }

        if mergedCount > 0 {
            let sweep = availableSweep * Double(mergedSize) / Double(parentSize)
            if sweep > 0.0005 {
                arcs.append(Arc(
                    node: nil,
                    ring: ring,
                    startAngle: angle,
                    endAngle: angle + sweep,
                    slot: -1,
                    size: mergedSize,
                    mergedCount: mergedCount,
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
    static func hitTest(
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
