import Darwin
import Foundation

/// What could be established about one item still being in the trash.
///
/// Three cases, not two, because the trash is TCC-protected and "I am not
/// allowed to look" must never be read as "it is gone".
public enum TrashPresence: Sendable, Equatable {
    case present
    case absent
    case unknown
}

/// One thing this app moved to the trash and can still put back.
///
/// Deliberately not a `TrashedItem`: that carries a node index, and a node
/// index only means something inside the scan that produced it. A record meant
/// to outlive the scan — and the launch — can be nothing but paths.
public struct TrashLedgerEntry: Codable, Sendable, Identifiable {
    public let originalPath: String
    public let trashPath: String
    public let bytes: Int64
    public let trashedAt: Date
    /// Carried over from `TrashedItem.viaFinder`: these are the ones whose
    /// Finder "Remettre" is most likely to be missing, so they are the ones
    /// this ledger exists for.
    public let viaFinder: Bool

    /// The trash path, not the original: emptying and re-trashing the same
    /// file would otherwise collide, and the trash path is what is unique.
    public var id: String { trashPath }

    public var name: String { (originalPath as NSString).lastPathComponent }
    /// Where it will land again, for a list that has to say more than a name.
    public var originalFolder: String {
        (originalPath as NSString).deletingLastPathComponent
    }

    /// The form `SafeDeleter.restore` takes. No node: whatever tree this came
    /// from is long gone, and the file moves back on disk just the same.
    public var item: TrashedItem {
        TrashedItem(
            node: nil,
            originalPath: originalPath,
            trashPath: trashPath,
            bytes: bytes,
            viaFinder: viaFinder
        )
    }
}

/// What this app has trashed, kept on disk so that it stays restorable.
///
/// The in-app undo used to live and die with the banner: dismiss it, or quit,
/// and the only way back was the Finder's own "Remettre" — which is exactly
/// what comes back greyed out on the deletions most likely to need undoing.
/// This ledger is the durable half of the promise the banner makes.
public enum TrashLedger {

    /// Bounded so a year of tidying cannot grow the file without limit. Oldest
    /// records fall off first; they are also the ones most likely to have been
    /// emptied out from under us already.
    public static let capacity = 500

    // MARK: - Pure

    /// Adds what was just trashed, newest first.
    ///
    /// Items removed outright are dropped: with no trash path there is nothing
    /// to put back, and listing them would promise a restore that cannot happen.
    public static func record(
        _ items: [TrashedItem],
        at date: Date,
        into entries: [TrashLedgerEntry]
    ) -> [TrashLedgerEntry] {
        let added: [TrashLedgerEntry] = items.compactMap { item in
            guard let trashPath = item.trashPath else { return nil }
            return TrashLedgerEntry(
                originalPath: item.originalPath,
                trashPath: trashPath,
                bytes: item.bytes,
                trashedAt: date,
                viaFinder: item.viaFinder
            )
        }
        guard !added.isEmpty else { return entries }
        let fresh = Set(added.map(\.trashPath))
        let kept = entries.filter { !fresh.contains($0.trashPath) }
        return Array((added + kept).prefix(capacity))
    }

    /// Drops the given trash paths — what has gone back where it came from.
    ///
    /// Takes paths rather than entries so that both callers can use it: the
    /// banner's undo holds `TrashedItem`s, the tool holds ledger entries, and
    /// the trash path is the one thing they agree on.
    public static func forget(
        trashPaths: some Sequence<String>,
        from entries: [TrashLedgerEntry]
    ) -> [TrashLedgerEntry] {
        let gone = Set(trashPaths)
        return entries.filter { !gone.contains($0.trashPath) }
    }

    /// Whether one item is still in the trash.
    ///
    /// `lstat` on the item, deliberately, rather than listing its folder. The
    /// two are not equivalent under TCC: reading `~/.Trash` needs Full Disk
    /// Access and is refused without it, while stat-ing a path *inside* it is
    /// allowed and answers ENOENT for something genuinely gone. Asking the
    /// narrower question is what lets an app with no special privilege still
    /// tell "emptied" from "not allowed to look" — and `FileManager`'s
    /// `fileExists` cannot, since it collapses both into false.
    ///
    /// No `stat`: a symlink left in the trash is still an item to put back,
    /// and following it to a missing target would report it gone.
    public static func presence(of path: String) -> TrashPresence {
        var info = stat()
        guard lstat(path, &info) != 0 else { return .present }
        return errno == ENOENT || errno == ENOTDIR ? .absent : .unknown
    }

    /// Those entries still in the trash, as far as can be established.
    ///
    /// Only what is known to be gone is retired. An entry we were not allowed
    /// to look at stays: erasing the one record that makes an item restorable,
    /// on the strength of a permission error, would lose it exactly when it is
    /// needed. The probe is injectable so that this case can be tested without
    /// a machine-specific unreadable path.
    public static func survivors(
        of entries: [TrashLedgerEntry],
        probe: (String) -> TrashPresence = presence(of:)
    ) -> [TrashLedgerEntry] {
        entries.filter { probe($0.trashPath) != .absent }
    }

    // MARK: - Storage

    /// `~/Library/Application Support/Silt/trashed.json`, or nil if that cannot
    /// be created — in which case the ledger degrades to the in-memory undo
    /// rather than failing anything.
    private static var storeURL: URL? {
        let manager = FileManager.default
        guard let support = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let folder = support.appendingPathComponent("Silt", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("trashed.json")
    }

    public static func load() -> [TrashLedgerEntry] {
        guard let url = storeURL, let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([TrashLedgerEntry].self, from: data)) ?? []
    }

    public static func save(_ entries: [TrashLedgerEntry]) {
        guard let url = storeURL,
              let data = try? JSONEncoder().encode(entries)
        else { return }
        // Atomic: a half-written ledger is worse than a stale one, since it is
        // the only record of what can still be put back.
        try? data.write(to: url, options: .atomic)
    }
}
