import Foundation

/// Structural fingerprint of every folder in a scanned tree, and the candidate
/// buckets it yields — all of it from the arrays the scan already filled, with
/// no disk access at all.
///
/// Two folders can only hold the same bytes if they hold the same shape: the
/// same names, nested the same way, with the same sizes at the leaves. That is
/// free to check and eliminates almost everything, which is what makes reading
/// the disk afterwards affordable. It is *only* a filter — a bucket here is a
/// question, and `FolderManifest` plus the hasher answer it.
///
/// Hence 64 bits from the standard `Hasher` rather than SHA-256: a collision
/// costs one wasted verification, never a wrong answer. Nothing is ever
/// proposed for deletion on the strength of a signature.
public enum FolderSignature {

    /// A node's fingerprint, and whether its subtree is fit to be compared at
    /// all. The two travel together because both are computed by the same
    /// reverse pass.
    public struct Table: Sendable {
        public var signature: [UInt64]
        /// True when the subtree holds something that makes its fingerprint a
        /// lie, or its contents unsafe to walk. See `disqualifies`.
        public var disqualified: [Bool]
    }

    /// Flags that poison a whole subtree for comparison.
    ///
    /// `.hardlinkDuplicate` because the scan zeroes the sizes of the *second*
    /// path it reaches for an inode, and which one that is depends on the order
    /// the workers happened to run in. A `cp -al` backup would therefore
    /// fingerprint differently from one run to the next — and deleting a copy
    /// of it frees almost nothing anyway, so there is nothing to lose.
    ///
    /// `.mountPoint` and `.firmlink` because the scan stops at them and records
    /// the stub: two different volumes mounted under identically named folders
    /// look identical from here. Worse, the live walk would then wander onto a
    /// network share — gigabytes read over a link that cannot be cancelled
    /// mid-syscall, ending in a Trash that fails.
    ///
    /// `.unreadable` because the subtree below is missing from the totals: the
    /// fingerprint describes what we managed to see, not what is there.
    ///
    /// `.deleted` because a folder half in the Trash is not a folder any more.
    ///
    /// `.dataless` because the bytes are not here. Comparing a folder holding
    /// one would mean downloading it — filling the disk the user asked us to
    /// empty — and the copy weighs nothing anyway, so deleting it frees
    /// nothing. Same reasoning as `.hardlinkDuplicate`, same conclusion.
    public static let disqualifying: NodeFlags = [
        .hardlinkDuplicate, .mountPoint, .firmlink, .unreadable, .deleted,
        .dataless,
    ]

    // MARK: - F0

    /// One reverse pass over the store, the same shape as `NodeStore.rollUp`.
    ///
    /// Invariant 1 (a child's index is greater than its parent's) means that
    /// walking backwards visits every child before its parent, so a directory's
    /// entries are all fingerprinted by the time it is reached. Disqualification
    /// rides the same pass in the other direction: a child poisons its parent.
    public static func table(of store: NodeStore) -> Table {
        let count = store.count
        var signature = [UInt64](repeating: 0, count: count)
        var disqualified = [Bool](repeating: false, count: count)
        guard count > 0 else {
            return Table(signature: signature, disqualified: disqualified)
        }

        // Reused across directories so a million-node tree does not allocate a
        // million times. Entries are sorted here because the store keeps
        // children in raw `getattrlistbulk` order, which is the filesystem's
        // business and varies between two copies of the same folder.
        var entries: [UInt64] = []

        var index = count - 1
        while index >= 0 {
            defer { index -= 1 }
            let node = Int32(index)
            let flags = store.flags[index]

            if !flags.isDisjoint(with: disqualifying) { disqualified[index] = true }

            if flags.contains(.directory), !flags.contains(.notDescended) {
                entries.removeAll(keepingCapacity: true)
                for child in store.children(of: node) {
                    if disqualified[Int(child)] { disqualified[index] = true }
                    entries.append(entry(of: child, in: store, signature: signature))
                }
                entries.sort()
                signature[index] = fold(entries, kind: Kind.folder)
            } else {
                signature[index] = aggregate(node, in: store, kind: kind(of: flags))
            }
        }
        return Table(signature: signature, disqualified: disqualified)
    }

    /// One entry as its parent sees it: its name and its fingerprint, welded
    /// together so a rename cannot pass for a content change and vice versa.
    ///
    /// The node's *own* name is deliberately not part of `signature[node]` —
    /// only of the entry its parent records. Otherwise "Photos" and "Photos
    /// copie" could never match, which is precisely the case the whole feature
    /// exists for.
    private static func entry(
        of node: Int32, in store: NodeStore, signature: [UInt64]
    ) -> UInt64 {
        let name = store.nameBytes(of: node)
        var hasher = Hasher()
        // Length first, so no name can borrow the bytes of the field after it.
        hasher.combine(name.count)
        name.withUnsafeBytes { hasher.combine(bytes: $0) }
        hasher.combine(signature[Int(node)])
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// What a node is, folded in so a file can never share a fingerprint with
    /// a folder or a symlink of the same size.
    private enum Kind {
        static let file: UInt8 = 1
        static let symlink: UInt8 = 2
        static let folder: UInt8 = 3
        static let collapsedFolder: UInt8 = 4
    }

    private static func kind(of flags: NodeFlags) -> UInt8 {
        if flags.contains(.directory) { return Kind.collapsedFolder }
        return flags.contains(.symlink) ? Kind.symlink : Kind.file
    }

    private static func fold(_ entries: [UInt64], kind: UInt8) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(entries.count)
        for entry in entries { hasher.combine(entry) }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Anything with no entries of its own in the store: a file, a symlink, or
    /// a directory the scan stopped at.
    ///
    /// A collapsed directory — `node_modules`, a `.app` bundle — got no child
    /// nodes but does carry its subtree's totals, so the aggregate stands in
    /// for the shape that was never recorded. Coarse on purpose: being wrong
    /// costs one verification, and it is what makes folded folders comparable
    /// at all, which the tree on its own could never do.
    private static func aggregate(
        _ node: Int32, in store: NodeStore, kind: UInt8
    ) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(store.totalLogical[Int(node)])
        hasher.combine(store.fileCount[Int(node)])
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    // MARK: - F1

    /// Folders under `root` that share a fingerprint with at least one other,
    /// as buckets of node indices.
    ///
    /// Nested candidates are kept: `A/` and `A/sub` both come out when both are
    /// duplicated. Collapsing that to the topmost is the display's job, not the
    /// engine's — once the user resolves `A`, the duplication *inside* what
    /// survives is still real, and an engine that had dropped it would have to
    /// re-read the disk to find it again.
    ///
    /// Returns nil if the surrounding task was cancelled.
    public static func candidates(
        in store: NodeStore, under root: Int32, minimumSize: Int64
    ) -> [[Int32]]? {
        guard !store.isEmpty, root >= 0, Int(root) < store.count else { return [] }
        let table = table(of: store)

        var buckets: [UInt64: [Int32]] = [:]
        var stack: [Int32] = [root]
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            if visited & 0x3FF == 0, Task.isCancelled { return nil }
            let index = Int(node)
            let flags = store.flags[index]
            guard flags.contains(.directory) else { continue }
            // Nothing below a trashed folder exists any more, so the walk stops
            // rather than merely skipping the node.
            if flags.contains(.deleted) { continue }
            for child in store.children(of: node) { stack.append(child) }

            // Never the folder we are standing in, and never the scan root:
            // deleting the ground under the breadcrumb leaves the view
            // describing a place that is gone.
            guard node != root, node != 0 else { continue }
            guard !table.disqualified[index] else { continue }
            guard store.totalAlloc[index] >= minimumSize else { continue }
            // An empty folder pair is a true duplicate and a useless one; two
            // of them would also confirm instantly and free nothing.
            guard store.fileCount[index] > 0 else { continue }
            buckets[table.signature[index], default: []].append(node)
        }

        return buckets.values.filter { $0.count >= 2 }.map { $0.sorted() }
    }
}
