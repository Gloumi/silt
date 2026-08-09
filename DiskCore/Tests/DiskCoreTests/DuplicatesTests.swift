import Darwin
import Foundation
import Synchronization
import Testing

@testable import DiskCore

/// `Fixture.file(_:bytes:)` writes zeros, which makes every same-size pair a
/// duplicate — exactly what most of these tests must control precisely.
extension Fixture {
    @discardableResult
    func file(_ relative: String, content: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(content).write(to: url)
        return url
    }
}

/// Deterministic filler that never repeats a period the prefix could alias.
private func pattern(_ seed: UInt8, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0 &* 31) }
}

/// Progress snapshots need to cross from worker threads into the test.
private final class ProgressLog: Sendable {
    let entries = Mutex<[DuplicateFinder.Progress]>([])
    func record(_ progress: DuplicateFinder.Progress) {
        entries.withLock { $0.append(progress) }
    }
}

@Suite("Duplicate finder")
struct DuplicatesTests {

    /// Small enough that fixtures stay tiny, while still exercising the
    /// prefix/full split: 100-byte files overflow a 16-byte prefix.
    private var options: DuplicateFinder.Options {
        var options = DuplicateFinder.Options()
        options.minimumSize = 100
        options.prefixLength = 16
        return options
    }

    @Test("Identical content groups, same size alone does not")
    func contentDecides() async throws {
        let fixture = try Fixture()
        // Four files, one shared size: only the identical pair may group.
        try fixture.file("copy1.bin", content: pattern(1, count: 300))
        try fixture.file("nested/copy2.bin", content: pattern(1, count: 300))
        try fixture.file("other1.bin", content: pattern(2, count: 300))
        try fixture.file("other2.bin", content: pattern(3, count: 300))

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(group.logicalSize == 300)
        #expect(group.storages.count == 2)
        let names = Set(group.storages.flatMap(\.nodes).map { scan.store.name(of: $0) })
        #expect(names == ["copy1.bin", "copy2.bin"])
        #expect(result.candidateCount == 4)
        #expect(result.droppedCount == 0)
    }

    @Test("A shared prefix with a different tail is separated by the full pass")
    func prefixIsNotEnough() async throws {
        let fixture = try Fixture()
        let a = pattern(4, count: 300)
        var b = a
        b[200] ^= 0xFF
        try fixture.file("a.bin", content: a)
        try fixture.file("b.bin", content: b)

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.groups.isEmpty)
        // Both passes had to run: 16 bytes twice, then 300 bytes twice.
        #expect(result.bytesHashed == 2 * 16 + 2 * 300)
    }

    @Test("Files fitting inside the prefix never get a second read")
    func prefixCoversSmallFiles() async throws {
        let fixture = try Fixture()
        try fixture.file("one.bin", content: pattern(5, count: 200))
        try fixture.file("two.bin", content: pattern(5, count: 200))

        var wide = options
        wide.prefixLength = 4096
        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: wide
        ))
        #expect(result.groups.count == 1)
        // The prefix read the whole 200 bytes of each file; a full pass would
        // have doubled this.
        #expect(result.bytesHashed == 2 * 200)
    }

    @Test("Hard links fold into one storage and are hashed once")
    func hardLinksShareStorage() async throws {
        let fixture = try Fixture()
        try fixture.file("original.bin", content: pattern(6, count: 5_000))
        try fixture.hardLink("original.bin", to: "linked.bin")
        try fixture.file("copy.bin", content: pattern(6, count: 5_000))

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let group = try #require(result.groups.first)
        #expect(result.groups.count == 1)
        // Two storages, not three: the linked pair is one set of bytes.
        #expect(group.storages.count == 2)
        let linked = try #require(group.storages.first { $0.nodes.count == 2 })
        #expect(linked.linkCount == 2)
        // The inode was hashed once — prefix and full pass each read two
        // files, never three.
        #expect(result.bytesHashed == 2 * 16 + 2 * 5_000)
        // Deleting either copy frees exactly one copy's worth of disk.
        let single = try #require(group.storages.first { $0.nodes.count == 1 })
        #expect(group.reclaimableBytes == single.allocated)
    }

    @Test("Files below the threshold are never candidates")
    func thresholdFilters() async throws {
        let fixture = try Fixture()
        try fixture.file("small1.bin", content: pattern(7, count: 50))
        try fixture.file("small2.bin", content: pattern(7, count: 50))

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.groups.isEmpty)
        #expect(result.candidateCount == 0)
        #expect(result.bytesHashed == 0)
    }

    @Test("Nodes marked deleted are excluded, including whole subtrees")
    func deletedNodesExcluded() async throws {
        let fixture = try Fixture()
        try fixture.file("keep.bin", content: pattern(8, count: 300))
        try fixture.file("gone/trashed.bin", content: pattern(8, count: 300))

        let scan = await ScanEngine.scan(root: fixture.path)
        var store = scan.store
        let gone = try #require(
            store.children(of: 0).first { store.name(of: $0) == "gone" }
        )
        store.markDeleted(gone)

        let result = try #require(await DuplicateFinder.find(
            in: store, under: 0, options: options
        ))
        #expect(result.groups.isEmpty)
        #expect(result.candidateCount == 0)
    }

    @Test("An unreadable candidate is dropped, the rest still groups")
    func unreadableCandidateDropped() async throws {
        let fixture = try Fixture()
        try fixture.file("a.bin", content: pattern(9, count: 300))
        try fixture.file("b.bin", content: pattern(9, count: 300))
        let locked = try fixture.file("c.bin", content: pattern(9, count: 300))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path
        )

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.droppedCount == 1)
        #expect(result.groups.count == 1)
        #expect(result.groups.first?.storages.count == 2)
    }

    @Test("A file that changed since the scan is dropped, not mis-grouped")
    func changedFileDropped() async throws {
        let fixture = try Fixture()
        try fixture.file("stable.bin", content: pattern(10, count: 300))
        let mutated = try fixture.file("mutated.bin", content: pattern(10, count: 300))

        let scan = await ScanEngine.scan(root: fixture.path)
        // Grow the file after the scan: the size bucket no longer describes it.
        try Data(pattern(10, count: 350)).write(to: mutated)

        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.droppedCount == 1)
        #expect(result.groups.isEmpty)
        #expect(result.bytesHashed == 0)
    }

    @Test("Copies stamped with the same date are still ordered the same way")
    func keeperOrderIsDeterministic() async throws {
        let fixture = try Fixture()
        // Three copies of one content, deliberately given the very same mtime —
        // what `cp -p` does, and what a folder's rolled-up date does to every
        // folder copy. Without a tie-break the order is whichever worker got
        // there first, and « Conservée » wanders between two launches.
        try fixture.file("b-deep/nested/copy.bin", content: pattern(20, count: 300))
        try fixture.file("a-top.bin", content: pattern(20, count: 300))
        try fixture.file("z-top.bin", content: pattern(20, count: 300))
        for path in ["b-deep/nested/copy.bin", "a-top.bin", "z-top.bin"] {
            try fixture.setModified(path, daysAgo: 3)
        }

        let scan = await ScanEngine.scan(root: fixture.path)
        let first = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let second = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))

        func order(_ result: DuplicateFinder.Result) -> [String] {
            (result.groups.first?.storages ?? []).compactMap {
                $0.nodes.first.map(scan.store.name(of:))
            }
        }
        // Shallowest first, then alphabetical — never the scan order.
        #expect(order(first) == ["a-top.bin", "z-top.bin", "copy.bin"])
        #expect(order(first) == order(second))
    }

    @Test("Cancellation returns nil instead of a partial answer")
    func cancellation() async throws {
        let fixture = try Fixture()
        try fixture.file("a.bin", content: pattern(11, count: 2_000_000))
        try fixture.file("b.bin", content: pattern(11, count: 2_000_000))

        let scan = await ScanEngine.scan(root: fixture.path)
        let store = scan.store
        let opts = options
        let task = Task {
            await DuplicateFinder.find(in: store, under: 0, options: opts)
        }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }

    @Test("Progress is staged and monotonic")
    func progressReporting() async throws {
        let fixture = try Fixture()
        try fixture.file("a.bin", content: pattern(12, count: 300))
        try fixture.file("b.bin", content: pattern(12, count: 300))

        let scan = await ScanEngine.scan(root: fixture.path)
        let log = ProgressLog()
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options,
            onProgress: { log.record($0) }
        ))
        #expect(result.groups.count == 1)
        #expect(result.bytesHashed == 2 * 16 + 2 * 300)

        let entries = log.entries.withLock { $0 }
        // Every stage announces itself even when the pass is too quick for
        // any throttled update to fire.
        #expect(entries.first?.stage == .collecting)
        #expect(entries.contains { $0.stage == .prefixPass })
        #expect(entries.contains { $0.stage == .fullPass })
        // Within a stage the byte counter only ever moves forward.
        for stage in [DuplicateFinder.Progress.Stage.prefixPass, .fullPass] {
            let bytes = entries.filter { $0.stage == stage }.map(\.bytesHashed)
            #expect(bytes == bytes.sorted())
        }
    }
}
