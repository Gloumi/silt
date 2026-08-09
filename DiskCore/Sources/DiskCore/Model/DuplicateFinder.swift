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
        /// Nodes sharing this inode, newest modification first.
        public var nodes: [Int32]
        /// `st_nlink` at hash time. `nodes.count < linkCount` means links
        /// exist outside the scanned subtree: deleting every path listed here
        /// still leaves the bytes on disk.
        public var linkCount: Int
        /// On-disk bytes, taken from the store rather than re-measured so the
        /// figure matches what every other view shows for the same file.
        public var allocated: Int64
    }

    /// Files whose content hashed identical. Always at least two storages.
    public struct Group: Sendable {
        /// SHA-256 of the full content (or of the whole file when it fits in
        /// the prefix). Kept for tests and debugging, not shown to the user.
        public var digest: [UInt8]
        public var logicalSize: Int64
        /// Sorted newest first, so "keep the most recent" is index zero.
        public var storages: [Storage]
        /// Upper bound on what deleting all copies but one would free. A
        /// storage with links outside the subtree contributes nothing — its
        /// bytes survive the deletion regardless.
        public var reclaimableBytes: Int64
    }

    public struct Result: Sendable {
        /// Sorted by descending `reclaimableBytes`.
        public var groups: [Group]
        /// Candidate files that entered the hashing pipeline.
        public var candidateCount: Int
        /// Total bytes read across both passes.
        public var bytesHashed: Int64
        /// Candidates silently dropped: vanished, changed size, or unreadable
        /// between the scan and the hash. Normal life, not an error.
        public var droppedCount: Int
    }

    public struct Progress: Sendable {
        public enum Stage: Sendable { case collecting, prefixPass, fullPass }
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
            return Result(groups: [], candidateCount: 0, bytesHashed: 0, droppedCount: 0)
        }
        onProgress?(Progress(
            stage: .collecting, bytesHashed: 0, bytesToHash: 0,
            filesHashed: 0, filesToHash: 0
        ))

        // ---- Phase 0: size buckets, free because the scan measured everything.
        guard let collected = collect(in: store, under: root, options: options)
        else { return nil }
        let candidateCount = collected.buckets.values.reduce(0) { $0 + $1.count }
        var dropped = 0
        var totalHashed: Int64 = 0

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
            onProgress: onProgress
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
                    groups.append(assemble(matching, digest: digest, in: store))
                } else {
                    fullJobs.append(matching)
                }
            }
        }

        // ---- Phase 2: whole-file hash, only where a prefix could not decide.
        guard let fullPass = await hash(
            jobs: fullJobs.flatMap { $0 }, limit: nil,
            workerCount: options.workerCount, stage: .fullPass,
            onProgress: onProgress
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
                groups.append(assemble(matching, digest: digest, in: store))
            }
        }

        groups.sort {
            ($0.reclaimableBytes, $0.logicalSize) > ($1.reclaimableBytes, $1.logicalSize)
        }
        return Result(
            groups: groups,
            candidateCount: candidateCount,
            bytesHashed: totalHashed,
            droppedCount: dropped
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
        return Collected(buckets: sizes, hardlinkNodes: hardlinkNodes)
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
    private struct Draft: Sendable {
        var fileID: FileID
        var nodes: [Int32]
        var linkCount: Int
        var allocated: Int64
        var size: Int64
        var path: String
    }

    private struct HashPass {
        var digests: [FileID: [UInt8]]
        var bytesRead: Int64
        var dropped: Int
    }

    /// All shared mutable state of a hashing pass behind one lock, following
    /// `ScanEngine`'s pattern. The lock is taken per chunk, not per byte, and
    /// hashing itself happens outside it.
    private final class HashState: Sendable {
        struct Inner {
            var nextJob = 0
            var bytesHashed: Int64 = 0
            var filesHashed = 0
            var dropped = 0
            var digests: [FileID: [UInt8]] = [:]
            var lastReport: ContinuousClock.Instant
        }
        let inner: Mutex<Inner>
        init() { inner = Mutex(Inner(lastReport: .now)) }
    }

    private static func hash(
        jobs: [Draft],
        limit: Int?,
        workerCount: Int,
        stage: Progress.Stage,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async -> HashPass? {
        guard !jobs.isEmpty else {
            return HashPass(digests: [:], bytesRead: 0, dropped: 0)
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
                        bytesToHash: bytesToHash, onProgress: onProgress
                    )
                }
            }
        }
        if Task.isCancelled { return nil }
        return state.inner.withLock {
            HashPass(digests: $0.digests, bytesRead: $0.bytesHashed, dropped: $0.dropped)
        }
    }

    private static func hashWorker(
        jobs: [Draft],
        limit: Int?,
        state: HashState,
        stage: Progress.Stage,
        bytesToHash: Int64,
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

            // O_NOFOLLOW as defense in depth: the node was a regular file at
            // scan time and at stat time, but the path could have been swapped
            // for a symlink since.
            let fd = open(job.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: 0, finished: true,
                       dropped: true, onProgress: onProgress)
                continue
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
                       jobCount: jobs.count, read: Int64(got), finished: false,
                       dropped: false, onProgress: onProgress)
            }
            close(fd)
            if Task.isCancelled { return }

            // A short read means the file shrank mid-hash; whatever content
            // it has now, it is not what the size bucket was built from.
            if truncated || remaining > 0 {
                report(state: state, stage: stage, bytesToHash: bytesToHash,
                       jobCount: jobs.count, read: 0, finished: true,
                       dropped: true, onProgress: onProgress)
                continue
            }
            let digest = Array(hasher.finalize())
            state.inner.withLock { $0.digests[job.fileID] = digest }
            report(state: state, stage: stage, bytesToHash: bytesToHash,
                   jobCount: jobs.count, read: 0, finished: true,
                   dropped: false, onProgress: onProgress)
        }
    }

    /// Accumulates counters and forwards a throttled snapshot. The callback
    /// runs outside the lock: it hops to the main actor and must not hold up
    /// the other workers while it does.
    private static func report(
        state: HashState,
        stage: Progress.Stage,
        bytesToHash: Int64,
        jobCount: Int,
        read: Int64,
        finished: Bool,
        dropped: Bool,
        onProgress: (@Sendable (Progress) -> Void)?
    ) {
        let snapshot: Progress? = state.inner.withLock { inner in
            inner.bytesHashed += read
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
        _ drafts: [Draft], digest: [UInt8], in store: NodeStore
    ) -> Group {
        var storages = drafts.map { draft in
            Storage(
                fileID: draft.fileID,
                nodes: draft.nodes.sorted {
                    store.modTime[Int($0)] > store.modTime[Int($1)]
                },
                linkCount: draft.linkCount,
                allocated: draft.allocated
            )
        }
        storages.sort { newestTime($0, in: store) > newestTime($1, in: store) }
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
        let inScope = storages.filter { $0.nodes.count == $0.linkCount }
        if inScope.count == storages.count {
            let total = storages.reduce(Int64(0)) { $0 + $1.allocated }
            let largest = storages.map(\.allocated).max() ?? 0
            return total - largest
        }
        return inScope.reduce(Int64(0)) { $0 + $1.allocated }
    }

    private static func newestTime(_ storage: Storage, in store: NodeStore) -> Int32 {
        storage.nodes.map { store.modTime[Int($0)] }.max() ?? 0
    }
}
