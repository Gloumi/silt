import Foundation
import Testing

@testable import DiskCore

@Suite("Trash ledger")
struct TrashLedgerTests {

    private func trashed(
        _ original: String, at trashPath: String?, bytes: Int64 = 100,
        viaFinder: Bool = false
    ) -> TrashedItem {
        TrashedItem(
            node: nil, originalPath: original, trashPath: trashPath,
            bytes: bytes, viaFinder: viaFinder
        )
    }

    private func entry(
        _ original: String, at trashPath: String, when: Date = Date()
    ) -> TrashLedgerEntry {
        TrashLedgerEntry(
            originalPath: original, trashPath: trashPath, bytes: 100,
            trashedAt: when, viaFinder: false
        )
    }

    @Test("Newly trashed items land at the top, keeping what came before")
    func recordsNewestFirst() {
        let existing = [entry("/a/old", at: "/T/old")]
        let ledger = TrashLedger.record(
            [trashed("/a/new", at: "/T/new")], at: Date(), into: existing
        )
        #expect(ledger.map(\.name) == ["new", "old"])
    }

    /// Nothing to put back means nothing to promise. An item removed outright —
    /// a volume with no trash — must not appear in a list headed "restaurable".
    @Test("An item deleted outright is not recorded")
    func skipsItemsWithNoTrashPath() {
        let ledger = TrashLedger.record(
            [trashed("/a/gone", at: nil)], at: Date(), into: []
        )
        #expect(ledger.isEmpty)
    }

    @Test("Re-trashing the same path replaces the earlier record")
    func deduplicatesByTrashPath() {
        let first = TrashLedger.record(
            [trashed("/a/x", at: "/T/x", bytes: 10)], at: Date(), into: []
        )
        let second = TrashLedger.record(
            [trashed("/a/x", at: "/T/x", bytes: 99)], at: Date(), into: first
        )
        #expect(second.count == 1)
        #expect(second.first?.bytes == 99)
    }

    @Test("The ledger is bounded, dropping the oldest first")
    func boundedByCapacity() {
        let old = (0..<TrashLedger.capacity).map {
            entry("/a/old\($0)", at: "/T/old\($0)")
        }
        let ledger = TrashLedger.record(
            [trashed("/a/new", at: "/T/new")], at: Date(), into: old
        )
        #expect(ledger.count == TrashLedger.capacity)
        #expect(ledger.first?.name == "new")
        #expect(!ledger.contains { $0.name == "old\(TrashLedger.capacity - 1)" })
    }

    @Test("Restored items leave the ledger, failures stay")
    func forgetsOnlyWhatWasGiven() {
        let ledger = [entry("/a/x", at: "/T/x"), entry("/a/y", at: "/T/y")]
        let kept = TrashLedger.forget(trashPaths: ["/T/x"], from: ledger)
        #expect(kept.map(\.name) == ["y"])
    }

    @Test("What has left the trash is retired, what remains is kept")
    func survivorsReflectTheTrashFolder() throws {
        let fixture = try Fixture()
        try fixture.file("still-there.bin", bytes: 10)

        let ledger = [
            entry("/a/still-there.bin", at: fixture.path + "/still-there.bin"),
            entry("/a/emptied.bin", at: fixture.path + "/emptied.bin"),
        ]
        #expect(TrashLedger.survivors(of: ledger).map(\.name) == ["still-there.bin"])
    }

    /// The one that matters most. `~/.Trash` is unreadable without Full Disk
    /// Access, and a prune that read that as "everything is gone" would wipe the
    /// only record of what can still be put back — in the exact case where the
    /// user needs it. An unlistable folder must retire nothing.
    @Test("A trash folder that cannot be listed retires nothing")
    func unreadableTrashKeepsEverything() {
        let ledger = [
            entry("/a/x", at: "/nowhere-at-all/x"),
            entry("/a/y", at: "/nowhere-at-all/y"),
        ]
        #expect(TrashLedger.survivors(of: ledger).count == 2)
    }

    /// Volumes keep their own trash, so one unreadable folder must not blind
    /// the ledger to a readable one — nor the other way round.
    @Test("Each trash folder is judged on its own")
    func foldersAreIndependent() throws {
        let fixture = try Fixture()
        try fixture.file("kept.bin", bytes: 10)

        let ledger = [
            entry("/a/kept.bin", at: fixture.path + "/kept.bin"),
            entry("/a/emptied.bin", at: fixture.path + "/emptied.bin"),
            entry("/b/unknown.bin", at: "/nowhere-at-all/unknown.bin"),
        ]
        #expect(
            Set(TrashLedger.survivors(of: ledger).map(\.name))
                == ["kept.bin", "unknown.bin"]
        )
    }

    @Test("An entry restores as a node-less trashed item")
    func convertsToRestorableItem() {
        let item = entry("/a/x", at: "/T/x").item
        #expect(item.node == nil)
        #expect(item.originalPath == "/a/x")
        #expect(item.trashPath == "/T/x")
    }
}
