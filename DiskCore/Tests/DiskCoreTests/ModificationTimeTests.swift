import Darwin
import Foundation
import Testing

@testable import DiskCore

/// Filesystem timestamps have one-second granularity, so dates are compared
/// with a little slack rather than for equality.
///
/// The slack is small on purpose, and `from` is what lets it stay that way:
/// measured against the fixture's own instant, the only error left is the
/// filesystem rounding. Read off `Date()` here instead and the gap would also
/// carry however long the scan took — which failed this suite roughly every
/// other run, since the tests run in parallel and a scan is seconds of work.
private func expectDays(
    _ seconds: Int32, agoBy days: Double, from reference: Date
) -> Bool {
    let expected = reference.timeIntervalSince1970 - days * 86_400
    return abs(Double(seconds) - expected) < 2
}

@Suite("Modification times")
struct ModificationTimeTests {

    @Test("Every file agrees with stat(2)")
    func agreesWithStat() async throws {
        let fixture = try Fixture()
        try fixture.file("plain.bin", bytes: 1_000)
        try fixture.file("deep/nested/other.bin", bytes: 2_000)
        try fixture.file("aged.bin", bytes: 500)
        try fixture.setModified("aged.bin", daysAgo: 1_234)

        let store = (await ScanEngine.scan(root: fixture.path)).store

        // The whole risk in reading `getattrlistbulk` is packing order: land one
        // field off and you get a plausible-looking number from the neighbouring
        // attribute. Only the kernel can settle that, so ask it directly.
        for node in Int32(1)..<Int32(store.count)
        where !store.isDirectory(node) {
            var info = stat()
            try #require(lstat(store.path(of: node), &info) == 0)
            #expect(store.modTime[Int(node)] == Int32(info.st_mtimespec.tv_sec),
                    "\(store.name(of: node))")
        }
    }

    @Test("A file keeps its own date")
    func fileKeepsItsDate() async throws {
        let fixture = try Fixture()
        try fixture.file("report.bin", bytes: 1_000)
        try fixture.setModified("report.bin", daysAgo: 400)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let file = try #require(store.child(of: 0, named: "report.bin"))
        #expect(expectDays(store.modTime[Int(file)], agoBy: 400, from: fixture.created))
    }

    @Test("A folder reports its newest descendant, not its own mtime")
    func folderReportsNewestDescendant() async throws {
        let fixture = try Fixture()
        try fixture.file("branch/deep/ancient.bin", bytes: 1_000)
        try fixture.file("branch/deep/fresh.bin", bytes: 1_000)
        try fixture.setModified("branch/deep/ancient.bin", daysAgo: 900)
        try fixture.setModified("branch/deep/fresh.bin", daysAgo: 2)
        // The folders themselves are backdated, so passing the test can only
        // come from the roll-up and never from a directory's own timestamp.
        try fixture.setModified("branch/deep", daysAgo: 900)
        try fixture.setModified("branch", daysAgo: 900)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let branch = try #require(store.child(of: 0, named: "branch"))
        let deep = try #require(store.child(of: branch, named: "deep"))

        // Two levels up, so this also covers the reverse pass being transitive.
        #expect(expectDays(store.modTime[Int(deep)], agoBy: 2, from: fixture.created))
        #expect(expectDays(store.modTime[Int(branch)], agoBy: 2, from: fixture.created))
    }

    @Test("An old folder stays old when nothing inside it is newer")
    func staleFolderStaysStale() async throws {
        let fixture = try Fixture()
        try fixture.file("attic/box.bin", bytes: 1_000)
        try fixture.setModified("attic/box.bin", daysAgo: 700)
        try fixture.setModified("attic", daysAgo: 500)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let attic = try #require(store.child(of: 0, named: "attic"))
        // Its own mtime wins here: 500 days is the newest thing about it.
        #expect(expectDays(store.modTime[Int(attic)], agoBy: 500, from: fixture.created))
    }

    @Test("A collapsed directory carries the newest date it hides")
    func collapsedDirectoryAggregatesDates() async throws {
        let fixture = try Fixture()
        try fixture.file("node_modules/pkg/old.js", bytes: 1_000)
        try fixture.file("node_modules/pkg/recent.js", bytes: 1_000)
        try fixture.setModified("node_modules/pkg/old.js", daysAgo: 800)
        try fixture.setModified("node_modules/pkg/recent.js", daysAgo: 3)
        try fixture.setModified("node_modules/pkg", daysAgo: 800)
        try fixture.setModified("node_modules", daysAgo: 800)

        var options = ScanOptions()
        options.collapsedDirectoryNames = ["node_modules"]
        let store = (await ScanEngine.scan(root: fixture.path, options: options)).store

        let modules = try #require(store.child(of: 0, named: "node_modules"))
        // Nothing inside got a node, so `rollUp` cannot help: this can only
        // work if `aggregateSubtree` tracked the date on its own way down.
        #expect(store.childCount[Int(modules)] == 0)
        #expect(expectDays(store.modTime[Int(modules)], agoBy: 3, from: fixture.created))
    }

    @Test("A bundle carries the newest date inside it too")
    func packageAggregatesDates() async throws {
        let fixture = try Fixture()
        try fixture.file("Thing.app/Contents/MacOS/Thing", bytes: 1_000)
        try fixture.setModified("Thing.app/Contents/MacOS/Thing", daysAgo: 5)
        try fixture.setModified("Thing.app/Contents/MacOS", daysAgo: 600)
        try fixture.setModified("Thing.app/Contents", daysAgo: 600)
        try fixture.setModified("Thing.app", daysAgo: 600)

        let store = (await ScanEngine.scan(root: fixture.path)).store
        let app = try #require(store.child(of: 0, named: "Thing.app"))
        #expect(store.flags[Int(app)].contains(.package))
        #expect(expectDays(store.modTime[Int(app)], agoBy: 5, from: fixture.created))
    }

    @Test("Roll-up maxes dates while it sums sizes")
    func rollUpMaxesDates() {
        var store = NodeStore()
        let root = store.append(
            name: Array("/root".utf8), parent: 0,
            alloc: 0, logical: 0, files: 0, modified: 100, flags: .directory
        )
        let dir = store.append(
            name: Array("dir".utf8), parent: root,
            alloc: 10, logical: 10, files: 0, modified: 4_000, flags: .directory
        )
        let file = store.append(
            name: Array("f.bin".utf8), parent: dir,
            alloc: 30, logical: 30, files: 1, modified: 2_000, flags: []
        )
        store.setChildren(of: root, start: dir, count: 1)
        store.setChildren(of: dir, start: file, count: 1)

        store.rollUp()

        // Sizes add up the tree, dates do not: the root takes the maximum it
        // can see (4 000), not the sum and not its own 100.
        #expect(store.totalAlloc[Int(root)] == 40)
        #expect(store.modTime[Int(root)] == 4_000)
        // And a parent already newer than its child keeps its own date.
        #expect(store.modTime[Int(dir)] == 4_000)
    }

    @Test("Rolling up twice changes nothing about the dates")
    func rollUpIsIdempotentForDates() {
        var store = NodeStore()
        let root = store.append(
            name: Array("/root".utf8), parent: 0,
            alloc: 0, logical: 0, files: 0, modified: 100, flags: .directory
        )
        let file = store.append(
            name: Array("f.bin".utf8), parent: root,
            alloc: 10, logical: 10, files: 1, modified: 9_000, flags: []
        )
        store.setChildren(of: root, start: file, count: 1)

        store.rollUp()
        let afterOnce = store.modTime
        store.rollUp()

        // Sizes would double here — the snapshot path only ever rolls up a
        // fresh copy — but `max` has to be stable regardless.
        #expect(store.modTime == afterOnce)
    }

    @Test("modificationDate reads back what was stored, and nil for no date")
    func modificationDateAccessor() {
        var store = NodeStore()
        store.append(
            name: Array("/root".utf8), parent: 0,
            alloc: 0, logical: 0, files: 0, modified: 0, flags: .directory
        )
        store.append(
            name: Array("f.bin".utf8), parent: 0,
            alloc: 10, logical: 10, files: 1, modified: 1_700_000_000, flags: []
        )

        #expect(store.modificationDate(of: 0) == nil)
        #expect(store.modificationDate(of: 1)?.timeIntervalSince1970 == 1_700_000_000)
    }
}
