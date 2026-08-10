import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Finds sets of regular files with byte-identical content under a subtree.
///
/// The work is progressive, so the disk is only read where cheaper evidence
/// has failed to separate two files: group by logical size (free — the scan
/// already recorded every size), hash the first `prefixLength` bytes of files
/// sharing a size, and read whole files only for the groups a prefix could not
/// split. On a typical tree the full pass touches a small fraction of the
/// candidate bytes.
///
/// Hard links get folded before anything is hashed: two paths sharing an inode
/// share their bytes, so hashing both would be wasted IO and — worse —
/// counting both as reclaimable would promise space that deleting a link can
/// never free. APFS clones stay invisible (telling one apart needs a per-block
/// syscall), so every reclaimable figure is an upper bound; the UI says so.
public enum DuplicateFinder {

    public struct Options: Sendable {
        /// Files smaller than this never become candidates. Below about a
        /// megabyte duplicates are innumerable and worthless to a cleanup.
        public var minimumSize: Int64 = 1_000_000
        /// Folders smaller than this never become candidates. Nil disables the
        /// folder pass entirely, which is what every caller that only wants
        /// files should pass.
        public var folderMinimumSize: Int64?
        /// Bytes hashed in the first pass. Files no larger than this skip the
        /// full pass entirely — their prefix is their content.
        public var prefixLength: Int = 128 * 1024
        /// Concurrent hashing workers. The work is IO-bound; a few workers
        /// saturate an SSD without starving the rest of the machine.
        public var workerCount: Int = 4
        public init() {}
    }

    /// Identity of storage on disk. Two paths with the same `FileID` are hard
    /// links: they share their bytes, and unlinking one frees nothing.
    public struct FileID: Sendable, Hashable {
        public var device: Int32
        public var inode: UInt64
    }

    /// One physical copy inside a group — usually one path, more when the
    /// scan saw hard links to the same inode.
    public struct Storage: Sendable {
        public var fileID: FileID
        /// Nodes sharing this inode, in `keeperRank` order — newest first, ties
        /// broken by depth then path.
        public var nodes: [Int32]
        /// `st_nlink` at hash time. `nodes.count < linkCount` means links
        /// exist outside the scanned subtree: deleting every path listed here
        /// still leaves the bytes on disk.
        public var linkCount: Int
        /// On-disk bytes, taken from the store rather than re-measured so the
        /// figure matches what every other view shows for the same file.
        public var allocated: Int64
        /// Device offset shared with at least one other storage in this
        /// group, or nil when these bytes are this copy's own.
        ///
        /// The value and not just a flag, because "shares with something" is
        /// not the question anyone is asking. What matters is *which* copies
        /// share with *which*: deleting a copy frees nothing only when the one
        /// being kept holds the same blocks.
        public var sharedExtent: Int64?

        public var sharesBlocks: Bool { sharedExtent != nil }
    }

    /// Files whose content hashed identical. Always at least two storages.
    public struct Group: Sendable {
        /// SHA-256 of the full content (or of the whole file when it fits in
        /// the prefix). Kept for tests and debugging, not shown to the user.
        public var digest: [UInt8]
        public var logicalSize: Int64
        /// Sorted by `keeperRank`, so "keep the most recent" is index zero.
        public var storages: [Storage]
        /// Upper bound on what deleting all copies but one would free. A
        /// storage with links outside the subtree contributes nothing — its
        /// bytes survive the deletion regardless.
        public var reclaimableBytes: Int64
    }

    public struct Result: Sendable {
        /// Folders whose entire contents hashed identical, sorted by
        /// descending `reclaimableBytes`. Empty unless `folderMinimumSize`
        /// asked for them.
        ///
        /// Nested groups are all here: when `A/` ≡ `B/`, `A/sub` ≡ `B/sub` is
        /// reported too. Showing only the topmost is the display's business —
        /// once the user resolves `A`, the duplication inside what survives is
        /// still real, and an engine that had dropped it would have to read the
        /// disk again to find it.
        public var folderGroups: [FolderGroup]
        /// Sorted by descending `reclaimableBytes`.
        public var groups: [Group]
        /// Candidate files that entered the hashing pipeline.
        public var candidateCount: Int
        /// Total bytes read, across every pass.
        public var bytesHashed: Int64
        /// Candidates silently dropped: vanished, changed size, or unreadable
        /// between the scan and the hash — plus folders that failed to verify
        /// for the same reasons. Normal life, not an error.
        public var droppedCount: Int
        /// Files and folders left alone because their contents are in iCloud
        /// and not on this disk. Comparing one means downloading it, and it
        /// occupies nothing here, so deleting it would free nothing anyway.
        public var datalessCount: Int
    }

    public struct Progress: Sendable {
        public enum Stage: Sendable {
            case collecting, prefixPass, fullPass
            /// Reading candidate folders entry by entry. Bound by syscalls
            /// rather than bytes, so it reports files rather than a byte bar.
            case folderScan
            case folderCompare
        }
        public var stage: Stage
        public var bytesHashed: Int64
        public var bytesToHash: Int64
        public var filesHashed: Int
        public var filesToHash: Int
    }

    /// Runs the whole pipeline. Returns nil when the surrounding task is
    /// cancelled — cancellation is checked between files and between read
    /// chunks, so a multi-gigabyte pass stops promptly.
    ///
    /// `onProgress` is throttled to ~10 Hz and called from worker threads;
    /// a UI caller hops to the main actor itself.
    public static func find(
        in store: NodeStore,
        under root: Int32,
        options: Options = Options(),
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async -> Result? {
        guard !store.isEmpty, root >= 0, Int(root) < store.count else {
            return Result(
                folderGroups: [], groups: [], candidateCount: 0,
                bytesHashed: 0, droppedCount: 0, datalessCount: 0
            )
        }
        onProgress?(Progress(
            stage: .collecting, bytesHashed: 0, bytesToHash: 0,
            filesHashed: 0, filesToHash: 0
        ))

        // One cache for both passes: a file the folder pass already read must
        // not be read again by the file pass a second later.
        let cache = DigestCache()
        var dropped = 0
        var dataless = 0
        var totalHashed: Int64 = 0

        // ---- Folders first. They are the coarser answer, and the files they
        // cover get absorbed into them at display time.
        var folderGroups: [FolderGroup] = []
        if let folderMinimum = options.folderMinimumSize {
            guard let folders = await findFolders(
                in: store, under: root, minimumSize: folderMinimum,
                options: options, cache: cache, onProgress: onProgress
            ) else { return nil }
            folderGroups = folders.groups
            dropped += folders.dropped
            dataless += folders.dataless
            totalHashed += folders.bytesHashed
            onProgress?(Progress(
                stage: .collecting, bytesHashed: 0, bytesToHash: 0,
                filesHashed: 0, filesToHash: 0
            ))
        }

        // ---- Phase 0: size buckets, free because the scan measured everything.
        guard let collected = collect(in: store, under: root, options: options)
        else { return nil }
        let candidateCount = collected.buckets.values.reduce(0) { $0 + $1.count }
        dataless += collected.dataless

        // ---- Phase 1: stat, fold hard links, then hash prefixes.
        // Stat also re-checks the size: a file that grew or shrank since the
        // scan is not the file the bucket was built from.
        let linkedByID = inodes(of: collected.hardlinkNodes, in: store)
        var buckets: [Int64: [Draft]] = [:]
        for (size, nodes) in collected.buckets {
            var drafts: [FileID: Draft] = [:]
            for node in nodes {
                let path = store.path(of: node)
                var info = stat()
                guard lstat(path, &info) == 0 else { dropped += 1; continue }
                guard UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
                      info.st_size == size
                else { dropped += 1; continue }
                let id = FileID(device: info.st_dev, inode: info.st_ino)
                if drafts[id] == nil {
                    drafts[id] = Draft(
                        fileID: id,
                        nodes: [node] + (linkedByID[id] ?? []),
                        linkCount: Int(info.st_nlink),
                        allocated: store.totalAlloc[Int(node)],
                        size: size,
                        modTime: Int64(info.st_mtimespec.tv_sec),
                        path: path
                    )
                } else {
                    // Same inode reached through two candidate nodes: a link
                    // made after the scan. Fold it — hashing twice would say
                    // a file duplicates itself.
                    drafts[id]?.nodes.append(node)
                }
            }
            if drafts.count >= 2 { buckets[size] = Array(drafts.values) }
        }

        let prefixJobs = buckets.values.flatMap { $0 }
        guard let prefixPass = await hash(
            jobs: prefixJobs, limit: options.prefixLength,
            workerCount: options.workerCount, stage: .prefixPass,
            cache: cache, onProgress: onProgress
        ) else { return nil }
        dropped += prefixPass.dropped
        totalHashed += prefixPass.bytesRead

        // Split every size bucket by its prefix digests. Files that fit inside
        // the prefix are fully known already and become groups right here.
        var groups: [Group] = []
        var fullJobs: [[Draft]] = []
        for (size, drafts) in buckets {
            var byDigest: [[UInt8]: [Draft]] = [:]
            for draft in drafts {
                guard let digest = prefixPass.digests[draft.fileID] else { continue }
                byDigest[digest, default: []].append(draft)
            }
            for (digest, matching) in byDigest where matching.count >= 2 {
                if size <= Int64(options.prefixLength) {
                    groups.append(assemble(
                        matching, digest: digest, in: store,
                        extents: prefixPass.extents
                    ))
                } else {
                    fullJobs.append(matching)
                }
            }
        }

        // ---- Phase 2: whole-file hash, only where a prefix could not decide.
        guard let fullPass = await hash(
            jobs: fullJobs.flatMap { $0 }, limit: nil,
            workerCount: options.workerCount, stage: .fullPass,
            cache: cache, onProgress: onProgress
        ) else { return nil }
        dropped += fullPass.dropped
        totalHashed += fullPass.bytesRead

        for drafts in fullJobs {
            var byDigest: [[UInt8]: [Draft]] = [:]
            for draft in drafts {
                guard let digest = fullPass.digests[draft.fileID] else { continue }
                byDigest[digest, default: []].append(draft)
            }
            for (digest, matching) in byDigest where matching.count >= 2 {
                groups.append(assemble(
                    matching, digest: digest, in: store,
                    extents: fullPass.extents
                ))
            }
        }

        groups.sort {
            ($0.reclaimableBytes, $0.logicalSize) > ($1.reclaimableBytes, $1.logicalSize)
        }
        return Result(
            folderGroups: folderGroups,
            groups: groups,
            candidateCount: candidateCount,
            bytesHashed: totalHashed,
            droppedCount: dropped,
            datalessCount: dataless
        )
    }

    // MARK: - Phase 0: collection

    private struct Collected {
        /// Logical size → candidate nodes, only sizes seen at least twice.
        var buckets: [Int64: [Int32]]
        /// `.hardlinkDuplicate` nodes under the root. They carry size 0 so
        /// they can never seed a bucket, but they name paths the user can see,
        /// so they must reattach to their inode's storage.
        var hardlinkNodes: [Int32]
        /// Files left alone because their contents live in iCloud rather than
        /// on this disk.
        var dataless: Int
    }

    /// One stack walk, the same shape as `LargestFiles.top`: a subtree is not
    /// a contiguous index range, workers interleave siblings during the scan.
    private static func collect(
        in store: NodeStore, under root: Int32, options: Options
    ) -> Collected? {
        let minimum = max(options.minimumSize, 1)
        var sizes: [Int64: [Int32]] = [:]
        var seenOnce: [Int64: Int32] = [:]
        var hardlinkNodes: [Int32] = []
        var dataless = 0
        var stack: [Int32] = [root]
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            if visited & 0x3FF == 0, Task.isCancelled { return nil }
            let index = Int(node)
            let flags = store.flags[index]
            // `markDeleted` marks only the node itself; descending under a
            // deleted directory would resurrect files already in the Trash.
            if flags.contains(.deleted) { continue }
            if flags.contains(.directory) {
                for child in store.children(of: node) { stack.append(child) }
                continue
            }
            if flags.contains(.hardlinkDuplicate) {
                hardlinkNodes.append(node)
                continue
            }
            if flags.contains(.symlink) || flags.contains(.unreadable) { continue }
            // An evicted iCloud file is a listing entry with nothing behind it.
            // It occupies zero bytes, so deleting it frees nothing — the same
            // reason hard links are folded rather than proposed — and the only
            // way to compare it is to download it, which fills the very disk
            // the user opened this app to empty.
            //
            // The bucket is built on the *logical* size, which for one of these
            // is the full size of a file that is not there, while `totalAlloc`
            // is zero and that is what the rest of the app shows. So without
            // this they were candidates like any other, and hashing them pulled
            // them down one by one.
            if flags.contains(.dataless) { dataless += 1; continue }
            let size = store.totalLogical[index]
            guard size >= minimum else { continue }
            // Most sizes are unique; keeping singletons out of the dictionary
            // of arrays until a second file shows up avoids allocating an
            // array per distinct size in the tree.
            if var bucket = sizes[size] {
                bucket.append(node)
                sizes[size] = bucket
            } else if let first = seenOnce.removeValue(forKey: size) {
                sizes[size] = [first, node]
            } else {
                seenOnce[size] = node
            }
        }
        return Collected(
            buckets: sizes, hardlinkNodes: hardlinkNodes, dataless: dataless
        )
    }

    /// Inode of every extra hard link the scan recorded, so the paths can be
    /// listed inside their storage. Failures are ignored: an unresolvable
    /// link just goes unlisted, it was never a candidate.
    private static func inodes(
        of nodes: [Int32], in store: NodeStore
    ) -> [FileID: [Int32]] {
        var result: [FileID: [Int32]] = [:]
        for node in nodes {
            var info = stat()
            guard lstat(store.path(of: node), &info) == 0,
                  UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG)
            else { continue }
            result[FileID(device: info.st_dev, inode: info.st_ino), default: []]
                .append(node)
        }
        return result
    }

    // MARK: - Hashing

    /// One inode waiting to be hashed, with everything the final group needs.
    ///
    /// Module-visible, like the four functions below it: the folder pass hashes
    /// files the very same way and rebuilding that machinery beside it would
    /// mean two worker pools competing for the same disk.
    struct Draft: Sendable {
        var fileID: FileID
        /// Nodes in the scanned tree, empty for a job the folder pass raised
        /// from a live directory read.
        var nodes: [Int32] = []
        var linkCount: Int = 1
        var allocated: Int64 = 0
        var size: Int64
        /// Last modification, so a cached digest can be told from a stale one.
        var modTime: Int64
        var path: String
    }

    struct HashPass {
        var digests: [FileID: [UInt8]]
        /// Device offset of each file's first extent, when the filesystem
        /// would say. Free to collect: the hasher already holds the
        /// descriptor, so this costs one `fcntl` and reads nothing.
        var extents: [FileID: Int64]
        var bytesRead: Int64
        var dropped: Int
    }

    /// Digests already computed during this run, so the folder pass and the
    /// file pass never read the same bytes twice. A pair of duplicated project
    /// folders means the same hundred thousand files are candidates in both.
    ///
    /// The key carries the *limit*, and that is not a detail. A prefix digest
    /// and a whole-file digest are two different answers about one file; keyed
    /// on the inode alone, the 128 KiB the folder pass read would come back a
    /// second later as the file's full content, and Silt would offer to delete
    /// files that are identical for one block and diverge after it.
    ///
    /// The entry is then *validated* against size and mtime rather than
    /// trusted: an inode is reused the moment a file is deleted, and a rewrite
    /// in place keeps both the inode and the size.
    final class DigestCache: Sendable {
        struct Key: Hashable {
            var fileID: FileID
            /// Bytes hashed; `-1` means the whole file.
            var limit: Int
        }

        private struct Entry {
            var digest: [UInt8]
            var extent: Int64?
            var size: Int64
            var modTime: Int64
        }

        private let entries = Mutex<[Key: Entry]>([:])

        /// The extent rides along with the digest: a cache hit skips the open,
        /// and without it the second pass would lose the one measurement that
        /// tells a clone from a copy.
        func digest(
            for key: Key, size: Int64, modTime: Int64
        ) -> (digest: [UInt8], extent: Int64?)? {
            entries.withLock { stored in
                guard let entry = stored[key], entry.size == size,
                      entry.modTime == modTime
                else { return nil }
                return (entry.digest, entry.extent)
            }
        }

        func store(
            _ digest: [UInt8], extent: Int64?, for key: Key,
            size: Int64, modTime: Int64
        ) {
            entries.withLock {
                $0[key] = Entry(
                    digest: digest, extent: extent, size: size, modTime: modTime
                )
            }
        }
    }

    /// All shared mutable state of a hashing pass behind one lock, following
    /// `ScanEngine`'s pattern. The lock is taken per chunk, not per byte, and
    /// hashing itself happens outside it.
    final class HashState: Sendable {
        struct Inner {
            var nextJob = 0
            var bytesHashed: Int64 = 0
            /// Of those, the ones a cache hit spared us. The progress bar wants
            /// the first figure, the report wants the difference.
            var bytesFromCache: Int64 = 0
            var filesHashed = 0
            var dropped = 0
            var digests: [FileID: [UInt8]] = [:]
            var extents: [FileID: Int64] = [:]
            var lastReport: ContinuousClock.Instant
        }
        let inner: Mutex<Inner>
        init() { inner = Mutex(Inner(lastReport: .now)) }
    }

    static func hash(
        jobs: [Draft],
        limit: Int?,
        workerCount: Int,
        stage: Progress.Stage,
        cache: DigestCache?,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async -> HashPass? {
        guard !jobs.isEmpty else {
            return HashPass(digests: [:], extents: [:], bytesRead: 0, dropped: 0)
        }
        let bytesToHash = jobs.reduce(Int64(0)) { sum, job in
            sum + (limit.map { min(job.size, Int64($0)) } ?? job.size)
        }
        onProgress?(Progress(
            stage: stage, bytesHashed: 0, bytesToHash: bytesToHash,
            filesHashed: 0, filesToHash: jobs.count
        ))
        let state = HashState()
        let workers = max(1, min(workerCount, jobs.count))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    hashWorker(
                        jobs: jobs, limit: limit, state: state, stage: stage,
                        bytesToHash: bytesToHash, cache: cache,
                        onProgress: onProgress
                    )
                }
            }
        }
        if Task.isCancelled { return nil }
        return state.inner.withLock {
            HashPass(
                digests: $0.digests,
                extents: $0.extents,
                bytesRead: $0.bytesHashed - $0.bytesFromCache,
                dropped: $0.dropped
            )
        }
    }

    static func hashWorker(
        jobs: [Draft],
        limit: Int?,
        state: HashState,
        stage: Progress.Stage,
        bytesToHash: Int64,
        cache: DigestCache?,
        onProgress: (@Sendable (Progress) -> Void)?
    ) {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while !Task.isCancelled {
            let index = state.inner.withLock { inner in
                defer { inner.nextJob += 1 }
                return inner.nextJob
            }
            guard index < jobs.count else { return }
            let job = jobs[index]
            let expected = limit.map { min(job.size, Int64($0)) } ?? job.size

            let key = DigestCache.Key(fileID: job.fileID, limit: limit ?? -1)
            if let known = cache?.digest(
                for: key, size: job.size, modTime: job.modTime
            ) {
                state.inner.withLock {
                    $0.digests[job.fileID] = known.digest
                    if let extent = known.extent { $0.extents[job.fileID] = extent }
                }
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: expected, cached: true,
                       finished: true, dropped: false, onProgress: onProgress)
                continue
            }

            // O_NOFOLLOW as defense in depth: the node was a regular file at
            // scan time and at stat time, but the path could have been swapped
            // for a symlink since. O_NONBLOCK because `open` on a named pipe
            // with no writer blocks *inside the kernel*, and cancellation is
            // only ever tested between blocks — one fifo would pin this worker
            // until the app quits. It has no effect on a regular file.
            let fd = open(job.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: 0, cached: false,
                       finished: true, dropped: true, onProgress: onProgress)
                continue
            }
            // And confirm what we actually opened. The kind was decided before
            // this call, by a listing or a stat that is now in the past.
            var opened = stat()
            guard fstat(fd, &opened) == 0,
                  UInt32(opened.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG)
            else {
                close(fd)
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: 0, cached: false,
                       finished: true, dropped: true, onProgress: onProgress)
                continue
            }
            // Where the first block physically lives. Two files at the same
            // device offset are APFS clones: separate inodes, one link each,
            // and the same bytes on the platter. Nothing in `stat` can tell
            // them from real copies, which is why every reclaim figure was an
            // over-estimate until this line. Failure is fine — the file is
            // then treated as unshared, which is what was assumed before.
            var extent = log2phys()
            extent.l2p_devoffset = 0
            extent.l2p_contigbytes = 0
            let physical: Int64? = fcntl(fd, F_LOG2PHYS_EXT, &extent) == 0
                ? Int64(extent.l2p_devoffset) : nil
            if let physical {
                state.inner.withLock { $0.extents[job.fileID] = physical }
            }

            // Streaming gigabytes through the page cache would evict what the
            // user is actually working with, for pages we will read once.
            _ = fcntl(fd, F_NOCACHE, 1)

            var hasher = SHA256()
            var remaining = expected
            var truncated = false
            while remaining > 0 {
                if Task.isCancelled { break }
                let want = Int(min(Int64(buffer.count), remaining))
                let got = buffer.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress, want)
                }
                guard got > 0 else { truncated = true; break }
                buffer.withUnsafeBytes { raw in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(
                        start: raw.baseAddress, count: got
                    ))
                }
                remaining -= Int64(got)
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: Int64(got), cached: false,
                       finished: false, dropped: false, onProgress: onProgress)
            }
            close(fd)
            if Task.isCancelled { return }

            // A short read means the file shrank mid-hash; whatever content
            // it has now, it is not what the size bucket was built from.
            if truncated || remaining > 0 {
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: 0, cached: false,
                       finished: true, dropped: true, onProgress: onProgress)
                continue
            }
            let digest = Array(hasher.finalize())
            state.inner.withLock { $0.digests[job.fileID] = digest }
            cache?.store(
                digest, extent: physical, for: key,
                size: job.size, modTime: job.modTime
            )
            report(state: state, stage: stage, bytesToHash: bytesToHash,
                   jobCount: jobs.count, read: 0, cached: false,
                   finished: true, dropped: false, onProgress: onProgress)
        }
    }

    /// Accumulates counters and forwards a throttled snapshot. The callback
    /// runs outside the lock: it hops to the main actor and must not hold up
    /// the other workers while it does.
    static func report(
        state: HashState,
        stage: Progress.Stage,
        bytesToHash: Int64,
        jobCount: Int,
        read: Int64,
        cached: Bool,
        finished: Bool,
        dropped: Bool,
        onProgress: (@Sendable (Progress) -> Void)?
    ) {
        let snapshot: Progress? = state.inner.withLock { inner in
            inner.bytesHashed += read
            if cached { inner.bytesFromCache += read }
            if finished { inner.filesHashed += 1 }
            if dropped { inner.dropped += 1 }
            guard onProgress != nil else { return nil }
            let now = ContinuousClock.now
            guard now - inner.lastReport > .milliseconds(100) else { return nil }
            inner.lastReport = now
            return Progress(
                stage: stage, bytesHashed: inner.bytesHashed,
                bytesToHash: bytesToHash, filesHashed: inner.filesHashed,
                filesToHash: jobCount
            )
        }
        if let snapshot { onProgress?(snapshot) }
    }

    // MARK: - Assembly

    private static func assemble(
        _ drafts: [Draft], digest: [UInt8], in store: NodeStore,
        extents: [FileID: Int64]
    ) -> Group {
        // Two of these files starting at the same device offset are clones of
        // one another. `⌘D` in the Finder makes one, and nothing short of this
        // measurement tells it from a copy — so without it the group promises
        // bytes that deleting can never return.
        var occupants: [Int64: Int] = [:]
        for draft in drafts {
            if let extent = extents[draft.fileID] {
                occupants[extent, default: 0] += 1
            }
        }
        var storages = drafts.map { draft in
            Storage(
                fileID: draft.fileID,
                nodes: draft.nodes.sorted {
                    keeperRank(of: $0, in: store) < keeperRank(of: $1, in: store)
                },
                linkCount: draft.linkCount,
                allocated: draft.allocated,
                sharedExtent: extents[draft.fileID]
                    .flatMap { (occupants[$0] ?? 0) > 1 ? $0 : nil }
            )
        }
        // The first node of each storage is already its own best, so ranking
        // the storages by it is enough.
        storages.sort { a, b in
            switch (a.nodes.first, b.nodes.first) {
            case let (first?, second?):
                keeperRank(of: first, in: store) < keeperRank(of: second, in: store)
            default:
                false
            }
        }
        return Group(
            digest: digest,
            logicalSize: drafts.first?.size ?? 0,
            storages: storages,
            reclaimableBytes: reclaimableBytes(of: storages)
        )
    }

    /// Upper bound on what deleting all listed copies but one would free.
    ///
    /// Honest arithmetic, not just sum-minus-max: a storage with links outside
    /// the listed paths cannot be freed from here at all. When every storage
    /// is fully listed the user keeps one copy (the largest stays for free);
    /// when some copy survives elsewhere anyway, every listed storage is
    /// deletable. Public because the app re-runs it after hiding copies the
    /// user has already trashed — filtering a list must not mean rehashing.
    public static func reclaimableBytes(of storages: [Storage]) -> Int64 {
        // A storage reachable through a link outside the listed paths survives
        // the deletion regardless, so it can never be freed from here.
        let inScope = storages.filter { $0.nodes.count == $0.linkCount }

        // Clones fold together, the way hard links already fold into a single
        // storage. Shared blocks are released only when the *last* holder goes,
        // so a set of clones is one copy's worth of bytes however many paths
        // point at it — and counting them one by one was what made "keep the
        // odd copy out" report zero when it frees a whole copy.
        var byBlocks: [Int64: Int64] = [:]
        var unique: [Int64] = []
        for storage in inScope {
            if let extent = storage.sharedExtent {
                byBlocks[extent] = storage.allocated
            } else {
                unique.append(storage.allocated)
            }
        }
        let sets = Array(byBlocks.values) + unique

        if inScope.count == storages.count {
            return sets.reduce(0, +) - (sets.max() ?? 0)
        }
        return sets.reduce(0, +)
    }

    /// Which copy is the obvious one to keep: newest first, then the path
    /// nearest the root, then alphabetical.
    ///
    /// A date alone is not an order. `cp -p` gives two copies the very same
    /// second, and a directory's date after `rollUp` is the newest anywhere in
    /// its subtree, so two copies of a folder are routinely stamped
    /// identically. The winner was then whichever worker happened to reach the
    /// file first, and « Conservée » moved between two runs on a disk nothing
    /// had touched. Depth and path settle it the same way every time.
    ///
    /// Shared with the folder pass, which ranks folder copies by the same rule.
    static func keeperRank(
        of node: Int32, in store: NodeStore
    ) -> (Int64, Int, String) {
        // Negated in Int64: a pre-1970 date is a negative Int32 and negating
        // Int32.min in place would trap.
        (-Int64(store.modTime[Int(node)]), store.depth(of: node), store.path(of: node))
    }
}
