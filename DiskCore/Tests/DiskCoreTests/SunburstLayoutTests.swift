import CoreGraphics
import Foundation
import Testing

@testable import DiskCore

/// The rings had no tests at all, unlike the treemap — which is how the merge
/// threshold ended up producing slices under two points long, and how "others"
/// stayed a dead end for so long.
@Suite("Sunburst layout")
struct SunburstLayoutTests {

    /// A tree with a wide first level and one deep branch, so both the merging
    /// and the depth cap have something to bite on.
    private func fixture() async throws -> NodeStore {
        let fixture = try Fixture()
        try fixture.file("big/one.bin", bytes: 400_000)
        try fixture.file("big/deep/two.bin", bytes: 300_000)
        try fixture.file("big/deep/deeper/three.bin", bytes: 200_000)
        try fixture.file("big/deep/deeper/deepest/four.bin", bytes: 100_000)
        try fixture.file("medium.bin", bytes: 120_000)
        for index in 0..<40 {
            try fixture.file("tiny\(index).bin", bytes: 200)
        }
        return await ScanEngine.scan(root: fixture.path).store
    }

    @Test("Sibling sweeps fill their parent exactly")
    func anglesAddUp() async throws {
        let store = try await fixture()
        let arcs = SunburstLayout.build(store: store, root: 0, useLogicalSize: false)

        let ringOne = arcs.filter { $0.ring == 1 }
        let total = ringOne.reduce(0.0) { $0 + $1.sweep }
        #expect(abs(total - 2 * .pi) < 0.001)

        // Laid out end to end, with no gap and no overlap.
        let sorted = ringOne.sorted { $0.startAngle < $1.startAngle }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(abs(a.endAngle - b.startAngle) < 1e-9)
        }
    }

    @Test("A child never escapes its parent's wedge")
    func childrenStayInsideParents() async throws {
        let store = try await fixture()
        let arcs = SunburstLayout.build(store: store, root: 0, useLogicalSize: false)

        for ring in 2...4 {
            for child in arcs where child.ring == ring {
                guard let node = child.node else { continue }
                let parent = store.parent[Int(node)]
                guard let wedge = arcs.first(
                    where: { $0.ring == ring - 1 && $0.node == parent }
                ) else { continue }
                #expect(child.startAngle >= wedge.startAngle - 1e-9)
                #expect(child.endAngle <= wedge.endAngle + 1e-9)
            }
        }
    }

    @Test("Nothing thinner than the threshold is ever drawn")
    func minimumSweepIsRespected() async throws {
        let store = try await fixture()
        let threshold = 0.02
        let arcs = SunburstLayout.build(
            store: store, root: 0, useLogicalSize: false,
            minimumSweep: threshold
        )

        // The merged wedge is the one exception: it is allowed to be thin
        // because it is what the thin ones were folded into.
        for arc in arcs where !arc.isOthers {
            #expect(arc.sweep >= threshold)
        }
    }

    @Test("An others slice names every sibling it swallowed, and only those")
    func mergedNodesAreCompleteAndDisjoint() async throws {
        let store = try await fixture()
        let arcs = SunburstLayout.build(
            store: store, root: 0, useLogicalSize: false,
            minimumSweep: 0.05
        )

        let others = try #require(arcs.first { $0.ring == 1 && $0.isOthers })
        #expect(others.mergedNodes.count == others.mergedCount)
        #expect(others.mergedNodes.count == Set(others.mergedNodes).count)

        // Nothing is both drawn and merged.
        let drawn = Set(arcs.compactMap(\.node))
        #expect(drawn.isDisjoint(with: Set(others.mergedNodes)))

        // The sizes agree with what the slice claims to stand for.
        let summed = others.mergedNodes.reduce(Int64(0)) {
            $0 + store.totalAlloc[Int($1)]
        }
        #expect(summed == others.size)
    }

    @Test("Depth is capped at the requested ring count")
    func depthIsCapped() async throws {
        let store = try await fixture()
        for rings in 1...4 {
            let arcs = SunburstLayout.build(
                store: store, root: 0, maxRings: rings,
                useLogicalSize: false
            )
            #expect(arcs.allSatisfy { $0.ring <= rings })
        }
    }

    @Test("An empty tree produces nothing rather than NaN")
    func degenerateInput() async throws {
        // A directory with nothing in it: real, and the case where every
        // proportion would be a division by zero.
        let fixture = try Fixture()
        let store = await ScanEngine.scan(root: fixture.path).store
        let arcs = SunburstLayout.build(store: store, root: 0, useLogicalSize: false)
        #expect(arcs.allSatisfy { $0.sweep.isFinite && $0.startAngle.isFinite })
    }

    @Test("Hit testing finds the slice under a point, and nothing in the hole")
    func hitTesting() async throws {
        let store = try await fixture()
        let arcs = SunburstLayout.build(store: store, root: 0, useLogicalSize: false)
        let inner = 40.0
        let ringWidth = 30.0

        let target = try #require(arcs.first { $0.ring == 1 && !$0.isOthers })
        let radius = inner + ringWidth / 2
        let point = CGPoint(
            x: cos(target.midAngle) * radius,
            y: sin(target.midAngle) * radius
        )
        let hit = SunburstLayout.hitTest(
            arcs: arcs, point: point, innerRadius: inner, ringWidth: ringWidth
        )
        #expect(hit?.node == target.node)

        // The centre hole belongs to "go up", not to any slice.
        #expect(SunburstLayout.hitTest(
            arcs: arcs, point: .zero, innerRadius: inner, ringWidth: ringWidth
        ) == nil)
    }
}
