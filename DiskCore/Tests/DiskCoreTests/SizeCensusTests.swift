import Darwin
import Foundation
import Testing

@testable import DiskCore

private func bytes(_ seed: UInt8, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 17) }
}

@Suite("Size census")
struct SizeCensusTests {

    /// Three files at 300 bytes, two at 500, one alone at 700. Only the sizes
    /// something shares can ever produce a candidate.
    private func fill(_ fixture: borrowing Fixture) throws {
        try fixture.file("a.bin", content: bytes(1, 300))
        try fixture.file("b.bin", content: bytes(2, 300))
        try fixture.file("nested/c.bin", content: bytes(3, 300))
        try fixture.file("d.bin", content: bytes(4, 500))
        try fixture.file("e.bin", content: bytes(5, 500))
        try fixture.file("alone.bin", content: bytes(6, 700))
    }

    @Test("Only sizes shared by two files count as candidates")
    func sharedSizesOnly() async throws {
        let fixture = try Fixture()
        try fill(fixture)
        let census = try #require(SizeCensus.measure(root: fixture.path))

        #expect(census.filesSeen == 6)
        // The lone 700-byte file sits above every threshold below it and is
        // still never work: nothing shares its size, so no bucket can form.
        // Counting "files above the threshold" would overstate this by one.
        #expect(census.candidates(above: 0) == 5)
        #expect(census.candidates(above: 400) == 2)
        #expect(census.candidates(above: 600) == 0)
    }

    @Test("The byte estimate caps each file at the prefix length")
    func bytesRespectThePrefix() async throws {
        let fixture = try Fixture()
        try fill(fixture)
        let census = try #require(SizeCensus.measure(root: fixture.path))

        // Below the prefix a file is read whole — three at 300, two at 500.
        #expect(census.bytesToRead(above: 0, prefixLength: 4096)
                == 3 * 300 + 2 * 500)
        // Above it, every candidate costs exactly the prefix.
        #expect(census.bytesToRead(above: 0, prefixLength: 100) == 5 * 100)
    }

    @Test("A tree already in memory gives the same answer for free")
    func matchesTheStore() async throws {
        let fixture = try Fixture()
        try fill(fixture)
        let walked = try #require(SizeCensus.measure(root: fixture.path))
        let scan = await ScanEngine.scan(root: fixture.path)
        let fromStore = SizeCensus.measure(in: scan.store, under: 0)

        #expect(fromStore.filesSeen == walked.filesSeen)
        #expect(fromStore.shared == walked.shared)
    }

    @Test("Evicted iCloud files are counted by neither route")
    func datalessExcluded() async throws {
        let fixture = try Fixture()
        try fill(fixture)
        let scan = await ScanEngine.scan(root: fixture.path)
        var store = scan.store
        store.markFlag(
            .dataless, on: try #require(store.child(of: 0, named: "a.bin"))
        )
        let census = SizeCensus.measure(in: store, under: 0)
        // Promising work the finder refuses to do would make the estimate a
        // lie in the one direction that matters.
        #expect(census.filesSeen == 5)
        #expect(census.candidates(above: 0) == 4)
    }

    @Test("Every threshold is answered from the one walk")
    func oneWalkAnswersEveryThreshold() async throws {
        let fixture = try Fixture()
        try fill(fixture)
        let census = try #require(SizeCensus.measure(root: fixture.path))
        // Monotonic, which is what makes it safe to drive a slider with:
        // dragging towards the floor can only ever add work.
        let counts = [Int64(600), 400, 200, 0].map(census.candidates(above:))
        #expect(counts == counts.sorted())
    }
}
