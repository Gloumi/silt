import Darwin
import Foundation
import Testing

@testable import DiskCore

/// Deterministic filler, distinct from the one the file tests use so a mistake
/// here cannot accidentally agree with a fixture over there.
private func filler(_ seed: UInt8, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &* 7 &+ $0 &* 13) }
}

extension Fixture {
    /// Writes the same little tree twice, under two differently named roots —
    /// the shape the whole feature exists for.
    func twoCopies(
        _ left: String, _ right: String, extraByteOnTheRight: Bool = false
    ) throws {
        for (root, extra) in [(left, 0), (right, extraByteOnTheRight ? 1 : 0)] {
            try file("\(root)/a.bin", content: filler(1, count: 300))
            try file("\(root)/b.bin", content: filler(2, count: 500 + extra))
            try file("\(root)/raw/c.bin", content: filler(3, count: 400))
        }
    }

    /// `A` and `B` are twins, `C` is unrelated but happens to hold the same
    /// `x` — everything the display rules have to get right, in one tree.
    func threeFolders() throws {
        for root in ["A", "B"] {
            try file("\(root)/x.bin", content: filler(1, count: 300))
            try file("\(root)/sub/y.bin", content: filler(2, count: 300))
        }
        try file("C/x.bin", content: filler(1, count: 300))
    }

    /// A named pipe. Opening one with no writer blocks inside the kernel, which
    /// is the whole reason the manifest records it and never touches it.
    func fifo(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        #expect(mkfifo(url.path, 0o644) == 0)
    }

    func chmod(_ relative: String, _ mode: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: root.appendingPathComponent(relative).path
        )
    }
}

@Suite("Folder signatures")
struct FolderSignatureTests {

    private func candidateNames(
        _ buckets: [[Int32]], in store: NodeStore
    ) -> Set<Set<String>> {
        Set(buckets.map { Set($0.map(store.name(of:))) })
    }

    @Test("Two identical trees group whatever their roots are called")
    func identicalTreesGroup() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        let buckets = try #require(FolderSignature.candidates(
            in: scan.store, under: 0, minimumSize: 100
        ))
        // The two roots pair up despite their names, and so do the two `raw`
        // subfolders — the engine reports both, the display picks the top.
        #expect(candidateNames(buckets, in: scan.store).contains(
            ["Photos", "Photos copie"]
        ))
        #expect(candidateNames(buckets, in: scan.store).contains(["raw"]))
    }

    @Test("One byte of difference separates them")
    func oneByteSeparates() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie", extraByteOnTheRight: true)

        let scan = await ScanEngine.scan(root: fixture.path)
        let buckets = try #require(FolderSignature.candidates(
            in: scan.store, under: 0, minimumSize: 100
        ))
        #expect(!candidateNames(buckets, in: scan.store).contains(
            ["Photos", "Photos copie"]
        ))
        // Only the untouched subfolders still match.
        #expect(candidateNames(buckets, in: scan.store) == [["raw"]])
    }

    @Test("A mount point anywhere below disqualifies the whole subtree")
    func mountPointDisqualifies() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        var store = scan.store
        // What a mounted volume looks like from the scan's point of view: the
        // stub is recorded, its contents belong to another disk. Two of them
        // fingerprint identically no matter what is actually mounted there.
        let mounted = try #require(
            store.descendant(of: 0, at: ["Photos copie", "raw"])
        )
        store.markFlag(.mountPoint, on: mounted)

        let table = FolderSignature.table(of: store)
        #expect(table.disqualified[Int(mounted)])
        let copy = try #require(store.child(of: 0, named: "Photos copie"))
        #expect(table.disqualified[Int(copy)])

        let buckets = try #require(FolderSignature.candidates(
            in: store, under: 0, minimumSize: 100
        ))
        let proposed = Set(buckets.flatMap { $0 })
        #expect(!proposed.contains(mounted))
        #expect(!proposed.contains(copy))
    }

    @Test("A cp -al twin never becomes a candidate")
    func hardLinkedTwinExcluded() async throws {
        let fixture = try Fixture()
        try fixture.file("orig/data.bin", content: filler(4, count: 4_000))
        try fixture.directory("clone")
        try fixture.hardLink("orig/data.bin", to: "clone/data.bin")

        let scan = await ScanEngine.scan(root: fixture.path)
        let store = scan.store
        // The scan zeroes the second path it reaches for an inode, and which
        // one that is depends on the order the workers ran in — so one of the
        // two folders is poisoned, and there is no telling which.
        let doubled = try #require(store.children(of: 0).first { folder in
            store.children(of: folder).contains {
                store.flags[Int($0)].contains(.hardlinkDuplicate)
            }
        })
        let table = FolderSignature.table(of: store)
        #expect(table.disqualified[Int(doubled)])

        let buckets = try #require(FolderSignature.candidates(
            in: store, under: 0, minimumSize: 100
        ))
        let proposed = Set(buckets.flatMap { $0 })
        #expect(!proposed.contains(doubled))
        // And with its twin gone the survivor is alone, so no bucket forms.
        #expect(buckets.isEmpty)
    }

    @Test("Neither the scan root nor the folder on screen is ever proposed")
    func neverProposesTheGroundUnderfoot() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("here/Photos", "here/Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        let store = scan.store
        let here = try #require(store.child(of: 0, named: "here"))
        let buckets = try #require(FolderSignature.candidates(
            in: store, under: here, minimumSize: 100
        ))
        let proposed = Set(buckets.flatMap { $0 })
        #expect(!proposed.contains(here))
        #expect(!proposed.contains(0))
        #expect(proposed.contains(try #require(
            store.descendant(of: 0, at: ["here", "Photos"])
        )))
    }

    @Test("Folders below the threshold are never candidates")
    func thresholdFilters() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        let buckets = try #require(FolderSignature.candidates(
            in: scan.store, under: 0, minimumSize: 100_000_000
        ))
        #expect(buckets.isEmpty)
    }
}

@Suite("Folder duplicates")
struct FolderDuplicatesTests {

    /// Tiny thresholds and a 16-byte prefix, so the fixtures stay small while
    /// still crossing the prefix/full boundary the way real files do.
    private var options: DuplicateFinder.Options {
        var options = DuplicateFinder.Options()
        options.minimumSize = 100
        options.folderMinimumSize = 100
        options.prefixLength = 16
        return options
    }

    private func names(
        _ group: FolderGroup, in store: NodeStore
    ) -> Set<String> {
        Set(group.folders.map(store.name(of:)))
    }

    @Test("Two identical folders are confirmed, whatever their names")
    func identicalFoldersConfirm() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        // Both the pair of roots and the pair of `raw` subfolders: the engine
        // reports every confirmed group, the display shows only the top.
        let found = Set(result.folderGroups.map { names($0, in: scan.store) })
        #expect(found.contains(["Photos", "Photos copie"]))
        #expect(found.contains(["raw"]))
        #expect(result.droppedCount == 0)
    }

    @Test("A subfolder added since the scan separates them")
    func liveReadSeesWhatTheScanMissed() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        // The one drift the hasher cannot catch: it re-stats and reopens what
        // it knows about, and knows nothing of an entry that appeared since.
        // Without a live read the folders would confirm as identical moments
        // before one of them went to the Trash, taking this with it.
        try fixture.directory("Photos copie/added")

        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let found = Set(result.folderGroups.map { names($0, in: scan.store) })
        #expect(!found.contains(["Photos", "Photos copie"]))
        #expect(found == [["raw"]])
    }

    @Test("Symlinks of the same length pointing elsewhere separate them")
    func symlinkTargetsAreCompared() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")
        // Same length, so the scan sees two identically sized symlinks and F0
        // cannot tell them apart. Only the target does.
        try fixture.symlink("./a.bin", at: "Photos/latest")
        try fixture.symlink("./b.bin", at: "Photos copie/latest")

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let found = Set(result.folderGroups.map { names($0, in: scan.store) })
        #expect(!found.contains(["Photos", "Photos copie"]))
    }

    @Test("An unreadable subfolder leaves the pair unconfirmed, never confirmed")
    func unreadableFailsClosed() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        // Locked *after* the scan, so both folders are still candidates: this
        // is the fail-closed path, not the disqualification one. And locked on
        // both sides, which is the likeliest case by far — they are copies, so
        // they carry the same permissions. Skipping what cannot be read would
        // have them compose the same fingerprint out of the readable
        // remainder, and one of them would be offered for deletion.
        try fixture.chmod("Photos/raw", 0o000)
        try fixture.chmod("Photos copie/raw", 0o000)
        defer {
            try? fixture.chmod("Photos/raw", 0o755)
            try? fixture.chmod("Photos copie/raw", 0o755)
        }

        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.folderGroups.isEmpty)
        #expect(result.droppedCount > 0)
    }

    @Test("An unreadable file leaves the pair unconfirmed too")
    func unhashableFileFailsClosed() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        // The manifest lists it fine; the hasher cannot open it. `hash(jobs:)`
        // only ever reports its successes, so this is where composing around a
        // gap would go wrong.
        try fixture.chmod("Photos/a.bin", 0o000)
        try fixture.chmod("Photos copie/a.bin", 0o000)
        defer {
            try? fixture.chmod("Photos/a.bin", 0o644)
            try? fixture.chmod("Photos copie/a.bin", 0o644)
        }

        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let found = Set(result.folderGroups.map { names($0, in: scan.store) })
        #expect(!found.contains(["Photos", "Photos copie"]))
        #expect(result.droppedCount > 0)
    }

    @Test("A fifo is recorded and never opened, so nothing hangs")
    func fifoDoesNotBlock() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")
        try fixture.fifo("Photos/pipe")
        try fixture.fifo("Photos copie/pipe")

        // If a named pipe ever became a hashing job this call would never
        // return: `open` blocks in the kernel until someone writes, and
        // cancellation is only tested between blocks.
        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let found = Set(result.folderGroups.map { names($0, in: scan.store) })
        #expect(found.contains(["Photos", "Photos copie"]))
    }

    @Test("A shared prefix with a different tail is not a folder duplicate")
    func prefixIsNotEnoughForFolders() async throws {
        let fixture = try Fixture()
        let left = filler(9, count: 4_000)
        var right = left
        right[3_000] ^= 0xFF // identical for far more than the 16-byte prefix
        try fixture.file("Photos/big.bin", content: left)
        try fixture.file("Photos copie/big.bin", content: right)

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(result.folderGroups.isEmpty)
    }

    @Test("Nested duplicates are all reported, outer and inner")
    func nestedGroupsAreAllProduced() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Outer/Photos", "Outer copie/Photos")

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let found = Set(result.folderGroups.map { names($0, in: scan.store) })
        #expect(found.contains(["Outer", "Outer copie"]))
        #expect(found.contains(["Photos"]))
        #expect(found.contains(["raw"]))
    }

    @Test("Cancellation during the folder pass returns nil")
    func cancellationDuringFolders() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        let store = scan.store
        let opts = options
        let task = Task {
            await DuplicateFinder.find(in: store, under: 0, options: opts)
        }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("The folder pass is off unless a threshold asks for it")
    func offByDefault() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        var noFolders = options
        noFolders.folderMinimumSize = nil
        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: noFolders
        ))
        #expect(result.folderGroups.isEmpty)
        #expect(!result.groups.isEmpty) // the files are still found
    }
}

@Suite("Folder reclaim arithmetic")
struct FolderReclaimTests {

    private var options: DuplicateFinder.Options {
        var options = DuplicateFinder.Options()
        options.minimumSize = 100
        options.folderMinimumSize = 100
        options.prefixLength = 16
        return options
    }

    @Test("A clean pair frees one copy's worth, never both")
    func cleanPair() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        let scan = await ScanEngine.scan(root: fixture.path)
        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let group = try #require(result.folderGroups.first {
            Set($0.folders.map(scan.store.name(of:)))
                == ["Photos", "Photos copie"]
        })
        #expect(group.folders.count == 2)
        #expect(group.fileCount == 3)
        #expect(group.bytesEach > 0)
        // Sum minus the largest: one copy stays, and the biggest stays for
        // free. Both copies are clean, so that is exactly one copy's bytes.
        let free = group.folders.map { group.freeableBytes[$0] ?? 0 }
        #expect(free.allSatisfy { $0 > 0 })
        #expect(group.reclaimableBytes == free.reduce(0, +) - free.max()!)
        #expect(group.reclaimableBytes <= group.bytesEach)
    }

    @Test("Bytes linked from outside the folder are not freeable")
    func linkedFromOutside() async throws {
        let fixture = try Fixture()
        try fixture.file("Photos/big.bin", content: filler(11, count: 40_000))
        try fixture.file("Photos copie/big.bin", content: filler(11, count: 40_000))
        try fixture.file("elsewhere/placeholder.bin", content: filler(12, count: 40_000))

        let scan = await ScanEngine.scan(root: fixture.path)
        // Linked after the scan, so no node carries `.hardlinkDuplicate` and
        // both folders stay candidates — the disqualification and the
        // arithmetic are two different guards and this test is about the
        // second one. `Photos/big.bin` now has two links, only one of which is
        // inside the folder: trashing Photos leaves its bytes on the disk.
        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent("elsewhere/placeholder.bin")
        )
        try fixture.hardLink("Photos/big.bin", to: "elsewhere/placeholder.bin")

        let result = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        let group = try #require(result.folderGroups.first {
            Set($0.folders.map(scan.store.name(of:)))
                == ["Photos", "Photos copie"]
        })
        let linked = try #require(scan.store.child(of: 0, named: "Photos"))
        let clean = try #require(scan.store.child(of: 0, named: "Photos copie"))
        let linkedFree = try #require(group.freeableBytes[linked])
        let cleanFree = try #require(group.freeableBytes[clean])
        #expect(linkedFree < cleanFree)
        #expect(cleanFree - linkedFree >= 40_000)
        // Keeping the copy that frees the most leaves only the poorer one.
        #expect(group.reclaimableBytes == linkedFree)
    }
}

@Suite("Shared digest cache")
struct DigestCacheTests {

    @Test("A prefix digest is never handed back as a whole-file digest")
    func prefixAndFullNeverCollide() async throws {
        let fixture = try Fixture()
        // Identical far past the 16-byte prefix, different at the end. Keyed on
        // the inode alone, the folder pass's prefix digest would come back to
        // the file pass as this file's whole content, and Silt would offer to
        // delete one of two files that are not the same.
        let left = filler(21, count: 4_000)
        var right = left
        right[3_500] ^= 0xFF
        try fixture.file("Photos/big.bin", content: left)
        try fixture.file("Photos copie/big.bin", content: right)

        var options = DuplicateFinder.Options()
        options.minimumSize = 100
        options.folderMinimumSize = 100
        options.prefixLength = 16

        let scan = await ScanEngine.scan(root: fixture.path)
        let both = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: options
        ))
        #expect(both.folderGroups.isEmpty)
        #expect(both.groups.isEmpty)

        // Both passes wanted the same two digests of the same two files, and
        // the disk was read for them once: 16 bytes each, then 4 000 each.
        #expect(both.bytesHashed == 2 * 16 + 2 * 4_000)

        var filesOnly = options
        filesOnly.folderMinimumSize = nil
        let alone = try #require(await DuplicateFinder.find(
            in: scan.store, under: 0, options: filesOnly
        ))
        #expect(alone.bytesHashed == both.bytesHashed)
    }

    @Test("A file rewritten between two passes is hashed again, not remembered")
    func staleEntriesAreRejected() async throws {
        let cache = DuplicateFinder.DigestCache()
        let id = DuplicateFinder.FileID(device: 1, inode: 42)
        let key = DuplicateFinder.DigestCache.Key(fileID: id, limit: -1)
        cache.store([1, 2, 3], for: key, size: 100, modTime: 1_000)

        #expect(cache.digest(for: key, size: 100, modTime: 1_000) == [1, 2, 3])
        // An inode is reused the moment a file is deleted, and a rewrite in
        // place keeps both the inode and the size.
        #expect(cache.digest(for: key, size: 100, modTime: 1_001) == nil)
        #expect(cache.digest(for: key, size: 200, modTime: 1_000) == nil)
        let prefix = DuplicateFinder.DigestCache.Key(fileID: id, limit: 16)
        #expect(cache.digest(for: prefix, size: 100, modTime: 1_000) == nil)
    }
}

@Suite("Folder coverage")
struct FolderCoverageTests {

    private func node(_ store: NodeStore, _ path: [String]) throws -> Int32 {
        try #require(store.descendant(of: 0, at: path))
    }

    @Test("Only the topmost group of a nest is shown")
    func topmostOnly() async throws {
        let fixture = try Fixture()
        try fixture.threeFolders()
        let store = await ScanEngine.scan(root: fixture.path).store
        let outer = [try node(store, ["A"]), try node(store, ["B"])]
        let inner = [try node(store, ["A", "sub"]), try node(store, ["B", "sub"])]

        let plan = FolderCoverage.plan(for: [inner, outer], in: store)
        // Order in is irrelevant — depth decides, so the outer pair wins
        // whichever way the engine happened to report them.
        #expect(plan.visible == [1])
    }

    @Test("An inner group with a copy outside the covered folders stays")
    func partiallyCoveredGroupSurvives() async throws {
        let fixture = try Fixture()
        try fixture.threeFolders()
        let store = await ScanEngine.scan(root: fixture.path).store
        let outer = [try node(store, ["A"]), try node(store, ["B"])]
        // `A/sub` is covered by the outer group, `C` is not — the pair is
        // still worth resolving, and hiding it would lose that.
        let mixed = [try node(store, ["A", "sub"]), try node(store, ["C"])]

        let plan = FolderCoverage.plan(for: [outer, mixed], in: store)
        #expect(Set(plan.visible) == [0, 1])
    }

    @Test("Only the non-canonical copies absorb, so {A/x, C/x} survives")
    func absorptionSparesTheCanonicalCopy() async throws {
        let fixture = try Fixture()
        try fixture.threeFolders()
        let store = await ScanEngine.scan(root: fixture.path).store
        let a = try node(store, ["A"])
        let b = try node(store, ["B"])
        let plan = FolderCoverage.plan(for: [[a, b]], in: store)

        // One of the two survives, and it is the shallower/alphabetically
        // first — never both, never neither.
        #expect(plan.absorbing.count == 1)
        #expect(plan.absorbing == [b])
        // So the file group {A/x, B/x, C/x} loses only B/x and keeps its two
        // remaining members, which is a duplicate the user can still act on.
        let hidden = [
            try node(store, ["A", "x.bin"]),
            try node(store, ["B", "x.bin"]),
            try node(store, ["C", "x.bin"]),
        ].filter { FolderCoverage.hasAncestor(of: $0, in: plan.absorbing, store: store) }
        #expect(hidden == [try node(store, ["B", "x.bin"])])
    }

    @Test("Managed storage never becomes the copy that survives")
    func canonicalPrefersUnmanaged() async throws {
        let fixture = try Fixture()
        try fixture.threeFolders()
        let store = await ScanEngine.scan(root: fixture.path).store
        let a = try node(store, ["A"])
        let b = try node(store, ["B"])
        // Same depth, so the tie falls to the managed flag before the name:
        // an app's own folder is a poor thing to designate as the survivor.
        let plan = FolderCoverage.plan(
            for: [[a, b]], in: store, isManaged: { $0 == a }
        )
        #expect(plan.absorbing == [a])
    }

    @Test("A search about something inside the folder absorbs nothing")
    func searchInsideDoesNotAbsorb() async throws {
        let fixture = try Fixture()
        try fixture.threeFolders()
        let store = await ScanEngine.scan(root: fixture.path).store
        let a = try node(store, ["A"])
        let b = try node(store, ["B"])
        // What `searchMask.matches` says while the user is looking for
        // `x.bin`: the folders are kept because they hold a result, but the
        // query is not about them. Absorbing here would hide the very files
        // being searched for.
        let plan = FolderCoverage.plan(
            for: [[a, b]], in: store, absorbs: { _ in false }
        )
        #expect(plan.visible == [0])
        #expect(plan.absorbing.isEmpty)
    }

    @Test("Duplication inside the copy that survives is never swallowed")
    func internalDuplicationSurvives() async throws {
        let fixture = try Fixture()
        // Two identical files *inside* each copy, so `{A/p, A/q, B/p, B/q}` is
        // one file group that overlaps the folder group entirely.
        for root in ["A", "B"] {
            for name in ["p.bin", "q.bin"] {
                try fixture.file("\(root)/\(name)", content: filler(5, count: 300))
            }
        }
        var store = await ScanEngine.scan(root: fixture.path).store
        let a = try #require(store.child(of: 0, named: "A"))
        let b = try #require(store.child(of: 0, named: "B"))

        let plan = FolderCoverage.plan(for: [[a, b]], in: store)
        #expect(plan.absorbing == [b])
        let copies = try ["A", "B"].flatMap { root in
            try ["p.bin", "q.bin"].map {
                try #require(store.descendant(of: 0, at: [root, $0]))
            }
        }
        let surviving = copies.filter {
            !FolderCoverage.hasAncestor(of: $0, in: plan.absorbing, store: store)
        }
        // `{A/p, A/q}` is still two copies of one content: the folder group
        // takes B away, and what A duplicates inside itself stays actionable.
        #expect(surviving.count == 2)
        #expect(surviving.allSatisfy { store.parent[Int($0)] == a })

        // And it survives B actually going to the Trash, from the same result
        // in memory — the engine is not run again.
        store.markDeleted(b)
        #expect(surviving.allSatisfy { !store.isEffectivelyDeleted($0) })
        #expect(store.isEffectivelyDeleted(
            try #require(store.descendant(of: 0, at: ["B", "p.bin"]))
        ))
    }
}

@Suite("Files that are not on this disk")
struct DatalessTests {

    /// Marks a node the way the scan marks an evicted iCloud file: present in
    /// the listing, zero bytes on disk, contents elsewhere.
    private func evict(_ node: Int32, in store: inout NodeStore) {
        store.markFlag(.dataless, on: node)
    }

    @Test("An evicted file is never a duplicate candidate")
    func datalessFilesAreNotCandidates() async throws {
        let fixture = try Fixture()
        try fixture.file("here.bin", content: filler(30, count: 4_000))
        try fixture.file("there.bin", content: filler(30, count: 4_000))

        var options = DuplicateFinder.Options()
        options.minimumSize = 100
        options.prefixLength = 16

        let scan = await ScanEngine.scan(root: fixture.path)
        var store = scan.store
        // Both are in iCloud. The scan still records their *logical* size —
        // that is the size of the file that is not here — so without the flag
        // they bucket together like any other pair and get hashed, which
        // downloads them. On a disk the user opened this app to empty.
        for name in ["here.bin", "there.bin"] {
            evict(try #require(store.child(of: 0, named: name)), in: &store)
        }

        let result = try #require(await DuplicateFinder.find(
            in: store, under: 0, options: options
        ))
        #expect(result.groups.isEmpty)
        #expect(result.candidateCount == 0)
        // And not one byte was read, which is the whole point.
        #expect(result.bytesHashed == 0)
        #expect(result.datalessCount == 2)
    }

    @Test("A folder holding an evicted file is never confirmed")
    func datalessDisqualifiesTheFolder() async throws {
        let fixture = try Fixture()
        try fixture.twoCopies("Photos", "Photos copie")

        var options = DuplicateFinder.Options()
        options.minimumSize = 100
        options.folderMinimumSize = 100
        options.prefixLength = 16

        let scan = await ScanEngine.scan(root: fixture.path)
        var store = scan.store
        evict(
            try #require(store.descendant(of: 0, at: ["Photos", "raw", "c.bin"])),
            in: &store
        )

        let result = try #require(await DuplicateFinder.find(
            in: store, under: 0, options: options
        ))
        let names = Set(result.folderGroups.map {
            Set($0.folders.map(store.name(of:)))
        })
        // Neither `Photos` nor the `raw` that holds it: comparing either means
        // downloading, and the copy weighs nothing here anyway.
        #expect(!names.contains(["Photos", "Photos copie"]))
        #expect(!names.contains(["raw"]))
    }
}
