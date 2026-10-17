import Foundation

public struct NodeFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    public static let symlink = NodeFlags(rawValue: 1 << 1)
    /// Bundle treated as a leaf (`.app`, `.photoslibrary`…).
    public static let package = NodeFlags(rawValue: 1 << 2)
    /// Additional link to an inode already counted; its size is recorded as 0.
    public static let hardlinkDuplicate = NodeFlags(rawValue: 1 << 3)
    public static let mountPoint = NodeFlags(rawValue: 1 << 4)
    public static let firmlink = NodeFlags(rawValue: 1 << 5)
    /// Directory we could not open — its subtree is missing from the totals.
    public static let unreadable = NodeFlags(rawValue: 1 << 6)
    /// Directory deliberately not descended into (policy: node_modules, .git…).
    /// Its own size is still accounted for.
    public static let notDescended = NodeFlags(rawValue: 1 << 7)
    public static let compressed = NodeFlags(rawValue: 1 << 8)
    /// Moved to the Trash during this session. The node stays in the tree so
    /// the deletion can be undone; views hide it and it contributes nothing.
    public static let deleted = NodeFlags(rawValue: 1 << 9)
    /// Present in the listing, absent from the disk: an iCloud file evicted to
    /// free space, or a directory whose contents were never materialised. It
    /// occupies zero bytes, and reading a single one of them downloads it.
    public static let dataless = NodeFlags(rawValue: 1 << 10)
}

/// A whole scanned tree, stored as parallel arrays indexed by node id.
///
/// Deliberately *not* a graph of class instances: at a million nodes the ARC
/// traffic and allocation churn dominate everything else. Here a node is just
/// an `Int32` index, and every field lives in a contiguous array.
///
/// Two invariants make the rest of the code simple, and both are guaranteed by
/// the way `ScanEngine` appends:
///   1. A node's index is always greater than its parent's, so a single reverse
///      pass rolls sizes up the tree.
///   2. A directory's children occupy one contiguous index range, so they can
///      be iterated and sorted as a slice.
public struct NodeStore: Sendable {
    // Names live in one big blob; a node stores only offset + length. Avoids a
    // million individual String allocations.
    public private(set) var nameBlob: [UInt8] = []
    public private(set) var nameOffset: [UInt32] = []
    public private(set) var nameLength: [UInt16] = []

    public private(set) var parent: [Int32] = []
    public private(set) var childStart: [Int32] = []
    public private(set) var childCount: [Int32] = []

    /// Bytes on disk. Before `rollUp()` this is the node's own size; after, it
    /// includes the whole subtree.
    public private(set) var totalAlloc: [Int64] = []
    /// Logical bytes, same lifecycle as `totalAlloc`.
    public private(set) var totalLogical: [Int64] = []
    /// Number of files in the subtree (directories excluded). Rolled up too.
    public private(set) var fileCount: [Int32] = []

    /// Modification time in Unix seconds. Before `rollUp()` this is the node's
    /// own mtime; after, it is the newest mtime anywhere in its subtree.
    ///
    /// A directory's own mtime only says when an entry was last added or renamed
    /// inside it, which makes a cache that is read and rewritten constantly look
    /// abandoned. Rolling the newest date up answers the question the user is
    /// actually asking: *has anything in here moved lately?*
    ///
    /// `Int32` rather than `Int64` to keep the row at four bytes; dates are
    /// clamped on the way in, so a file stamped past 2038 reads as very recent.
    /// That is the safe direction — it can only keep something out of a cleanup
    /// suggestion, never put it in.
    public private(set) var modTime: [Int32] = []

    public private(set) var flags: [NodeFlags] = []

    public var count: Int { parent.count }
    public var isEmpty: Bool { parent.isEmpty }

    public init() {}

    /// Rebuilds a store from arrays read off disk, or nil if they could not
    /// have come from a scan.
    ///
    /// Everything else here indexes these arrays unchecked, so the invariants
    /// the scanner guarantees by construction are verified instead of trusted:
    /// equal lengths, a root that is its own parent, parents before children,
    /// child ranges inside the array and made of exactly the node's own
    /// children, names inside the blob.
    init?(
        validating nameBlob: [UInt8],
        nameOffset: [UInt32], nameLength: [UInt16],
        parent: [Int32], childStart: [Int32], childCount: [Int32],
        totalAlloc: [Int64], totalLogical: [Int64], fileCount: [Int32],
        modTime: [Int32], flags: [NodeFlags]
    ) {
        let n = parent.count
        guard n > 0,
              nameOffset.count == n, nameLength.count == n,
              childStart.count == n, childCount.count == n,
              totalAlloc.count == n, totalLogical.count == n,
              fileCount.count == n, modTime.count == n, flags.count == n,
              parent[0] == 0
        else { return nil }
        for i in 0..<n {
            if i > 0, parent[i] < 0 || Int(parent[i]) >= i { return nil }
            let start = Int(childStart[i]), count = Int(childCount[i])
            if start < 0 || count < 0 || start + count > n { return nil }
            // A range that includes its own owner, or a node whose parent
            // disagrees, would send every recursive walker round in circles.
            // Each node has one parent, so this also keeps ranges disjoint.
            if count > 0 {
                if start <= i { return nil }
                for child in start..<(start + count) where Int(parent[child]) != i {
                    return nil
                }
            }
            if Int(nameOffset[i]) + Int(nameLength[i]) > nameBlob.count { return nil }
        }
        self.nameBlob = nameBlob
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.parent = parent
        self.childStart = childStart
        self.childCount = childCount
        self.totalAlloc = totalAlloc
        self.totalLogical = totalLogical
        self.fileCount = fileCount
        self.modTime = modTime
        self.flags = flags
    }

    public mutating func reserveCapacity(_ n: Int) {
        nameBlob.reserveCapacity(n * 24)
        nameOffset.reserveCapacity(n)
        nameLength.reserveCapacity(n)
        parent.reserveCapacity(n)
        childStart.reserveCapacity(n)
        childCount.reserveCapacity(n)
        totalAlloc.reserveCapacity(n)
        totalLogical.reserveCapacity(n)
        fileCount.reserveCapacity(n)
        modTime.reserveCapacity(n)
        flags.reserveCapacity(n)
    }

    // MARK: - Building

    /// Appends a node and returns its index. `name` is copied into the blob.
    ///
    /// `files` is the number of files this node contributes on its own: 1 for a
    /// regular file, 0 for a directory we will descend into, and the whole
    /// subtree count for a collapsed directory whose children get no nodes.
    @discardableResult
    public mutating func append(
        name: some Collection<UInt8>,
        parent parentIndex: Int32,
        alloc: Int64,
        logical: Int64,
        files: Int32,
        modified: Int32,
        flags nodeFlags: NodeFlags
    ) -> Int32 {
        let index = Int32(parent.count)
        nameOffset.append(UInt32(nameBlob.count))
        nameLength.append(UInt16(min(name.count, Int(UInt16.max))))
        nameBlob.append(contentsOf: name)
        parent.append(parentIndex)
        childStart.append(0)
        childCount.append(0)
        totalAlloc.append(alloc)
        totalLogical.append(logical)
        fileCount.append(files)
        modTime.append(modified)
        flags.append(nodeFlags)
        return index
    }

    /// Records that `node`'s children occupy `start..<start+count`.
    public mutating func setChildren(of node: Int32, start: Int32, count: Int32) {
        childStart[Int(node)] = start
        childCount[Int(node)] = count
    }

    public mutating func markFlag(_ flag: NodeFlags, on node: Int32) {
        flags[Int(node)].insert(flag)
    }

    // MARK: - Roll-up

    /// Accumulates every subtree's sizes, file counts and dates into its
    /// ancestors.
    ///
    /// Relies on invariant 1 (child index > parent index): walking the arrays
    /// backwards means a node is always fully accumulated before its own
    /// contribution is pushed to its parent. One linear pass, no recursion, no
    /// risk of blowing the stack on a deep tree.
    ///
    /// Sizes are summed, dates are maxed. Both are idempotent enough for the
    /// partial snapshots, which roll up a fresh copy of the tree every time.
    public mutating func rollUp() {
        guard count > 1 else { return }
        totalAlloc.withUnsafeMutableBufferPointer { alloc in
            totalLogical.withUnsafeMutableBufferPointer { logical in
                fileCount.withUnsafeMutableBufferPointer { files in
                    modTime.withUnsafeMutableBufferPointer { mod in
                        parent.withUnsafeBufferPointer { parents in
                            Self.accumulate(
                                alloc: alloc, logical: logical, files: files,
                                mod: mod, parents: parents
                            )
                        }
                    }
                }
            }
        }
    }

    /// The reverse pass itself, lifted out of the pointer pyramid above so the
    /// loop stays readable.
    private static func accumulate(
        alloc: UnsafeMutableBufferPointer<Int64>,
        logical: UnsafeMutableBufferPointer<Int64>,
        files: UnsafeMutableBufferPointer<Int32>,
        mod: UnsafeMutableBufferPointer<Int32>,
        parents: UnsafeBufferPointer<Int32>
    ) {
        var i = alloc.count - 1
        while i > 0 {
            let p = Int(parents[i])
            alloc[p] += alloc[i]
            logical[p] += logical[i]
            files[p] += files[i]
            if mod[i] > mod[p] { mod[p] = mod[i] }
            i -= 1
        }
    }

    // MARK: - Reading

    public func name(of node: Int32) -> String {
        let i = Int(node)
        let start = Int(nameOffset[i])
        let end = start + Int(nameLength[i])
        return nameBlob.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start..<end]), as: UTF8.self)
        }
    }

    /// Raw name bytes, for comparing without building a `String`.
    ///
    /// The rule engine tests every directory in the tree against a handful of
    /// names; going through `String` there would mean allocating one per node
    /// just to throw it away.
    public func nameBytes(of node: Int32) -> ArraySlice<UInt8> {
        let i = Int(node)
        let start = Int(nameOffset[i])
        return nameBlob[start..<(start + Int(nameLength[i]))]
    }

    public func hasName(_ node: Int32, _ candidate: [UInt8]) -> Bool {
        let i = Int(node)
        guard Int(nameLength[i]) == candidate.count else { return false }
        let start = Int(nameOffset[i])
        for offset in 0..<candidate.count
        where nameBlob[start + offset] != candidate[offset] { return false }
        return true
    }

    /// Finds a descendant by following path components from `node`.
    public func child(of node: Int32, named name: String) -> Int32? {
        let bytes = Array(name.utf8)
        return children(of: node).first { hasName($0, bytes) }
    }

    public func descendant(of node: Int32, at components: [String]) -> Int32? {
        var current = node
        for component in components {
            guard let next = child(of: current, named: component) else { return nil }
            current = next
        }
        return current
    }

    /// The node an absolute path names, or nil when it lies outside the scan
    /// root or was never walked.
    ///
    /// What lets a folder be shown out of a tree scanned from higher up: a scan
    /// of `/` already holds every folder of the home directory. The path is
    /// matched as given — the caller resolves symlinks the way the scanner
    /// resolved the root, since a store knows nothing of the disk.
    public func node(atPath path: String) -> Int32? {
        guard !isEmpty else { return nil }
        let root = name(of: 0)
        if path == root { return 0 }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let components = path.dropFirst(prefix.count)
            .split(separator: "/").map(String.init)
        return descendant(of: 0, at: components)
    }

    public func children(of node: Int32) -> Range<Int32> {
        let start = childStart[Int(node)]
        return start..<(start + childCount[Int(node)])
    }

    public func isDirectory(_ node: Int32) -> Bool {
        flags[Int(node)].contains(.directory)
    }

    /// How many folders sit between `node` and the scan root.
    ///
    /// Used wherever an order has to be stable without being arbitrary: of two
    /// copies with the same date, the one nearer the root is the one the user
    /// put there.
    public func depth(of node: Int32) -> Int {
        var depth = 0
        var current = node
        while true {
            let next = parent[Int(current)]
            if next == current { return depth } // root points at itself
            depth += 1
            current = next
        }
    }

    /// True when the node is in the Trash, or lives under something that is.
    ///
    /// `markDeleted` marks only the node it was handed: splicing a whole
    /// subtree out would cost its size in work on every click, and crediting
    /// the ancestors back already keeps every total honest. So the flag sits
    /// at the top of the trashed subtree and everything below it has to climb
    /// to find out.
    ///
    /// Until folder duplicates the only reader that climbed was `SearchMask`,
    /// which carries deletion downwards in a pass of its own — which is why a
    /// file inside a trashed folder went on being listed as long as no search
    /// was running. Answering per node is O(depth), and depth is single digits.
    public func isEffectivelyDeleted(_ node: Int32) -> Bool {
        guard node >= 0, Int(node) < count else { return true }
        var current = node
        while true {
            if flags[Int(current)].contains(.deleted) { return true }
            let next = parent[Int(current)]
            if next == current { return false }
            current = next
        }
    }

    /// Last modification, or the newest one in the subtree for a directory.
    /// Nil when the filesystem gave us no date at all.
    public func modificationDate(of node: Int32) -> Date? {
        let seconds = modTime[Int(node)]
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Rebuilds an absolute path by walking up to the root, whose name is the
    /// full root path. Cheap enough for on-demand use (inspector, deletion);
    /// not meant to be called per node during a scan.
    public func path(of node: Int32) -> String {
        var components: [String] = []
        var current = node
        while true {
            components.append(name(of: current))
            let p = parent[Int(current)]
            if p == current { break } // root points at itself
            current = p
        }
        var result = components.removeLast() // root path
        while let component = components.popLast() {
            if !result.hasSuffix("/") { result += "/" }
            result += component
        }
        return result
    }

    /// Children sorted by descending size — the order every view wants.
    /// Items deleted this session are dropped.
    public func childrenSortedBySize(
        of node: Int32, useLogical: Bool = false
    ) -> [Int32] {
        let sizes = useLogical ? totalLogical : totalAlloc
        return children(of: node)
            .filter { !flags[Int($0)].contains(.deleted) }
            .sorted { sizes[Int($0)] > sizes[Int($1)] }
    }

    // MARK: - Deletion

    /// Records that `node` is gone, crediting its bytes back to every ancestor.
    ///
    /// The node is kept rather than spliced out: indices are woven through the
    /// parent and child arrays, and through geometry the views are animating,
    /// so removing an entry would invalidate all of it. Marking is O(depth) and
    /// lets the tree stay live under the user instead of forcing a rescan.
    ///
    /// `modTime` is deliberately left alone. A date is not a total, so there is
    /// nothing to credit back: an ancestor simply keeps the date of a child that
    /// went to the Trash, until the next scan. Fixing that would mean rescanning
    /// the whole subtree for a new maximum on every single deletion.
    public mutating func markDeleted(_ node: Int32) {
        let index = Int(node)
        guard node > 0, !flags[index].contains(.deleted) else { return }
        applyDelta(
            from: node,
            alloc: -totalAlloc[index],
            logical: -totalLogical[index],
            files: -fileCount[index]
        )
        flags[index].insert(.deleted)
    }

    /// Reverses `markDeleted` after the item has been put back on disk.
    public mutating func unmarkDeleted(
        _ node: Int32, alloc: Int64, logical: Int64, files: Int32
    ) {
        let index = Int(node)
        guard flags[index].contains(.deleted) else { return }
        flags[index].remove(.deleted)
        totalAlloc[index] = alloc
        totalLogical[index] = logical
        fileCount[index] = files
        applyDelta(from: node, alloc: alloc, logical: logical, files: files)
    }

    /// Adds a delta to every ancestor of `node`, stopping at the root, which is
    /// its own parent.
    private mutating func applyDelta(
        from node: Int32, alloc: Int64, logical: Int64, files: Int32
    ) {
        if alloc < 0 {
            let index = Int(node)
            totalAlloc[index] = 0
            totalLogical[index] = 0
            fileCount[index] = 0
        }
        var current = parent[Int(node)]
        while true {
            let index = Int(current)
            totalAlloc[index] += alloc
            totalLogical[index] += logical
            fileCount[index] += files
            let next = parent[index]
            if next == current { break }
            current = next
        }
    }
}

extension NodeStore {

    /// What a path that came back from the Trash weighs now, read from disk.
    ///
    /// Kept apart from the tree it is applied to for two reasons. Measuring is
    /// disk work — a package or a collapsed folder is walked whole — and must
    /// run off the main actor, while the trees live on it. And the same path
    /// may sit in several trees in memory, which should not each walk it.
    public struct Remeasured: Sendable {
        /// Everything below a folder, summed as the scanner sums a folder it
        /// does not descend into.
        public struct Contents: Sendable, Equatable {
            public var alloc: Int64
            public var logical: Int64
            public var files: Int32
        }

        public var isFolder: Bool
        /// A file's two sizes; a folder's own blocks, for both.
        public var alloc: Int64
        public var logical: Int64
        /// Nil for a file, and for a folder measured without them.
        public var contents: Contents?
    }

    /// Reads `path` from disk. Nil when nothing is there any more.
    ///
    /// A file is read with the attributes the scanner records
    /// (`ATTR_FILE_TOTALSIZE` / `ATTR_FILE_ALLOCSIZE`), not `lstat`, whose
    /// `st_size` leaves out the resource fork. A folder's contents are only
    /// walked when `withContents` says some tree needs them — see
    /// `needsContentsToReinstate` — since a walked folder's children already
    /// carry their totals and walking a big one would be wasted time.
    public static func remeasure(
        _ path: String, withContents: Bool, options: ScanOptions = ScanOptions()
    ) -> Remeasured? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            let sizes = DiskCheck.sizes(of: path, fallback: info)
            return Remeasured(isFolder: false, alloc: sizes.alloc, logical: sizes.total)
        }
        // The directory attributes carry no separate length: the scanner
        // counts a folder's own blocks for both.
        let own = Int64(info.st_blocks) * 512
        var measured = Remeasured(isFolder: true, alloc: own, logical: own)
        if withContents {
            let sum = ScanEngine.contentsTotals(of: path, device: info.st_dev, options: options)
            measured.contents = .init(alloc: sum.alloc, logical: sum.logical, files: sum.files)
        }
        return measured
    }

    /// True when bringing `node` back as a folder takes a walk of its
    /// contents: the scan gave it no children to add up — a package, a
    /// collapsed folder, another volume — or it was not a folder at all.
    public func needsContentsToReinstate(_ node: Int32) -> Bool {
        !isDirectory(node) || flags[Int(node)].contains(.notDescended)
    }

    /// Sizes to give back to a node marked `.deleted` that has returned to
    /// disk, without remembering what it weighed before. Pure arithmetic on
    /// the tree and a measurement taken beforehand.
    ///
    /// An extra hard link comes back at zero, as the scan stored it: another
    /// link to the same inode still pays for the bytes. `markDeleted` zeroes
    /// only the node it is handed, so the children of a walked folder still
    /// carry their totals and are summed here. A child that was trashed
    /// earlier is already at zero, and asking `isEffectivelyDeleted` would be
    /// wrong anyway: the folder's own flag is still set. The folder itself
    /// counts as the scan engine counts it: its own blocks for both alloc and
    /// logical, no file. Anything the scan never descended into has no
    /// children to add up, so it takes the measured contents — and is nil if
    /// they were not measured, rather than a guess.
    public func reinstatedSizes(of node: Int32, from measured: Remeasured)
        -> (alloc: Int64, logical: Int64, files: Int32)?
    {
        guard measured.isFolder else {
            if flags[Int(node)].contains(.hardlinkDuplicate) { return (0, 0, 1) }
            return (measured.alloc, measured.logical, 1)
        }
        guard !needsContentsToReinstate(node) else {
            guard let contents = measured.contents else { return nil }
            return (
                measured.alloc + contents.alloc,
                measured.logical + contents.logical,
                contents.files
            )
        }

        var alloc = measured.alloc, logical = measured.logical, files: Int32 = 0
        for child in children(of: node) {
            alloc += totalAlloc[Int(child)]
            logical += totalLogical[Int(child)]
            files += fileCount[Int(child)]
        }
        return (alloc, logical, files)
    }
}
