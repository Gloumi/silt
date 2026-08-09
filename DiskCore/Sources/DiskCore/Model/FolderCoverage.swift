import Foundation

/// The two rules that decide what a confirmed folder duplicate hides.
///
/// Pure reasoning over the tree, and here rather than in the view model
/// precisely because both rules are one sentence long and very easy to get
/// subtly wrong — and being wrong means either proposing the same folder twice
/// or erasing a file duplicate the user could still have acted on.
public enum FolderCoverage {

    public struct Plan: Sendable {
        /// Indices, into the groups handed in, of the ones worth showing.
        public var visible: [Int]
        /// Folder copies whose descendants leave the file list: they are going
        /// to the Trash with their folder anyway.
        public var absorbing: Set<Int32>
    }

    /// True when one of `node`'s ancestors is in `set`.
    public static func hasAncestor(
        of node: Int32, in set: Set<Int32>, store: NodeStore
    ) -> Bool {
        guard !set.isEmpty else { return false }
        var current = node
        while true {
            let next = store.parent[Int(current)]
            if next == current { return false } // root points at itself
            if set.contains(next) { return true }
            current = next
        }
    }

    /// Which folder groups to show, and which folder copies swallow the files
    /// beneath them.
    ///
    /// - Parameters:
    ///   - groups: the copies of each confirmed group.
    ///   - isManaged: whether a copy sits in storage an app or a tool owns.
    ///     Only ever a tie-break for the canonical copy — never a reason to
    ///     hide anything, which is the caller's decision to make first.
    ///   - absorbs: whether this copy may swallow the files under it. The
    ///     caller says no while a search is narrowing the list to something
    ///     *inside* the folder: `keeps` is true for a folder that merely holds
    ///     a result, so a search for a file name would surface the folder
    ///     group and have it eat the very files being looked for.
    public static func plan(
        for groups: [[Int32]],
        in store: NodeStore,
        isManaged: (Int32) -> Bool = { _ in false },
        absorbs: (Int32) -> Bool = { _ in true }
    ) -> Plan {
        // Sorted by depth rather than by size. An outer group is always worth
        // at least as much as the one nested inside it, so bytes would usually
        // agree — but the two can tie exactly, and a tie would then decide
        // which of them survives.
        let order = groups.indices.sorted {
            (groups[$0].map(store.depth(of:)).min() ?? 0,
             groups[$0].min() ?? 0)
                < (groups[$1].map(store.depth(of:)).min() ?? 0,
                   groups[$1].min() ?? 0)
        }

        var shown: Set<Int32> = []
        var visible: [Int] = []
        for index in order {
            let folders = groups[index]
            guard !folders.isEmpty else { continue }
            // Hidden only when *every* copy is already covered. With
            // `{A/sub, C/sub}` where only A is part of a shown group, C/sub is
            // somewhere else entirely and the pair is still worth resolving.
            guard !folders.allSatisfy({
                hasAncestor(of: $0, in: shown, store: store)
            }) else { continue }
            shown.formUnion(folders)
            visible.append(index)
        }

        // Each visible group designates one copy to survive, and only the
        // *others* absorb. With `{A/x, B/x, C/x}` and `A ≡ B`, hiding
        // everything under any flagged folder would erase `A/x ≡ C/x` — which
        // is still true, still actionable, and the only trace of it once B is
        // gone.
        //
        // Deterministic, and deliberately not the group's « Conservée »: that
        // one belongs to the user, moves from card to card, and is not part of
        // the key the display rebuilds on, so keying absorption on it would
        // leave the file list describing a decision from two clicks ago.
        var absorbing: Set<Int32> = []
        for index in visible {
            let folders = groups[index]
            let canonical = folders.min {
                (store.depth(of: $0), isManaged($0) ? 1 : 0, store.path(of: $0))
                    < (store.depth(of: $1), isManaged($1) ? 1 : 0, store.path(of: $1))
            }
            for folder in folders where folder != canonical && absorbs(folder) {
                absorbing.insert(folder)
            }
        }
        return Plan(visible: visible, absorbing: absorbing)
    }
}
