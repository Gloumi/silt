import Foundation

/// Finds the biggest individual files in a subtree.
///
/// "File" here means anything that behaves like a leaf in the rest of the app:
/// regular files, of course, but also collapsed directories (`.app` bundles,
/// `node_modules`…). Those carry `.notDescended` with an aggregated size, are
/// listed with a badge, and cannot be entered — for the user they *are* one
/// big opaque item, so hiding them from a "what is eating my disk" answer
/// would be lying by omission.
public enum LargestFiles {

    /// Nodes of the `limit` largest file-like entries under `root`, sorted by
    /// descending size.
    ///
    /// A subtree is *not* a contiguous index range in `NodeStore` — the
    /// parallel scan interleaves sibling subtrees as workers finish — so this
    /// walks explicitly with a stack, the same way `JunkScanner` does. One
    /// read-only pass over contiguous arrays; fast enough to redo on every
    /// navigation step.
    ///
    /// - Parameter modifiedBefore: Unix seconds; entries touched at or after
    ///   this instant are left out. The ranking stays by size — this answers
    ///   "what is big *and* stale", not "what is oldest", which on a Mac would
    ///   return a list of tiny system files.
    public static func top(
        in store: NodeStore,
        under root: Int32,
        limit: Int = 100,
        useLogical: Bool = false,
        modifiedBefore: Int32? = nil
    ) -> [Int32] {
        guard !store.isEmpty, root >= 0, Int(root) < store.count, limit > 0 else {
            return []
        }

        let sizes = useLogical ? store.totalLogical : store.totalAlloc

        // Partial selection without a heap: collect candidates above a rising
        // threshold, and every time the buffer reaches twice the limit, sort,
        // truncate, and raise the threshold to the size of the last survivor.
        // Most of the tree is then rejected by a single integer comparison.
        var candidates: [Int32] = []
        candidates.reserveCapacity(limit * 2)
        var threshold: Int64 = 0

        func compact() {
            candidates.sort { sizes[Int($0)] > sizes[Int($1)] }
            if candidates.count > limit {
                candidates.removeLast(candidates.count - limit)
            }
        }

        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            let index = Int(node)
            let flags = store.flags[index]

            // `markDeleted` marks only the node itself, never its descendants,
            // so a deleted directory must also stop the walk — descending would
            // resurrect files that just went to the Trash.
            if flags.contains(.deleted) { continue }

            let isDirectory = flags.contains(.directory)

            // The subtree we were asked about is never itself the answer.
            // Hardlink duplicates are recorded with size 0, and the size guard
            // also drops empty files and mount points (aggregated as empty).
            // Only ever a test on the candidate, never on the walk: a folder
            // whose aggregated date is recent almost certainly holds old files,
            // and pruning there would hide exactly what we are looking for.
            let staleEnough = modifiedBefore.map { store.modTime[index] < $0 } ?? true

            if node != root, staleEnough,
               !isDirectory || flags.contains(.notDescended),
               !flags.contains(.hardlinkDuplicate) {
                let size = sizes[index]
                if size > threshold {
                    candidates.append(node)
                    if candidates.count >= limit * 2 {
                        compact()
                        threshold = sizes[Int(candidates[candidates.count - 1])]
                    }
                }
            }

            if isDirectory {
                for child in store.children(of: node) { stack.append(child) }
            }
        }

        compact()
        return candidates
    }
}
