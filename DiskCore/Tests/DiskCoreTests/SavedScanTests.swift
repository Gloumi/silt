import Testing
import Foundation
@testable import DiskCore

@Suite("Saved scan")
struct SavedScanTests {
    private func scanned() async throws -> (SavedScan, String) {
        let fixture = try Fixture()
        try fixture.file("a/b/c.bin", bytes: 10_000)
        try fixture.file("a/d.bin", bytes: 3_000)
        try fixture.file("e/f.bin", bytes: 500)
        var result = await ScanEngine.scan(root: fixture.path)
        // The scanner resolves symlinks (/var -> /private/var), so the store's
        // root is the path to build node paths from, not the requested one.
        let root = result.store.name(of: 0)
        let doomed = try #require(result.store.node(atPath: root + "/a/d.bin"))
        result.store.markDeleted(doomed)
        result.unreadablePaths = ["/private/var/db", "/Volumes/é"]
        let saved = SavedScan(
            rootPath: fixture.path, scannedAt: Date(), result: result
        )
        return (saved, root)
    }

    @Test("A scan survives encoding and decoding unchanged")
    func roundTrip() async throws {
        let (saved, root) = try await scanned()
        let back = try #require(SavedScan(decoding: saved.encoded()))

        let a = saved.result.store, b = back.result.store
        #expect(b.parent == a.parent)
        #expect(b.childStart == a.childStart)
        #expect(b.childCount == a.childCount)
        #expect(b.totalAlloc == a.totalAlloc)
        #expect(b.totalLogical == a.totalLogical)
        #expect(b.fileCount == a.fileCount)
        #expect(b.modTime == a.modTime)
        #expect(b.flags.map(\.rawValue) == a.flags.map(\.rawValue))
        #expect(b.nameBlob == a.nameBlob)
        #expect(b.nameOffset == a.nameOffset)
        #expect(b.nameLength == a.nameLength)

        #expect(back.rootPath == saved.rootPath)
        #expect(abs(back.scannedAt.timeIntervalSince(saved.scannedAt)) < 1)
        #expect(back.result.unreadablePaths == saved.result.unreadablePaths)
        #expect(back.result.filesSeen == saved.result.filesSeen)
        #expect(back.result.directoriesSeen == saved.result.directoriesSeen)
        #expect(back.result.duration == saved.result.duration)

        #expect(b.node(atPath: root + "/a/b") == a.node(atPath: root + "/a/b"))
        let deleted = try #require(b.node(atPath: root + "/a/d.bin"))
        #expect(b.flags[Int(deleted)].contains(.deleted))
    }

    @Test("A truncated archive is refused, wherever it was cut")
    func rejectsTruncated() async throws {
        let (saved, _) = try await scanned()
        let data = saved.encoded()
        for k in stride(from: 0, to: data.count, by: max(1, data.count / 50)) {
            #expect(SavedScan(decoding: data.prefix(k)) == nil)
        }
    }

    @Test("An archive from another format version is refused")
    func rejectsOtherVersion() async throws {
        let (saved, _) = try await scanned()
        var data = saved.encoded()
        data[4] = data[4] &+ 1
        #expect(SavedScan(decoding: data) == nil)
    }

    @Test("A tree whose parent points forward is refused")
    func rejectsInconsistentTree() async throws {
        let (saved, _) = try await scanned()
        let n = saved.result.store.count
        let bad = saved.encoded(corruptingParentOf: 1, with: Int32(n + 5))
        #expect(SavedScan(decoding: bad) == nil)
        // The same helper with a valid value must still decode, so the failure
        // above is down to the value and not to the helper.
        let fine = saved.encoded(corruptingParentOf: 1, with: 0)
        #expect(SavedScan(decoding: fine) != nil)
    }

    /// Root with two children, as the scanner would lay it out. Each case
    /// below breaks exactly one thing.
    private func store(
        parent: [Int32] = [0, 0, 0],
        childStart: [Int32] = [1, 0, 0],
        childCount: [Int32] = [2, 0, 0],
        nameOffset: [UInt32] = [0, 1, 2],
        nameLength: [UInt16] = [1, 1, 1],
        nameBlob: [UInt8] = [97, 98, 99],
        totalAlloc: [Int64] = [0, 0, 0]
    ) -> NodeStore? {
        NodeStore(
            validating: nameBlob, nameOffset: nameOffset, nameLength: nameLength,
            parent: parent, childStart: childStart, childCount: childCount,
            totalAlloc: totalAlloc, totalLogical: [0, 0, 0], fileCount: [0, 0, 0],
            modTime: [0, 0, 0], flags: [.directory, [], []]
        )
    }

    @Test("The validating initialiser accepts a well-formed tree")
    func acceptsWellFormed() {
        #expect(store() != nil)
    }

    @Test("Trees that break the store's invariants are refused")
    func rejectsBrokenInvariants() {
        #expect(store(parent: [1, 0, 0]) == nil)          // root not its own parent
        #expect(store(parent: [0, 2, 0]) == nil)          // parent after child
        #expect(store(parent: [0, -1, 0]) == nil)         // negative parent
        #expect(store(childStart: [-1, 0, 0]) == nil)     // negative start
        #expect(store(childCount: [-1, 0, 0]) == nil)     // negative count
        #expect(store(childStart: [2, 0, 0]) == nil)      // range past the end
        #expect(store(childStart: [0, 0, 0], childCount: [3, 0, 0]) == nil) // contains root
        #expect(store(childStart: [1, 1, 0], childCount: [2, 1, 0]) == nil) // child claims itself
        #expect(store(parent: [0, 0, 1]) == nil)          // child of the wrong parent
        #expect(store(nameLength: [1, 1, 2]) == nil)      // name past the blob
        #expect(store(nameOffset: [0, 1, 4]) == nil)
        #expect(store(totalAlloc: [0, 0]) == nil)         // mismatched lengths
    }
}
