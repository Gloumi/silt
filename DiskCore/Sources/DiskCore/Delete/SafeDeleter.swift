import Foundation

public struct TrashedItem: Sendable, Identifiable {
    /// Node it came from, or nil when the item was never part of the tree —
    /// an application's leftovers live all over `~/Library` and are found by
    /// name, not by having been scanned.
    public let node: Int32?
    public let originalPath: String
    /// Where it landed in the Trash. Nil when the volume has no working trash
    /// and the item could only be removed outright — see `removeOutright`,
    /// which is the one thing in this app that produces such an item.
    public let trashPath: String?
    public let bytes: Int64
    /// True when a plain rename was refused and the Finder had to be asked
    /// instead. Worth telling the user about: on that route the Finder's own
    /// "Remettre" can come back greyed out, which leaves the in-app undo — good
    /// only until the banner is dismissed — as the one way back.
    public let viaFinder: Bool

    public init(
        node: Int32?, originalPath: String, trashPath: String?,
        bytes: Int64, viaFinder: Bool
    ) {
        self.node = node
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.bytes = bytes
        self.viaFinder = viaFinder
    }

    /// The path, not the node: a path is unique whether or not the item was in
    /// the tree, and two out-of-tree items would otherwise share an identity.
    public var id: String { originalPath }
}

public struct DeletionFailure: Sendable, Identifiable {
    public let path: String
    public let reason: String
    /// The filesystem said no — as opposed to the deny list, a vanished file,
    /// or an occupied restore target. The caller can turn this into permission
    /// guidance where a bare reason string could not be told apart.
    public let isPermissionDenied: Bool
    /// The trash claimed the item and left it exactly where it was. Told apart
    /// from an ordinary failure because the cure is different: nothing is wrong
    /// with the item, the volume simply has no trash that works.
    public let isTrashUnusable: Bool

    public init(
        path: String, reason: String,
        isPermissionDenied: Bool = false, isTrashUnusable: Bool = false
    ) {
        self.path = path
        self.reason = reason
        self.isPermissionDenied = isPermissionDenied
        self.isTrashUnusable = isTrashUnusable
    }

    public var id: String { path }
}

public struct DeletionReport: Sendable {
    public var trashed: [TrashedItem] = []
    public var failures: [DeletionFailure] = []
    public var refused: [DeletionFailure] = []

    public var reclaimedBytes: Int64 { trashed.reduce(0) { $0 + $1.bytes } }
    /// Those the Finder had to trash on our behalf — see `TrashedItem.viaFinder`.
    public var finderAssisted: [TrashedItem] { trashed.filter(\.viaFinder) }
    /// Those that can still be put back: everything that reached a trash.
    public var restorable: [TrashedItem] { trashed.filter { $0.trashPath != nil } }
    /// Those that are gone — the volume had no trash, and the user agreed.
    public var erased: [TrashedItem] { trashed.filter { $0.trashPath == nil } }
    /// Freed this instant, as opposed to freed by emptying the trash.
    public var reclaimedNowBytes: Int64 { erased.reduce(0) { $0 + $1.bytes } }
    public var reclaimedOnEmptyingBytes: Int64 {
        restorable.reduce(0) { $0 + $1.bytes }
    }
    /// Items a trash pretended to take. Not the user's problem to fix item by
    /// item: their volume's trash does not work.
    public var strandedByTrash: [DeletionFailure] {
        failures.filter(\.isTrashUnusable)
    }
    public var isEmpty: Bool {
        trashed.isEmpty && failures.isEmpty && refused.isEmpty
    }
}

/// Moves things to the Trash, and can put them back.
///
/// The Trash is the rule and the guarantee: a deletion that goes through it is
/// reversible by the user in the Finder even after this app is gone, and the
/// in-app undo is a convenience on top of that, not the promise.
///
/// Removing outright is the exception, and it is deliberately hard to reach.
/// It happens only for a request whose `permanent` flag a caller set, which
/// `VolumeTrashProbe` only ever justifies by *watching* a volume's trash fail
/// to move a file, and which the interface only ever acts on after a second,
/// explicit confirmation. Nothing in this file decides it.
public enum SafeDeleter {

    public struct Request: Sendable {
        /// Nil for a path that is not part of any scanned tree. `delete`
        /// never reads it — it works entirely off `path` — but the caller needs
        /// it back to update the tree it does own.
        public let node: Int32?
        public let path: String
        public let bytes: Int64
        /// Removed outright rather than trashed, because this volume's trash
        /// was probed and found not to move anything. Per request rather than
        /// per batch: a selection routinely spans two volumes, and splitting
        /// the call would cost the single Finder pass below.
        public let permanent: Bool

        public init(
            node: Int32?, path: String, bytes: Int64, permanent: Bool = false
        ) {
            self.node = node
            self.path = path
            self.bytes = bytes
            self.permanent = permanent
        }
    }

    /// Trashes — or, where the caller has established it must, removes — each
    /// request, and says what became of every one of them.
    ///
    /// `presence` is injectable for the same reason `TrashLedger.survivors` has
    /// a probe: the interesting case is a trash that lies, and no fixture can
    /// produce one.
    public static func delete(
        _ requests: [Request],
        presence: (String) -> TrashPresence = TrashLedger.presence(of:)
    ) -> DeletionReport {
        var report = DeletionReport()
        /// Denied by the filesystem, kept aside for one Finder attempt at the
        /// end — batched so the administrator dialog shows once, not per item.
        var denied: [Request] = []

        for request in requests {
            // Re-checked here rather than trusted from the caller: this is the
            // last gate before the filesystem, and it must not be bypassable by
            // a UI bug. Ahead of `permanent` on purpose — a protected path is
            // protected all the more when the deletion cannot be undone.
            let verdict = DenyList.verdict(for: request.path)
            if verdict.isForbidden {
                report.refused.append(DeletionFailure(
                    path: request.path,
                    reason: verdict.message ?? "Élément protégé."
                ))
                continue
            }

            if request.permanent {
                removeOutright(request, into: &report)
            } else {
                trash(request, presence: presence, into: &report, denied: &denied)
            }
        }

        // What we cannot rename, the Finder often can: it authenticates as an
        // administrator for items owned by another account, and macOS lets it
        // touch application bundles. Failures it resolves become successes.
        if !denied.isEmpty {
            finderFallback(denied, presence: presence, into: &report)
        }
        return report
    }

    // MARK: - The two routes

    private static func trash(
        _ request: Request,
        presence: (String) -> TrashPresence,
        into report: inout DeletionReport,
        denied: inout [Request]
    ) {
        var resulting: NSURL?
        do {
            try FileManager().trashItem(
                at: URL(fileURLWithPath: request.path),
                resultingItemURL: &resulting
            )
        } catch {
            let permission = isPermissionError(error)
            if permission { denied.append(request) }
            report.failures.append(DeletionFailure(
                path: request.path,
                reason: error.localizedDescription,
                isPermissionDenied: permission
            ))
            return
        }
        record(
            request, landedAt: (resulting as URL?)?.path, viaFinder: false,
            presence: presence, into: &report
        )
    }

    /// Removes an item for good, on a volume whose trash was probed and found
    /// wanting.
    ///
    /// No Finder fallback and no elevation here, deliberately. `FinderTrash`
    /// turns "impossible" into "asks for a password" because what waits on the
    /// other side is reversible; `rm -rf` as root is not, and a permission
    /// error on this route stays a reported failure the user can act on.
    private static func removeOutright(
        _ request: Request, into report: inout DeletionReport
    ) {
        do {
            try FileManager().removeItem(atPath: request.path)
            report.trashed.append(TrashedItem(
                node: request.node,
                originalPath: request.path,
                trashPath: nil,
                bytes: request.bytes,
                viaFinder: false
            ))
        } catch {
            report.failures.append(DeletionFailure(
                path: request.path,
                reason: error.localizedDescription,
                isPermissionDenied: isPermissionError(error)
            ))
        }
    }

    /// The Finder's turn at everything a rename refused.
    ///
    /// Its successes are checked exactly as our own are: asked to delete on a
    /// volume whose trash does not move things, the Finder copies just the same.
    private static func finderFallback(
        _ denied: [Request],
        presence: (String) -> TrashPresence,
        into report: inout DeletionReport
    ) {
        let landed = FinderTrash.delete(denied.map(\.path))
        for (request, trashPath) in zip(denied, landed) {
            guard let trashPath else { continue }
            // Dropped first, then re-decided: an item the Finder only copied
            // goes back into the failures, but under the reason that actually
            // applies, not the permission error that sent it here.
            report.failures.removeAll { $0.path == request.path }
            record(
                request, landedAt: trashPath, viaFinder: true,
                presence: presence, into: &report
            )
        }
    }

    // MARK: - Trusting nothing

    /// Books one nominally successful trashing, once the original has been
    /// asked whether it really left.
    ///
    /// `trashItem` — and the Finder — report success on a volume where all they
    /// did was make a copy: the item shows up in a trash and stays where it
    /// was, and nothing is freed. Believing them is how deleting on an external
    /// disk came to do nothing at all, while filling the startup disk with the
    /// copies. The original is the only witness worth asking.
    ///
    /// `lstat`, through the ledger's probe, rather than `fileExists`: its third
    /// answer matters. "Not allowed to look" counts as success — the item may
    /// well be gone, and destroying a trash copy on the strength of a
    /// permission error would throw away the last instance of it.
    private static func record(
        _ request: Request,
        landedAt trashPath: String?,
        viaFinder: Bool,
        presence: (String) -> TrashPresence,
        into report: inout DeletionReport
    ) {
        guard presence(request.path) == .present else {
            report.trashed.append(TrashedItem(
                node: request.node,
                originalPath: request.path,
                trashPath: trashPath,
                bytes: request.bytes,
                viaFinder: viaFinder
            ))
            return
        }
        let discarded = trashPath.map(discardStrayCopy(at:)) ?? false
        report.failures.append(DeletionFailure(
            path: request.path,
            reason: discarded
                ? "La corbeille de ce volume n'a rien déplacé : l'élément est resté en place."
                : "La corbeille de ce volume n'a rien déplacé : l'élément est resté en place, et une copie subsiste dans la corbeille.",
            isTrashUnusable: true
        ))
    }

    /// Removes the copy a trash left behind when it did not move anything.
    ///
    /// Guarded on the path really being inside a trash folder: this is the one
    /// place in the app that deletes something the user never named, and a
    /// `resultingItemURL` we misread must not be able to point anywhere else.
    static func discardStrayCopy(at path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.contains(".Trash") || components.contains(".Trashes")
        else { return false }
        return (try? FileManager().removeItem(atPath: path)) != nil
    }

    /// Whether the filesystem refused out of permissions, wherever the POSIX
    /// error ended up — Foundation sometimes wraps it, sometimes not.
    private static func isPermissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let inspected = current {
            if inspected.domain == NSCocoaErrorDomain,
               inspected.code == CocoaError.fileWriteNoPermission.rawValue {
                return true
            }
            if inspected.domain == NSPOSIXErrorDomain,
               inspected.code == Int(EPERM) || inspected.code == Int(EACCES) {
                return true
            }
            current = inspected.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Puts trashed items back where they came from.
    ///
    /// Only moves a file back if nothing has appeared at the original path in
    /// the meantime — restoring must never overwrite.
    @discardableResult
    public static func restore(_ items: [TrashedItem]) -> [DeletionFailure] {
        let manager = FileManager()
        var failures: [DeletionFailure] = []

        for item in items {
            guard let trashPath = item.trashPath else {
                failures.append(DeletionFailure(
                    path: item.originalPath,
                    reason: "Élément supprimé sans passer par la corbeille."
                ))
                continue
            }
            guard !manager.fileExists(atPath: item.originalPath) else {
                failures.append(DeletionFailure(
                    path: item.originalPath,
                    reason: "Un élément occupe déjà cet emplacement."
                ))
                continue
            }
            do {
                try manager.moveItem(
                    atPath: trashPath, toPath: item.originalPath
                )
            } catch {
                failures.append(DeletionFailure(
                    path: item.originalPath,
                    reason: error.localizedDescription
                ))
            }
        }
        return failures
    }
}
