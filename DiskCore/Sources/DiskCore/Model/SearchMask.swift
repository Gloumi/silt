import Foundation

/// Which nodes survive a search, and how many bytes each subtree still stands
/// for once the rest is filtered out.
///
/// Dense arrays rather than a dictionary of survivors, for the same reason
/// `NodeStore` is a struct of arrays: the layouts read this once per tile, once
/// per arc and once per sorted child list, and a hash lookup in those loops
/// costs more than the whole pass that produced them. The frugal shape is also
/// only frugal when it does not matter — a one-letter query on a disk keeps
/// nearly every node, which is exactly when a dictionary would be at its worst.
public struct SearchMask: Sendable {

    public let query: SearchQuery
    public let useLogical: Bool

    /// How many nodes the mask was built for.
    ///
    /// The store keeps growing during a scan, so a node can be newer than the
    /// mask. Every accessor below bounds-checks against this rather than
    /// trapping: those nodes are simply not kept until the next rebuild, a few
    /// hundred milliseconds later.
    public let count: Int

    /// Bytes a node still stands for: its own total when it matches, otherwise
    /// the sum of what its children retain.
    private let retained: [Int64]
    /// Matched by name, or standing under something that did. Everything under a
    /// matching folder is retained whole — the folder is the result, and its
    /// contents have to stay explorable.
    private let matched: [Bool]
    /// This node, or something below it, is a result. Kept apart from
    /// `retained > 0` so a matching empty file does not vanish.
    private let kept: [Bool]
    /// Results in the subtree, counted on names only — a matching folder is one
    /// result, not one per file it happens to contain.
    private let results: [Int32]

    public var isEmpty: Bool { totalResults == 0 }
    public var totalResults: Int { results.isEmpty ? 0 : Int(results[0]) }

    // MARK: - Reading

    /// True when the node is a result or holds one, which is the test for
    /// "should this be on screen at all".
    public func keeps(_ node: Int32) -> Bool {
        let i = Int(node)
        return i >= 0 && i < count && kept[i]
    }

    /// True when the node is itself a result, or lives inside one.
    public func matches(_ node: Int32) -> Bool {
        let i = Int(node)
        return i >= 0 && i < count && matched[i]
    }

    public func bytes(of node: Int32) -> Int64 {
        let i = Int(node)
        return i >= 0 && i < count ? retained[i] : 0
    }

    public func resultCount(under node: Int32) -> Int {
        let i = Int(node)
        return i >= 0 && i < count ? Int(results[i]) : 0
    }

    // MARK: - Building

    public static func build(
        store: NodeStore, query: SearchQuery, useLogical: Bool
    ) -> SearchMask {
        let count = store.count
        var own = [Bool](repeating: false, count: count)
        var matched = [Bool](repeating: false, count: count)
        var kept = [Bool](repeating: false, count: count)
        var retained = [Int64](repeating: 0, count: count)
        var results = [Int32](repeating: 0, count: count)

        guard count > 1 else {
            return SearchMask(
                query: query, useLogical: useLogical, count: count,
                retained: retained, matched: matched, kept: kept, results: results
            )
        }

        // Pass 1 — names.
        store.nameBlob.withUnsafeBufferPointer { blob in
            store.nameOffset.withUnsafeBufferPointer { offsets in
                store.nameLength.withUnsafeBufferPointer { lengths in
                    own.withUnsafeMutableBufferPointer { hits in
                        scanNames(
                            blob: blob, offsets: offsets, lengths: lengths,
                            query: query, into: hits
                        )
                    }
                }
            }
        }

        let parents = store.parent
        let flags = store.flags

        // Pass 2 — two flags travelling downwards at once.
        //
        // Invariant 1 read the other way round: a parent's index is always lower
        // than its children's, so one forward pass carries a flag all the way
        // down.
        //
        // A matching folder takes its whole subtree with it. Without that,
        // opening a folder you just found by name would show an empty list — its
        // children match nothing themselves.
        //
        // Deletion travels the same way and wins. `markDeleted` only ever marks
        // the node itself, so the top of a trashed subtree is the one place its
        // contents can be recognised as gone; carrying it down is what keeps the
        // mask from claiming to keep a file that is in the Trash.
        matched = own
        var trashed = [Bool](repeating: false, count: count)
        for i in 1..<count {
            let p = Int(parents[i])
            if flags[i].contains(.deleted) || trashed[p] {
                trashed[i] = true
                matched[i] = false
                own[i] = false
                continue
            }
            if matched[p] { matched[i] = true }
        }

        // Pass 3 — sizes, hits and counts, upwards.
        //
        // Same reverse walk as `NodeStore.rollUp`: a node has received
        // everything its children retain before it hands its own total up. A
        // node that matches *replaces* what its children contributed with its
        // whole size rather than adding to it — adding would charge a matching
        // folder's bytes twice.
        kept = matched
        let sizes = useLogical ? store.totalLogical : store.totalAlloc
        var i = count - 1
        while i > 0 {
            defer { i -= 1 }
            guard !trashed[i] else { continue }
            if matched[i] { retained[i] = sizes[i] }
            if own[i] { results[i] += 1 }
            let p = Int(parents[i])
            retained[p] += retained[i]
            results[p] += results[i]
            if kept[i] { kept[p] = true }
        }

        return SearchMask(
            query: query, useLogical: useLogical, count: count,
            retained: retained, matched: matched, kept: kept, results: results
        )
    }

    /// The name pass itself, lifted out of the pointer pyramid above so the loop
    /// stays readable — same shape as `NodeStore.accumulate`.
    ///
    /// Node 0 is skipped: the scan root's name *is* its absolute path, so a
    /// search for "users" would match it, and a matching root retains the whole
    /// disk — the filter would silently do nothing.
    private static func scanNames(
        blob: UnsafeBufferPointer<UInt8>,
        offsets: UnsafeBufferPointer<UInt32>,
        lengths: UnsafeBufferPointer<UInt16>,
        query: SearchQuery,
        into own: UnsafeMutableBufferPointer<Bool>
    ) {
        var i = 1
        while i < own.count {
            let start = Int(offsets[i])
            let name = UnsafeBufferPointer(
                rebasing: blob[start..<(start + Int(lengths[i]))]
            )
            own[i] = query.matches(name)
            i += 1
        }
    }

    private init(
        query: SearchQuery, useLogical: Bool, count: Int,
        retained: [Int64], matched: [Bool], kept: [Bool], results: [Int32]
    ) {
        self.query = query
        self.useLogical = useLogical
        self.count = count
        self.retained = retained
        self.matched = matched
        self.kept = kept
        self.results = results
    }
}

// MARK: - Focus

extension SearchMask {

    /// Deepest node worth showing: descend while exactly one branch survives.
    ///
    /// After a search across a whole disk, standing at the root means looking at
    /// one slice in a hundred that happens to be non-empty, and the treemap
    /// spends its three levels of depth on empty corridors. The answer to "where
    /// are my results" is the closest folder that still contains all of them.
    ///
    /// The descent stops *above* a folder that is itself a result: stepping into
    /// it would show its contents, and the thing the user searched for would no
    /// longer be on screen.
    public func focus(from root: Int32, in store: NodeStore) -> Int32 {
        guard keeps(root) else { return root }
        var node = root
        while true {
            var only: Int32?
            for child in store.children(of: node) where keeps(child) {
                if only != nil { return node } // the branches part here
                only = child
            }
            guard let child = only, !matches(child), store.isDirectory(child),
                  store.childCount[Int(child)] > 0
            else { return node }
            node = child
        }
    }
}

// MARK: - Reading a store through a mask

extension NodeStore {

    /// Size a view should draw for `node`: everything it holds, or only what
    /// survives a filter.
    public func size(
        of node: Int32, useLogical: Bool, through filter: SearchMask?
    ) -> Int64 {
        guard let filter else {
            return useLogical ? totalLogical[Int(node)] : totalAlloc[Int(node)]
        }
        return filter.bytes(of: node)
    }

    /// `childrenSortedBySize`, restricted to the branches a filter keeps.
    ///
    /// Sorted on retained sizes rather than real ones: under a filter, a folder
    /// holding one matching kilobyte must not outrank a folder holding a
    /// gigabyte of them just because it is bigger overall.
    public func childrenSortedBySize(
        of node: Int32, useLogical: Bool = false, through filter: SearchMask?
    ) -> [Int32] {
        guard let filter else {
            return childrenSortedBySize(of: node, useLogical: useLogical)
        }
        return children(of: node)
            .filter { !flags[Int($0)].contains(.deleted) && filter.keeps($0) }
            .sorted { filter.bytes(of: $0) > filter.bytes(of: $1) }
    }
}
