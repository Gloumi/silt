import Testing
import Foundation
import CryptoKit
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

@Suite("Scan sealing")
struct ScanSealingTests {
    private let sample = Data(
        (0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 % 37) }
    )

    @Test("Sealed with a key, it opens with the same key and is smaller")
    func roundTripWithKey() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try ScanSealing.seal(sample, key: key)
        #expect(sealed.count < sample.count / 4)
        #expect(ScanSealing.open(sealed, key: key) == sample)
    }

    @Test("Sealed without a key, it opens without one")
    func roundTripWithoutKey() throws {
        let sealed = try ScanSealing.seal(sample, key: nil)
        #expect(sealed.count < sample.count / 4)
        #expect(ScanSealing.open(sealed, key: nil) == sample)
    }

    @Test("Another key opens nothing")
    func wrongKeyFails() throws {
        let sealed = try ScanSealing.seal(
            sample, key: SymmetricKey(size: .bits256)
        )
        #expect(ScanSealing.open(sealed, key: SymmetricKey(size: .bits256)) == nil)
    }

    @Test("A flipped byte is refused")
    func tamperingFails() throws {
        let key = SymmetricKey(size: .bits256)
        var sealed = try ScanSealing.seal(sample, key: key)
        sealed[sealed.count / 2] ^= 0xFF
        #expect(ScanSealing.open(sealed, key: key) == nil)
    }
}

@Suite("Reinstated sizes")
struct ReinstatedSizesTests {
    private typealias Totals = (alloc: Int64, logical: Int64, files: Int32)

    private func totals(_ store: NodeStore, _ node: Int32) -> Totals {
        let i = Int(node)
        return (store.totalAlloc[i], store.totalLogical[i], store.fileCount[i])
    }

    private func fixture() throws -> Fixture {
        let fixture = try Fixture()
        try fixture.file("x/one.bin", bytes: 8_000)
        try fixture.file("x/two.bin", bytes: 4_000)
        return fixture
    }

    /// Trashes `relative` in a fresh scan of `fixture`, brings it back the
    /// way the app does — measured from disk on its own, then applied to the
    /// tree — and checks the node and the root read as before.
    private func roundTrip(
        _ fixture: borrowing Fixture, _ relative: String
    ) async throws {
        var store = await ScanEngine.scan(root: fixture.path).store
        let root = store.name(of: 0)
        let node = try #require(store.node(atPath: root + relative))
        let before = totals(store, node), rootBefore = totals(store, 0)

        store.markDeleted(node)
        let measured = try #require(NodeStore.remeasure(
            root + relative,
            withContents: store.needsContentsToReinstate(node)
        ))
        let back = try #require(store.reinstatedSizes(of: node, from: measured))
        store.unmarkDeleted(node, alloc: back.alloc, logical: back.logical, files: back.files)

        #expect(totals(store, node) == before)
        #expect(totals(store, 0) == rootBefore)
    }

    @Test("A file comes back with its size")
    func fileComesBackWithItsSize() async throws {
        try await roundTrip(fixture(), "/x/one.bin")
    }

    @Test("A folder comes back with its size")
    func folderComesBackWithItsSize() async throws {
        try await roundTrip(fixture(), "/x")
    }

    @Test("A file with a resource fork comes back with the size the scan recorded")
    func resourceForkCountsAsTheScanCountsIt() async throws {
        let fixture = try fixture()
        let path = fixture.root.appendingPathComponent("x/one.bin").path
        let fork = [UInt8](repeating: 7, count: 6_000)
        #expect(setxattr(path, "com.apple.ResourceFork", fork, fork.count, 0, 0) == 0)
        try await roundTrip(fixture, "/x/one.bin")
    }

    @Test("A package the scan did not descend into comes back with its size")
    func packageComesBackWithItsSize() async throws {
        let fixture = try Fixture()
        try fixture.file("Thing.app/Contents/MacOS/Thing", bytes: 9_000)
        try fixture.file("Thing.app/Contents/Info.plist", bytes: 700)
        try fixture.file("Thing.app/Contents/Resources/a.bin", bytes: 30_000)
        try fixture.symlink("MacOS/Thing", at: "Thing.app/Contents/Current")
        try await roundTrip(fixture, "/Thing.app")
    }

    @Test("A collapsed folder comes back with its size")
    func collapsedFolderComesBackWithItsSize() async throws {
        let fixture = try Fixture()
        try fixture.file("p/node_modules/a/index.js", bytes: 1_500)
        try fixture.file("p/node_modules/b/lib/main.js", bytes: 22_000)
        try fixture.hardLink("p/node_modules/a/index.js", to: "p/node_modules/b/copy.js")
        try await roundTrip(fixture, "/p/node_modules")
    }

    @Test("An extra hard link comes back at zero, as the scan stored it")
    func hardLinkDuplicateComesBackAtZero() async throws {
        let fixture = try Fixture()
        try fixture.file("one.bin", bytes: 8_000)
        try fixture.hardLink("one.bin", to: "two.bin")
        let store = await ScanEngine.scan(root: fixture.path).store
        let duplicate = try #require(store.children(of: 0).first {
            store.flags[Int($0)].contains(.hardlinkDuplicate)
        })
        try await roundTrip(fixture, "/" + store.name(of: duplicate))
    }

    @Test("A folder measured without its contents is not guessed at")
    func contentsAreNeededWhereTheTreeHasNone() async throws {
        let fixture = try Fixture()
        try fixture.file("Thing.app/Contents/Info.plist", bytes: 700)
        var store = await ScanEngine.scan(root: fixture.path).store
        let root = store.name(of: 0)
        let node = try #require(store.node(atPath: root + "/Thing.app"))
        #expect(store.needsContentsToReinstate(node))
        store.markDeleted(node)
        let measured = try #require(
            NodeStore.remeasure(root + "/Thing.app", withContents: false)
        )
        #expect(store.reinstatedSizes(of: node, from: measured) == nil)
    }

    @Test("A path that is gone has no size")
    func missingPathIsNil() async throws {
        let fixture = try fixture()
        let store = await ScanEngine.scan(root: fixture.path).store
        let root = store.name(of: 0)
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent("x/one.bin")
        )
        #expect(NodeStore.remeasure(root + "/x/one.bin", withContents: true) == nil)
    }
}
