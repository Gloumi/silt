import CoreGraphics
import Darwin
import Foundation
import Testing

@testable import DiskCore

@Suite("Search query")
struct SearchQueryTests {

    @Test("Only a leading dot or star-dot means an extension")
    func parsing() throws {
        #expect(try #require(SearchQuery("dmg")).kind == .substring)
        #expect(try #require(SearchQuery(".dmg")).kind == .fileExtension)
        #expect(try #require(SearchQuery("*.dmg")).kind == .fileExtension)
        // A bare dot narrows to "names containing a dot", which is a substring.
        #expect(try #require(SearchQuery(".")).kind == .substring)
        #expect(try #require(SearchQuery("  dmg  ")).text == "dmg")
    }

    @Test("Anything that would not narrow the tree is not a query")
    func emptyQueriesAreNil() {
        #expect(SearchQuery("") == nil)
        #expect(SearchQuery("   ") == nil)
        #expect(SearchQuery("*.") == nil)
    }
}

/// Builds a mask, spelling the query the way the user would type it.
///
/// Sizes are asserted logically throughout these suites: on-disk sizes round up
/// to whole blocks, which would make several of these files the same size and
/// their totals a matter of the filesystem's block size rather than ours.
private func mask(
    _ store: NodeStore, _ text: String, useLogical: Bool = true
) throws -> SearchMask {
    SearchMask.build(
        store: store, query: try #require(SearchQuery(text)),
        useLogical: useLogical
    )
}

/// The tree most of these tests read. Takes the fixture rather than returning
/// one: `Fixture` is noncopyable, so it cannot travel in a tuple.
private func mediaTree(in fixture: borrowing Fixture) throws {
    try fixture.file("Images/vacances.dmg", bytes: 300_000)
    try fixture.file("Images/notes-dmg.txt", bytes: 10_000)
    try fixture.file("Images/PHOTO.DMG", bytes: 50_000)
    try fixture.file("Code/projet/README.md", bytes: 2_000)
    try fixture.file("Code/projet/build.log", bytes: 800_000)
}

@Suite("Search mask")
struct SearchMaskTests {

    @Test("A folder only retains the part of itself that matches")
    func retainedIsTheMatchingPart() async throws {
        let fixture = try Fixture()
        try mediaTree(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store
        let images = try #require(store.child(of: 0, named: "Images"))

        // `.dmg` is strict: the two disk images, not the text file that merely
        // has "dmg" in its name.
        let strict = try mask(store, ".dmg")
        #expect(strict.bytes(of: images) == 350_000)
        #expect(strict.bytes(of: 0) == 350_000)

        // As a substring it picks up the text file too.
        let loose = try mask(store, "dmg")
        #expect(loose.bytes(of: images) == 360_000)

        // Either way the sibling branch retains nothing and is not drawn.
        let code = try #require(store.child(of: 0, named: "Code"))
        #expect(strict.bytes(of: code) == 0)
        #expect(!strict.keeps(code))
    }

    @Test("The scan root is never a match, whatever its path spells")
    func rootIsNeverAMatch() async throws {
        let fixture = try Fixture()
        try mediaTree(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store

        // The root's *name* is its absolute path, which always contains this.
        // Matching it would retain the whole disk and the filter would silently
        // do nothing.
        #expect(store.name(of: 0).contains("diskcore-tests"))

        let found = try mask(store, "diskcore-tests")
        #expect(found.totalResults == 0)
        #expect(found.bytes(of: 0) == 0)
    }

    @Test("Case is ignored on ASCII names")
    func asciiCaseFolding() async throws {
        let fixture = try Fixture()
        try mediaTree(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store
        let images = try #require(store.child(of: 0, named: "Images"))
        let photo = try #require(store.child(of: images, named: "PHOTO.DMG"))

        #expect(try mask(store, ".dmg").matches(photo))
        #expect(try mask(store, "photo").matches(photo))
    }

    @Test("A matching folder counts whole and takes its contents with it")
    func matchingFolderIsInherited() async throws {
        let fixture = try Fixture()
        try mediaTree(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store
        let code = try #require(store.child(of: 0, named: "Code"))
        let projet = try #require(store.child(of: code, named: "projet"))
        let readme = try #require(store.child(of: projet, named: "README.md"))

        let found = try mask(store, "projet")
        #expect(found.bytes(of: projet) == store.totalLogical[Int(projet)])
        // Without the inherit pass this is false, and opening the folder the
        // user just found would show an empty list.
        #expect(found.keeps(readme))
        #expect(found.matches(readme))
        // One result: the folder. Not one per file it happens to contain.
        #expect(found.totalResults == 1)
    }

    @Test("A match inside a matching folder is never counted twice")
    func noDoubleCounting() async throws {
        let fixture = try Fixture()
        try fixture.file("data/data.bin", bytes: 50_000)
        try fixture.file("data/other.bin", bytes: 30_000)
        let store = await ScanEngine.scan(root: fixture.path).store
        let data = try #require(store.child(of: 0, named: "data"))

        // Both the folder and a file inside it match. Adding the file's bytes
        // on top of the folder's own total would charge them twice.
        let found = try mask(store, "data")
        #expect(found.bytes(of: data) == store.totalLogical[Int(data)])
        #expect(found.bytes(of: 0) == store.totalLogical[Int(data)])
        #expect(found.totalResults == 2)
    }

    @Test("Deleted items retain nothing, and neither do their descendants")
    func deletionStopsTheRollUp() async throws {
        let fixture = try Fixture()
        try mediaTree(in: fixture)
        var store = await ScanEngine.scan(root: fixture.path).store
        let images = try #require(store.child(of: 0, named: "Images"))
        let photo = try #require(store.child(of: images, named: "PHOTO.DMG"))
        // Only the folder is marked — its descendants keep their flags and
        // sizes, which is why both passes have to stop on it.
        store.markDeleted(images)

        let found = try mask(store, ".dmg")
        #expect(found.bytes(of: 0) == 0)
        #expect(!found.keeps(images))
        #expect(!found.keeps(photo))
    }

    @Test("An empty file that matches is still kept")
    func zeroByteMatchSurvives() async throws {
        let fixture = try Fixture()
        try fixture.file("empty.dmg", bytes: 0)
        try fixture.file("filler.txt", bytes: 1_000)
        let store = await ScanEngine.scan(root: fixture.path).store
        let empty = try #require(store.child(of: 0, named: "empty.dmg"))

        // `retained > 0` cannot answer this, which is why `kept` is its own bit.
        let found = try mask(store, ".dmg")
        #expect(found.keeps(empty))
        #expect(found.bytes(of: empty) == 0)
        #expect(found.totalResults == 1)
    }

    @Test("Focus lands on the closest folder holding all the results")
    func focusFindsTheCommonAncestor() async throws {
        let fixture = try Fixture()
        try fixture.file("a/b/c/target.dmg", bytes: 40_000)
        try fixture.file("a/b/c/neighbour.txt", bytes: 1_000)
        try fixture.file("elsewhere/noise.txt", bytes: 1_000)
        let store = await ScanEngine.scan(root: fixture.path).store

        // One result, three levels down: the answer is the folder holding it,
        // not the root, whose treemap would spend its depth on empty corridors.
        let a = try #require(store.child(of: 0, named: "a"))
        let b = try #require(store.child(of: a, named: "b"))
        let c = try #require(store.child(of: b, named: "c"))
        #expect(try mask(store, ".dmg").focus(from: 0, in: store) == c)

        // Results in two branches: the descent stops where they part.
        try fixture.file("elsewhere/second.dmg", bytes: 40_000)
        let widened = await ScanEngine.scan(root: fixture.path).store
        #expect(try mask(widened, ".dmg").focus(from: 0, in: widened) == 0)
    }

    @Test("A unique file deep in a home-shaped tree recentres on its folder")
    func focusDescendsInARealisticTree() async throws {
        let fixture = try Fixture()
        try fixture.file("Documents/Factures/2024/facture.pdf", bytes: 30_000)
        try fixture.file("Documents/Notes/notes.txt", bytes: 2_000)
        try fixture.file("Telechargements/installeur.zip", bytes: 90_000)
        try fixture.file("Library/Caches/blob.bin", bytes: 500_000)
        let store = await ScanEngine.scan(root: fixture.path).store

        let documents = try #require(store.child(of: 0, named: "Documents"))
        let factures = try #require(store.child(of: documents, named: "Factures"))
        let year = try #require(store.child(of: factures, named: "2024"))

        // One matching file, three levels down, with unrelated siblings at every
        // level: the descent walks past all of them.
        #expect(try mask(store, ".pdf").focus(from: 0, in: store) == year)

        // But a query that also names a folder on the way down stops there: the
        // folder is a result too, and stepping into it would hide it.
        #expect(try mask(store, "facture").focus(from: 0, in: store) == documents)

        // And a query matching two branches has nowhere to descend to.
        #expect(try mask(store, "e").focus(from: 0, in: store) == 0)
    }

    @Test("Focus stops above a folder that is itself the result")
    func focusDoesNotEnterItsOwnAnswer() async throws {
        let fixture = try Fixture()
        try fixture.file("Library/Caches/big.bin", bytes: 90_000)
        let store = await ScanEngine.scan(root: fixture.path).store
        let library = try #require(store.child(of: 0, named: "Library"))

        // Stepping into Caches would show `big.bin`, and the thing searched for
        // would no longer be on screen.
        #expect(try mask(store, "Caches").focus(from: 0, in: store) == library)
    }

    @Test("A node newer than the mask is simply not kept")
    func maskIsBoundsSafe() async throws {
        let fixture = try Fixture()
        try mediaTree(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store

        // A scan snapshot grows the store under a mask built from the previous
        // one. Those nodes must read as absent rather than trap.
        let found = try mask(store, ".dmg")
        let beyond = Int32(store.count + 10)
        #expect(!found.keeps(beyond))
        #expect(!found.matches(beyond))
        #expect(found.bytes(of: beyond) == 0)
        #expect(found.resultCount(under: beyond) == 0)
        #expect(found.bytes(of: -1) == 0)
    }

    @Test("Logical and on-disk masks disagree exactly where sparse files do")
    func logicalRetainedDiffers() async throws {
        let fixture = try Fixture()
        // A hole-only file: huge logically, nearly nothing on disk. Same recipe
        // as the sparse-file engine test — extend without writing.
        let sparse = fixture.root.appendingPathComponent("sparse.dmg")
        let fd = open(sparse.path, O_CREAT | O_RDWR, 0o644)
        try #require(fd >= 0)
        let extended = ftruncate(fd, 1_000_000)
        close(fd)
        try #require(extended == 0)

        let store = await ScanEngine.scan(root: fixture.path).store
        let node = try #require(store.child(of: 0, named: "sparse.dmg"))
        #expect(try mask(store, ".dmg", useLogical: true).bytes(of: node) == 1_000_000)
        #expect(try mask(store, ".dmg", useLogical: false).bytes(of: node) < 100_000)
    }
}

@Suite("Filtered layouts")
struct FilteredLayoutTests {

    private func mediaBranches(in fixture: borrowing Fixture) throws {
        try fixture.file("Images/vacances.dmg", bytes: 300_000)
        try fixture.file("Images/photo.jpg", bytes: 400_000)
        try fixture.file("Code/build.log", bytes: 800_000)
    }

    @Test("The treemap draws only kept branches, filling the whole bounds")
    func treemapHonoursTheFilter() async throws {
        let fixture = try Fixture()
        try mediaBranches(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tiles = TreemapLayout.build(
            store: store, root: 0, in: bounds,
            useLogicalSize: true, filter: try mask(store, ".dmg")
        )

        let names = tiles.compactMap { $0.node.map { store.name(of: $0) } }
        #expect(names.contains("Images"))
        #expect(names.contains("vacances.dmg"))
        #expect(!names.contains("Code"))
        #expect(!names.contains("photo.jpg"))

        // The one surviving branch is scaled to the whole rectangle: the chart
        // answers "where are the .dmg", not "how small are they overall".
        let images = try #require(tiles.first { $0.depth == 1 })
        #expect(images.rect.width == bounds.width)
        #expect(images.rect.height == bounds.height)
    }

    @Test("The sunburst draws only kept branches, filling the whole circle")
    func sunburstHonoursTheFilter() async throws {
        let fixture = try Fixture()
        try mediaBranches(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store
        let arcs = SunburstLayout.build(
            store: store, root: 0, useLogicalSize: true,
            filter: try mask(store, ".dmg")
        )

        let names = arcs.compactMap { $0.node.map { store.name(of: $0) } }
        #expect(names.contains("Images"))
        #expect(!names.contains("Code"))

        let ringOne = arcs.filter { $0.ring == 1 }
        #expect(ringOne.count == 1)
        #expect(abs(try #require(ringOne.first).sweep - 2 * .pi) < 0.0001)
    }

    @Test("Largest files lists only what the filter keeps")
    func largestFilesHonoursTheFilter() async throws {
        let fixture = try Fixture()
        try mediaBranches(in: fixture)
        let store = await ScanEngine.scan(root: fixture.path).store
        let top = LargestFiles.top(
            in: store, under: 0, useLogical: true,
            filter: try mask(store, ".dmg")
        )
        #expect(top.map { store.name(of: $0) } == ["vacances.dmg"])
    }

    @Test("Files under a folder found by name are still listed")
    func largestFilesFollowsAMatchingFolder() async throws {
        let fixture = try Fixture()
        try fixture.file("Caches/pkg/blob.bin", bytes: 60_000)
        try fixture.file("src/main.swift", bytes: 1_000)
        let store = await ScanEngine.scan(root: fixture.path).store
        // Only the folder matches by name; its contents inherit the flag, so
        // searching for a folder still answers "what is big inside it".
        let top = LargestFiles.top(
            in: store, under: 0, useLogical: true,
            filter: try mask(store, "Caches")
        )
        #expect(top.map { store.name(of: $0) } == ["blob.bin"])
    }

    @Test("A collapsed folder that matches is one entry, as it is everywhere")
    func largestFilesKeepsCollapsedFoldersWhole() async throws {
        let fixture = try Fixture()
        try fixture.file("node_modules/pkg/index.js", bytes: 60_000)
        try fixture.file("src/main.swift", bytes: 1_000)
        let store = await ScanEngine.scan(root: fixture.path).store
        // `node_modules` is collapsed by default: its contents have no nodes, so
        // nothing inside it can ever match on its own. The folder is the answer.
        let top = LargestFiles.top(
            in: store, under: 0, useLogical: true,
            filter: try mask(store, "node_modules")
        )
        #expect(top.map { store.name(of: $0) } == ["node_modules"])
    }
}
