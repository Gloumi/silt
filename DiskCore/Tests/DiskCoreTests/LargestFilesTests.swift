import Darwin
import Foundation
import Testing

@testable import DiskCore

@Suite("Largest files")
struct LargestFilesTests {

    @Test("Files come back sorted and scoped to the requested subtree")
    func sortedAndScoped() async throws {
        let fixture = try Fixture()
        try fixture.file("a/big.bin", bytes: 90_000)
        try fixture.file("a/sub/mid.bin", bytes: 50_000)
        try fixture.file("b/huge.bin", bytes: 200_000)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let a = try #require(store.child(of: 0, named: "a"))

        // Asked about `a`, the answer must not mention `b`'s contents.
        let underA = LargestFiles.top(in: store, under: a)
        #expect(underA.map { store.name(of: $0) } == ["big.bin", "mid.bin"])

        let all = LargestFiles.top(in: store, under: 0)
        #expect(all.map { store.name(of: $0) } == ["huge.bin", "big.bin", "mid.bin"])
    }

    @Test("The limit holds, and keeps the right files through compaction")
    func limitIsRespected() async throws {
        let fixture = try Fixture()
        // Enough files to force several compaction rounds at this limit.
        for i in 1...12 {
            try fixture.file("dir\(i % 3)/file\(i).bin", bytes: 1_000 * i)
        }

        let store = (await ScanEngine.scan(root: fixture.path)).store
        // Logical sizes, deliberately: on-disk sizes round up to whole blocks,
        // which makes 9…12 kB files all the same size and their order moot.
        let top = LargestFiles.top(in: store, under: 0, limit: 3, useLogical: true)
        #expect(top.map { store.name(of: $0) }
            == ["file12.bin", "file11.bin", "file10.bin"])
    }

    @Test("A collapsed directory is one entry, not its hidden contents")
    func collapsedDirectoryIsOneEntry() async throws {
        let fixture = try Fixture()
        try fixture.file("src/main.swift", bytes: 1_000)
        try fixture.file("node_modules/pkg/index.js", bytes: 60_000)

        var options = ScanOptions()
        options.collapsedDirectoryNames = ["node_modules"]
        let store = (await ScanEngine.scan(root: fixture.path, options: options)).store

        let top = LargestFiles.top(in: store, under: 0)
        let first = try #require(top.first)
        #expect(store.name(of: first) == "node_modules")
        #expect(store.flags[Int(first)].contains(.notDescended))
        // Its files have no nodes; nothing inside it can appear separately.
        #expect(!top.map { store.name(of: $0) }.contains("index.js"))
    }

    @Test("Deleted items disappear, including files under a deleted folder")
    func deletionExcludes() async throws {
        let fixture = try Fixture()
        try fixture.file("keep.bin", bytes: 10_000)
        try fixture.file("gone.bin", bytes: 80_000)
        try fixture.file("folder/inside.bin", bytes: 40_000)

        var store = (await ScanEngine.scan(root: fixture.path)).store
        store.markDeleted(try #require(store.child(of: 0, named: "gone.bin")))
        // Only the folder is marked — its descendants keep their flags and
        // sizes, which is exactly why the walk must not descend into it.
        store.markDeleted(try #require(store.child(of: 0, named: "folder")))

        let top = LargestFiles.top(in: store, under: 0)
        #expect(top.map { store.name(of: $0) } == ["keep.bin"])
    }

    @Test("A hard link appears once")
    func hardLinkAppearsOnce() async throws {
        let fixture = try Fixture()
        try fixture.file("original.bin", bytes: 60_000)
        try fixture.hardLink("original.bin", to: "same-inode.bin")

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let top = LargestFiles.top(in: store, under: 0)
        #expect(top.count == 1)
        #expect(!store.flags[Int(top[0])].contains(.hardlinkDuplicate))
    }

    @Test("An age cutoff drops recent files and keeps the size ordering")
    func ageCutoffFiltersButKeepsOrder() async throws {
        let fixture = try Fixture()
        try fixture.file("huge-recent.bin", bytes: 200_000)
        try fixture.file("big-stale.bin", bytes: 90_000)
        try fixture.file("small-stale.bin", bytes: 50_000)
        try fixture.setModified("huge-recent.bin", daysAgo: 3)
        try fixture.setModified("big-stale.bin", daysAgo: 500)
        try fixture.setModified("small-stale.bin", daysAgo: 900)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let cutoff = Int32(Date().timeIntervalSince1970 - 365 * 86_400)
        let stale = LargestFiles.top(in: store, under: 0, modifiedBefore: cutoff)

        // The biggest file is gone because it is recent, and what is left is
        // still ranked by size — not by age.
        #expect(stale.map { store.name(of: $0) } == ["big-stale.bin", "small-stale.bin"])
    }

    @Test("An old file under a busy folder is still found")
    func ageCutoffDoesNotPruneTheWalk() async throws {
        let fixture = try Fixture()
        // The folder's aggregated date is recent, but the file we want is not.
        // Pruning the descent on the folder would lose it entirely.
        try fixture.file("busy/forgotten.bin", bytes: 80_000)
        try fixture.file("busy/touched-today.bin", bytes: 1_000)
        try fixture.setModified("busy/forgotten.bin", daysAgo: 900)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let busy = try #require(store.child(of: 0, named: "busy"))
        let cutoff = Int32(Date().timeIntervalSince1970 - 365 * 86_400)
        #expect(store.modTime[Int(busy)] > cutoff) // premise: the folder is busy

        let stale = LargestFiles.top(in: store, under: 0, modifiedBefore: cutoff)
        #expect(stale.map { store.name(of: $0) } == ["forgotten.bin"])
    }

    @Test("Logical and on-disk orderings can differ, and both are honoured")
    func logicalSizeOrdering() async throws {
        let fixture = try Fixture()
        try fixture.file("dense.bin", bytes: 100_000)

        // A hole-only file: huge logically, nearly nothing on disk. Same
        // recipe as the sparse-file engine test — extend without writing.
        let sparse = fixture.root.appendingPathComponent("sparse.bin")
        let fd = open(sparse.path, O_CREAT | O_RDWR, 0o644)
        try #require(fd >= 0)
        let extended = ftruncate(fd, 1_000_000)
        close(fd)
        try #require(extended == 0)
        var info = stat()
        try #require(stat(sparse.path, &info) == 0)
        try #require(info.st_blocks * 512 < 100_000)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let onDisk = LargestFiles.top(in: store, under: 0)
        let logical = LargestFiles.top(in: store, under: 0, useLogical: true)
        #expect(store.name(of: try #require(onDisk.first)) == "dense.bin")
        #expect(store.name(of: try #require(logical.first)) == "sparse.bin")
    }
}
