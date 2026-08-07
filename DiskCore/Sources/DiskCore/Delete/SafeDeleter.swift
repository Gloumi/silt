import Foundation

public struct TrashedItem: Sendable, Identifiable {
    /// Node it came from, or nil when the item was never part of the tree —
    /// an application's leftovers live all over `~/Library` and are found by
    /// name, not by having been scanned.
    public let node: Int32?
    public let originalPath: String
    /// Where it landed in the Trash. Nil when the volume has no trash and the
    /// item could only be removed outright.
    public let trashPath: String?
    public let bytes: Int64
    /// True when a plain rename was refused and the Finder had to be asked
    /// instead. Worth telling the user about: on that route the Finder's own
    /// "Remettre" can come back greyed out, which leaves the in-app undo — good
    /// only until the banner is dismissed — as the one way back.
    public let viaFinder: Bool

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

    public init(path: String, reason: String, isPermissionDenied: Bool = false) {
        self.path = path
        self.reason = reason
        self.isPermissionDenied = isPermissionDenied
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
    public var isEmpty: Bool {
        trashed.isEmpty && failures.isEmpty && refused.isEmpty
    }
}

/// Moves things to the Trash, and can put them back.
///
/// Nothing here ever calls `unlink`. Going through the Trash means every
/// deletion this app performs is reversible by the user in the Finder even
/// after the app is gone, which is the whole safety story — the in-app undo
/// below is a convenience on top of that, not the guarantee.
public enum SafeDeleter {

    public struct Request: Sendable {
        /// Nil for a path that is not part of any scanned tree. `moveToTrash`
        /// never reads it — it works entirely off `path` — but the caller needs
        /// it back to update the tree it does own.
        public let node: Int32?
        public let path: String
        public let bytes: Int64

        public init(node: Int32?, path: String, bytes: Int64) {
            self.node = node
            self.path = path
            self.bytes = bytes
        }
    }

    public static func moveToTrash(_ requests: [Request]) -> DeletionReport {
        var report = DeletionReport()
        let manager = FileManager()
        /// Denied by the filesystem, kept aside for one Finder attempt at the
        /// end — batched so the administrator dialog shows once, not per item.
        var denied: [Request] = []

        for request in requests {
            // Re-checked here rather than trusted from the caller: this is the
            // last gate before the filesystem, and it must not be bypassable by
            // a UI bug.
            let verdict = DenyList.verdict(for: request.path)
            if verdict.isForbidden {
                report.refused.append(DeletionFailure(
                    path: request.path,
                    reason: verdict.message ?? "Élément protégé."
                ))
                continue
            }

            var resulting: NSURL?
            do {
                try manager.trashItem(
                    at: URL(fileURLWithPath: request.path),
                    resultingItemURL: &resulting
                )
                report.trashed.append(TrashedItem(
                    node: request.node,
                    originalPath: request.path,
                    trashPath: (resulting as URL?)?.path,
                    bytes: request.bytes,
                    viaFinder: false
                ))
            } catch {
                let permission = isPermissionError(error)
                if permission { denied.append(request) }
                report.failures.append(DeletionFailure(
                    path: request.path,
                    reason: error.localizedDescription,
                    isPermissionDenied: permission
                ))
            }
        }

        // What we cannot rename, the Finder often can: it authenticates as an
        // administrator for items owned by another account, and macOS lets it
        // touch application bundles. Failures it resolves become successes.
        if !denied.isEmpty {
            let landed = FinderTrash.delete(denied.map(\.path))
            for (request, trashPath) in zip(denied, landed) {
                guard let trashPath else { continue }
                report.failures.removeAll { $0.path == request.path }
                report.trashed.append(TrashedItem(
                    node: request.node,
                    originalPath: request.path,
                    trashPath: trashPath,
                    bytes: request.bytes,
                    viaFinder: true
                ))
            }
        }
        return report
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
