import Foundation

public struct TrashedItem: Sendable, Identifiable {
    public let node: Int32
    public let originalPath: String
    /// Where it landed in the Trash. Nil when the volume has no trash and the
    /// item could only be removed outright.
    public let trashPath: String?
    public let bytes: Int64

    public var id: Int32 { node }
}

public struct DeletionFailure: Sendable, Identifiable {
    public let path: String
    public let reason: String
    public var id: String { path }
}

public struct DeletionReport: Sendable {
    public var trashed: [TrashedItem] = []
    public var failures: [DeletionFailure] = []
    public var refused: [DeletionFailure] = []

    public var reclaimedBytes: Int64 { trashed.reduce(0) { $0 + $1.bytes } }
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
        public let node: Int32
        public let path: String
        public let bytes: Int64

        public init(node: Int32, path: String, bytes: Int64) {
            self.node = node
            self.path = path
            self.bytes = bytes
        }
    }

    public static func moveToTrash(_ requests: [Request]) -> DeletionReport {
        var report = DeletionReport()
        let manager = FileManager()

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
                    bytes: request.bytes
                ))
            } catch {
                report.failures.append(DeletionFailure(
                    path: request.path,
                    reason: error.localizedDescription
                ))
            }
        }
        return report
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
