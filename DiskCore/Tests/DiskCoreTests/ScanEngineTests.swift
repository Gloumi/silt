import Darwin
import Foundation
import Testing

@testable import DiskCore

/// Builds a throwaway tree on the real filesystem, because the whole point of
/// these tests is that we agree with the kernel — a mocked filesystem would only
/// verify our own assumptions back to us.
struct Fixture: ~Copyable {
    let root: URL

    init(_ name: String = UUID().uuidString) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskcore-tests-\(name)")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var path: String { root.path }

    @discardableResult
    func file(_ relative: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    func hardLink(_ target: String, to relative: String) throws {
        try FileManager.default.linkItem(
            at: root.appendingPathComponent(target),
            to: root.appendingPathComponent(relative)
        )
    }

    func symlink(_ destination: String, at relative: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(relative).path,
            withDestinationPath: destination
        )
    }

    /// `du -sk`, in bytes. The reference every size assertion is judged against.
    func duBytes() throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let field = String(decoding: data, as: UTF8.self)
            .split(separator: "\t").first ?? "0"
        return (Int64(field.trimmingCharacters(in: .whitespaces)) ?? 0) * 1024
    }
}

@Suite("Scan engine")
struct ScanEngineTests {

    @Test("Totals match du for a plain tree")
    func matchesDu() async throws {
        let fixture = try Fixture()
        try fixture.file("a.bin", bytes: 40_000)
        try fixture.file("nested/b.bin", bytes: 8_000)
        try fixture.file("nested/deep/c.bin", bytes: 1)
        try fixture.directory("empty")

        let result = await ScanEngine.scan(root: fixture.path)
        #expect(result.rootTotalAlloc == (try fixture.duBytes()))
        #expect(result.filesSeen == 3)
    }

    @Test("A hard link is counted once, like du")
    func hardLinksCountedOnce() async throws {
        let fixture = try Fixture()
        try fixture.file("original.bin", bytes: 60_000)
        try fixture.hardLink("original.bin", to: "same-inode.bin")

        let result = await ScanEngine.scan(root: fixture.path)
        #expect(result.rootTotalAlloc == (try fixture.duBytes()))

        // Both links get a node, but only one carries the bytes.
        let store = result.store
        let children = store.children(of: 0)
        #expect(children.count == 2)
        let duplicates = children.filter {
            store.flags[Int($0)].contains(.hardlinkDuplicate)
        }
        #expect(duplicates.count == 1)
        #expect(store.totalAlloc[Int(duplicates[0])] == 0)
    }

    @Test("Symlinks are not followed")
    func symlinksNotFollowed() async throws {
        let fixture = try Fixture()
        try fixture.file("real/payload.bin", bytes: 50_000)
        // A link back to the root would loop forever if we followed it.
        try fixture.symlink(fixture.path, at: "loop")

        let result = await ScanEngine.scan(root: fixture.path)
        #expect(result.rootTotalAlloc == (try fixture.duBytes()))

        // Terminating at all is the real assertion: following the link would
        // recurse until the path length blew up. The link is still listed as an
        // entry (Finder counts it too), it just contributes nothing and has no
        // children.
        let store = result.store
        let link = try #require(
            store.children(of: 0).first { store.name(of: $0) == "loop" }
        )
        #expect(store.flags[Int(link)].contains(.symlink))
        #expect(store.childCount[Int(link)] == 0)
        #expect(store.count == 4) // root, real/, payload.bin, loop
    }

    @Test("Sparse files report on-disk size, not logical size")
    func sparseFileUsesAllocatedSize() async throws {
        let fixture = try Fixture()
        let sparse = fixture.root.appendingPathComponent("sparse.bin")
        let fd = open(sparse.path, O_CREAT | O_RDWR, 0o644)
        try #require(fd >= 0)
        // Seek far out and write one byte: 1 MB logical, a block on disk.
        _ = lseek(fd, 1_000_000, SEEK_SET)
        var byte: UInt8 = 1
        _ = write(fd, &byte, 1)
        close(fd)

        let result = await ScanEngine.scan(root: fixture.path)
        #expect(result.rootTotalLogical > result.rootTotalAlloc)
        #expect(result.rootTotalAlloc == (try fixture.duBytes()))
    }

    @Test("Collapsed directories keep their size but produce no child nodes")
    func collapsedDirectories() async throws {
        let fixture = try Fixture()
        try fixture.file("src/main.swift", bytes: 1_000)
        try fixture.file("node_modules/pkg/index.js", bytes: 30_000)
        try fixture.file("node_modules/pkg/readme.md", bytes: 20_000)

        var options = ScanOptions()
        options.collapsedDirectoryNames = ["node_modules"]
        let collapsed = await ScanEngine.scan(root: fixture.path, options: options)

        options.collapsedDirectoryNames = []
        let full = await ScanEngine.scan(root: fixture.path, options: options)

        // Same bytes either way — collapsing hides detail, never size.
        #expect(collapsed.rootTotalAlloc == full.rootTotalAlloc)
        #expect(collapsed.rootTotalAlloc == (try fixture.duBytes()))
        #expect(collapsed.filesSeen == full.filesSeen)
        #expect(collapsed.store.count < full.store.count)

        let store = collapsed.store
        let modules = try #require(
            store.children(of: 0).first { store.name(of: $0) == "node_modules" }
        )
        #expect(store.flags[Int(modules)].contains(.notDescended))
        #expect(store.childCount[Int(modules)] == 0)
    }

    @Test("Bundles are leaves by default and descendable on request")
    func packagesAreLeaves() async throws {
        let fixture = try Fixture()
        try fixture.file("Thing.app/Contents/MacOS/Thing", bytes: 70_000)

        let leaf = await ScanEngine.scan(root: fixture.path)
        let app = try #require(leaf.store.children(of: 0).first)
        #expect(leaf.store.flags[Int(app)].contains(.package))
        #expect(leaf.store.childCount[Int(app)] == 0)
        #expect(leaf.rootTotalAlloc == (try fixture.duBytes()))

        var options = ScanOptions()
        options.descendIntoPackages = true
        let deep = await ScanEngine.scan(root: fixture.path, options: options)
        #expect(deep.rootTotalAlloc == leaf.rootTotalAlloc)
        #expect(deep.store.count > leaf.store.count)
    }

    @Test("An unreadable directory is reported instead of silently dropped")
    func unreadableDirectoryIsReported() async throws {
        let fixture = try Fixture()
        try fixture.file("visible.bin", bytes: 5_000)
        let locked = try fixture.directory("locked")
        try fixture.file("locked/hidden.bin", bytes: 5_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
        }

        let result = await ScanEngine.scan(root: fixture.path)
        #expect(result.unreadablePaths.count == 1)
        #expect(result.unreadablePaths[0].hasSuffix("locked"))

        let store = result.store
        let node = try #require(
            store.children(of: 0).first { store.name(of: $0) == "locked" }
        )
        #expect(store.flags[Int(node)].contains(.unreadable))
    }

    @Test("Paths rebuild correctly from node indices")
    func pathReconstruction() async throws {
        let fixture = try Fixture()
        try fixture.file("one/two/three.bin", bytes: 100)

        let result = await ScanEngine.scan(root: fixture.path)
        let store = result.store
        var node: Int32 = 0
        for component in ["one", "two", "three.bin"] {
            node = try #require(
                store.children(of: node).first { store.name(of: $0) == component }
            )
        }
        // The fixture path may itself contain symlinks (/var -> /private/var),
        // which the scanner resolves, so compare against the resolved root.
        let expected = store.name(of: 0) + "/one/two/three.bin"
        #expect(store.path(of: node) == expected)
    }

    @Test("Roll-up is consistent with the sum of every leaf")
    func rollUpConsistency() async throws {
        let fixture = try Fixture()
        for i in 0..<20 {
            try fixture.file("dir\(i % 4)/sub\(i % 3)/file\(i).bin", bytes: 1_000 * (i + 1))
        }

        let result = await ScanEngine.scan(root: fixture.path)
        let store = result.store
        // Every node's total must equal its own size plus its children's totals.
        for node in 0..<Int32(store.count) {
            let childSum = store.children(of: node)
                .reduce(Int64(0)) { $0 + store.totalAlloc[Int($1)] }
            #expect(store.totalAlloc[Int(node)] >= childSum)
        }
        #expect(store.totalAlloc[0] == (try fixture.duBytes()))
        #expect(store.fileCount[0] == 20)
    }

    @Test("Cancellation stops the scan and says so")
    func cancellation() async throws {
        let task = Task {
            await ScanEngine.scan(root: NSHomeDirectory() + "/Library")
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        #expect(result.wasCancelled)
    }
}
