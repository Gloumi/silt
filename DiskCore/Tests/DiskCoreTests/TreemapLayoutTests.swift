import CoreGraphics
import Foundation
import Testing

@testable import DiskCore

@Suite("Squarified treemap")
struct TreemapLayoutTests {

    private let canvas = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test("Tiles fill the rectangle and none escapes it")
    func areaIsConserved() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(values: values, in: canvas)

        #expect(rects.count == values.count)
        let covered = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(covered - Double(canvas.width * canvas.height)) < 1)

        for rect in rects {
            #expect(canvas.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
    }

    @Test("Each tile's area is proportional to its value")
    func areaMatchesValue() {
        let values: [Double] = [50, 25, 15, 10]
        let rects = TreemapLayout.squarify(values: values, in: canvas)
        let total = values.reduce(0, +)
        let canvasArea = Double(canvas.width * canvas.height)

        for (value, rect) in zip(values, rects) {
            let expected = canvasArea * value / total
            let actual = Double(rect.width * rect.height)
            #expect(abs(actual - expected) / expected < 0.001)
        }
    }

    @Test("Tiles do not overlap")
    func noOverlap() {
        let values = (1...20).map { Double(21 - $0) }
        let rects = TreemapLayout.squarify(values: values, in: canvas)

        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlap = a.intersection(b)
                #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01)
            }
        }
    }

    /// The whole reason for using this algorithm rather than slice-and-dice.
    @Test("Aspect ratios stay usable instead of degenerating into slivers")
    func aspectRatiosStayReasonable() {
        let values = (1...40).map { Double(41 - $0) }
        let rects = TreemapLayout.squarify(values: values, in: canvas)

        var worst = 1.0
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let ratio = Double(max(rect.width, rect.height) / min(rect.width, rect.height))
            worst = max(worst, ratio)
        }
        // Slice-and-dice on this input reaches ratios in the hundreds.
        #expect(worst < 12, "pire proportion \(worst)")
    }

    @Test("Degenerate inputs do not crash or produce NaN")
    func degenerateInputs() {
        #expect(TreemapLayout.squarify(values: [], in: canvas).isEmpty)
        #expect(TreemapLayout.squarify(values: [0, 0], in: canvas).count == 2)

        let flat = CGRect(x: 0, y: 0, width: 100, height: 0)
        for rect in TreemapLayout.squarify(values: [1, 2], in: flat) {
            #expect(!rect.width.isNaN && !rect.height.isNaN)
        }
        let single = TreemapLayout.squarify(values: [7], in: canvas)
        #expect(abs(single[0].width - canvas.width) < 0.01)
    }

    @Test("A real tree produces tiles that nest inside their parent")
    func nestingIsContained() async throws {
        let fixture = try Fixture()
        try fixture.file("big/one.bin", bytes: 400_000)
        try fixture.file("big/two.bin", bytes: 300_000)
        try fixture.file("small/three.bin", bytes: 50_000)

        let result = await ScanEngine.scan(root: fixture.path)
        let tiles = TreemapLayout.build(
            store: result.store, root: 0, in: canvas, useLogicalSize: false
        )
        #expect(!tiles.isEmpty)

        let store = result.store
        for tile in tiles where tile.depth == 2 {
            guard let node = tile.node else { continue }
            let parent = store.parent[Int(node)]
            guard let parentTile = tiles.first(
                where: { $0.node == parent && $0.depth == 1 }
            ) else { continue }
            #expect(parentTile.rect.insetBy(dx: -1, dy: -1).contains(tile.rect))
        }
    }
}
