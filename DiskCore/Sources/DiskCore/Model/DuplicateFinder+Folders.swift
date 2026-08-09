import CryptoKit
import Darwin
import Foundation

/// Folders whose entire contents hashed identical.
///
/// What the user actually duplicates is a folder — a photo library copied to
/// the Desktop, a project cloned twice, a backup. Reported as two hundred
/// separate file groups, that information is there and actionable nowhere.
public struct FolderGroup: Sendable {
    /// SHA-256 of the folder's Merkle fingerprint. Never comparable with a
    /// file's digest: the input is length-framed and opens with a domain byte,
    /// so no concatenation of one can imitate the other.
    public var digest: [UInt8]
    /// One node per copy, in `keeperRank` order — newest first, ties broken by
    /// depth then path, so the choice survives a relaunch.
    public var folders: [Int32]
    /// On-disk bytes one copy weighs, counting each inode once.
    public var bytesEach: Int64
    /// Regular files in one copy.
    public var fileCount: Int
    /// Per copy, the bytes deleting *that* copy would actually return.
    public var freeableBytes: [Int32: Int64]
    /// Upper bound on what deleting every copy but one would free.
    public var reclaimableBytes: Int64
}

extension DuplicateFinder {

    /// What the folder pass hands back to `find`.
    struct FolderPass {
        var groups: [FolderGroup]
        var bytesHashed: Int64
        var dropped: Int
    }

    /// The three stages, run in order: free structural buckets, a live read of
    /// each survivor, then content — prefixes first, whole files only where a
    /// prefix could not decide.
    ///
    /// Returns nil when the surrounding task was cancelled.
    static func findFolders(
        in store: NodeStore,
        under root: Int32,
        minimumSize: Int64,
        options: Options,
        cache: DigestCache,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async -> FolderPass? {
        guard let buckets = FolderSignature.candidates(
            in: store, under: root, minimumSize: minimumSize
        ) else { return nil }
        guard !buckets.isEmpty else {
            return FolderPass(groups: [], bytesHashed: 0, dropped: 0)
        }

        // ---- Live read. One manifest object, so a candidate nested inside
        // another candidate re-enumerates nothing.
        let manifest = FolderManifest()
        var dropped = 0
        var sites: [[Site]] = []
        var lastReport = ContinuousClock.now
        onProgress?(Progress(
            stage: .folderScan, bytesHashed: 0, bytesToHash: 0,
            filesHashed: 0, filesToHash: 0
        ))
        for bucket in buckets {
            var read: [Site] = []
            for node in bucket {
                switch manifest.read(path: store.path(of: node)) {
                case .listed(let listing):
                    read.append(Site(node: node, listing: listing))
                case .unreadable:
                    // Fail closed, and say so: the note under the headline
                    // already counts what we refused to judge.
                    dropped += 1
                case .cancelled:
                    return nil
                }
                let now = ContinuousClock.now
                if now - lastReport > .milliseconds(100) {
                    lastReport = now
                    onProgress?(Progress(
                        stage: .folderScan, bytesHashed: 0, bytesToHash: 0,
                        filesHashed: manifest.entriesRead, filesToHash: 0
                    ))
                }
            }
            // A folder whose twin failed to read is alone, and a lone folder
            // is not a duplicate.
            if read.count >= 2 { sites.append(read) }
        }
        guard !sites.isEmpty else {
            return FolderPass(groups: [], bytesHashed: 0, dropped: dropped)
        }

        // ---- Content, in two rounds. The prefix round rejects most false
        // candidates for 128 KiB a file; only what survives it is read whole.
        var bytesHashed: Int64 = 0
        let prefixJobs = jobs(
            for: sites.flatMap { $0 }, in: manifest, above: nil
        )
        guard let prefixPass = await hash(
            jobs: prefixJobs, limit: options.prefixLength,
            workerCount: options.workerCount, stage: .folderCompare,
            cache: cache, onProgress: onProgress
        ) else { return nil }
        bytesHashed += prefixPass.bytesRead

        var survivors: [[Site]] = []
        for bucket in sites {
            let split = regroup(bucket, in: manifest) { entry in
                prefixPass.digests[entry.fileID]
            }
            dropped += split.dropped
            survivors.append(contentsOf: split.buckets)
        }
        guard !survivors.isEmpty else {
            return FolderPass(groups: [], bytesHashed: bytesHashed, dropped: dropped)
        }

        // Only the files a prefix could not cover. A file no larger than the
        // prefix was read whole in the first round, and asking for it again
        // under a different limit would double the work for nothing.
        let limit = Int64(options.prefixLength)
        let fullJobs = jobs(
            for: survivors.flatMap { $0 }, in: manifest, above: limit
        )
        guard let fullPass = await hash(
            jobs: fullJobs, limit: nil,
            workerCount: options.workerCount, stage: .folderCompare,
            cache: cache, onProgress: onProgress
        ) else { return nil }
        bytesHashed += fullPass.bytesRead

        var groups: [FolderGroup] = []
        for bucket in survivors {
            // The one place a prefix digest could be mistaken for a whole-file
            // digest, so the choice is made on the size and nothing else.
            let split = regroup(bucket, in: manifest) { entry in
                entry.size > limit
                    ? fullPass.digests[entry.fileID]
                    : prefixPass.digests[entry.fileID]
            }
            dropped += split.dropped
            for (confirmed, digest) in zip(split.buckets, split.digests) {
                groups.append(assemble(
                    confirmed, digest: digest, in: manifest, store: store
                ))
            }
        }
        groups.sort {
            ($0.reclaimableBytes, $0.bytesEach) > ($1.reclaimableBytes, $1.bytesEach)
        }
        return FolderPass(
            groups: groups, bytesHashed: bytesHashed, dropped: dropped
        )
    }

    /// A candidate folder and the live listing it read into.
    struct Site {
        var node: Int32
        var listing: Int
    }

    // MARK: - Jobs

    /// Every regular file under these folders, deduplicated by inode.
    ///
    /// `above` keeps the second round to the files the prefix could not settle.
    private static func jobs(
        for sites: [Site], in manifest: FolderManifest, above: Int64?
    ) -> [Draft] {
        var drafts: [FileID: Draft] = [:]
        for site in sites {
            walk(site.listing, in: manifest) { listing, entry in
                guard entry.kind == .file else { return }
                if let above, entry.size <= above { return }
                guard drafts[entry.fileID] == nil else { return }
                drafts[entry.fileID] = Draft(
                    fileID: entry.fileID,
                    linkCount: entry.linkCount,
                    allocated: entry.allocated,
                    size: entry.size,
                    modTime: entry.modTime,
                    path: path(of: entry, under: listing, in: manifest)
                )
            }
        }
        return Array(drafts.values)
    }

    private static func path(
        of entry: FolderManifest.Entry, under listing: Int,
        in manifest: FolderManifest
    ) -> String {
        let directory = manifest.path(listing)
        let name = String(decoding: entry.name, as: UTF8.self)
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Every entry under `listing`, breadth unspecified, without recursion.
    private static func walk(
        _ listing: Int, in manifest: FolderManifest,
        _ body: (Int, FolderManifest.Entry) -> Void
    ) {
        var stack = [listing]
        while let index = stack.popLast() {
            guard let current = manifest.listing(index) else { continue }
            for entry in current.entries {
                body(index, entry)
                if entry.kind == .directory { stack.append(entry.listing) }
            }
        }
    }

    // MARK: - The Merkle fingerprint

    /// Splits a bucket by folder digest, keeping only what still has a twin.
    private static func regroup(
        _ sites: [Site], in manifest: FolderManifest,
        digestOf entryDigest: (FolderManifest.Entry) -> [UInt8]?
    ) -> (buckets: [[Site]], digests: [[UInt8]], dropped: Int) {
        var byDigest: [[UInt8]: [Site]] = [:]
        var order: [[UInt8]] = []
        var dropped = 0
        var memo: [Int: [UInt8]] = [:]
        for site in sites {
            guard let digest = compose(
                site.listing, in: manifest, memo: &memo, digestOf: entryDigest
            ) else { dropped += 1; continue }
            if byDigest[digest] == nil { order.append(digest) }
            byDigest[digest, default: []].append(site)
        }
        var buckets: [[Site]] = []
        var digests: [[UInt8]] = []
        for digest in order where (byDigest[digest]?.count ?? 0) >= 2 {
            buckets.append(byDigest[digest]!)
            digests.append(digest)
        }
        return (buckets, digests, dropped)
    }

    /// Domain byte every folder fingerprint opens with, so a folder digest and
    /// a file digest are never built from the same bytes.
    private static let folderDomain: UInt8 = 0xF0

    /// Folds a listing and everything below it into one digest.
    ///
    /// Nil when *any* entry is unresolved, and that is the load-bearing part.
    /// `hash(jobs:)` only reports its successes, so composing around the gaps
    /// would mean two folders whose *same* path is unreadable — by far the
    /// likeliest case, since they are copies and carry the same permissions —
    /// composing the *same* fingerprint from the readable remainder. Silt would
    /// then offer to delete one of them.
    ///
    /// Iterative for the same reason `FolderManifest` is: a deep tree must not
    /// be able to overflow the stack.
    private static func compose(
        _ root: Int, in manifest: FolderManifest,
        memo: inout [Int: [UInt8]],
        digestOf entryDigest: (FolderManifest.Entry) -> [UInt8]?
    ) -> [UInt8]? {
        var stack: [(index: Int, expanded: Bool)] = [(root, false)]
        while let frame = stack.popLast() {
            if memo[frame.index] != nil { continue }
            guard let listing = manifest.listing(frame.index) else { return nil }
            guard frame.expanded else {
                stack.append((frame.index, true))
                for entry in listing.entries
                where entry.kind == .directory && memo[entry.listing] == nil {
                    stack.append((entry.listing, false))
                }
                continue
            }

            var hasher = SHA256()
            hasher.update(byte: folderDomain)
            hasher.update(number: Int64(listing.entries.count))
            for entry in listing.entries {
                // Every field framed by its length, so no name can borrow the
                // bytes of the field beside it and imitate another folder.
                hasher.update(framed: entry.name)
                hasher.update(byte: entry.kind.rawValue)
                switch entry.kind {
                case .file:
                    hasher.update(number: entry.size)
                    guard let digest = entryDigest(entry) else { return nil }
                    hasher.update(framed: digest)
                case .symlink:
                    hasher.update(framed: entry.linkTarget)
                case .directory:
                    guard let digest = memo[entry.listing] else { return nil }
                    hasher.update(framed: digest)
                case .other:
                    break // a fifo is a fifo; there is nothing to read
                }
            }
            memo[frame.index] = Array(hasher.finalize())
        }
        return memo[root]
    }

    // MARK: - What deleting a copy would actually free

    private static func assemble(
        _ sites: [Site], digest: [UInt8],
        in manifest: FolderManifest, store: NodeStore
    ) -> FolderGroup {
        var freeable: [Int32: Int64] = [:]
        var totals: [Int64] = []
        var fileCount = 0

        for site in sites {
            // Deduplicated by inode: two names for one file inside the folder
            // cost its bytes once, and the whole point of the exercise is not
            // to promise space twice.
            var storages: [FileID: (allocated: Int64, here: Int, links: Int)] = [:]
            var directoryBytes: Int64 = 0
            var files = 0
            walk(site.listing, in: manifest) { _, entry in
                switch entry.kind {
                case .file:
                    files += 1
                    var seen = storages[entry.fileID]
                        ?? (entry.allocated, 0, entry.linkCount)
                    seen.here += 1
                    storages[entry.fileID] = seen
                case .directory:
                    directoryBytes += manifest.listing(entry.listing)?
                        .allocated ?? 0
                default:
                    break
                }
            }
            directoryBytes += manifest.listing(site.listing)?.allocated ?? 0

            let total = storages.values.reduce(directoryBytes) { $0 + $1.allocated }
            // Bytes that survive the deletion contribute nothing. A storage
            // with more links than this folder holds is reachable from
            // somewhere else — including, and this is the common case, from
            // the very copy the user is keeping: two folders sharing an inode
            // free four kilobytes between them, not twelve gigabytes.
            let free = storages.values.reduce(directoryBytes) { sum, storage in
                storage.here == storage.links ? sum + storage.allocated : sum
            }
            freeable[site.node] = free
            totals.append(total)
            fileCount = max(fileCount, files)
        }

        let free = sites.map { freeable[$0.node] ?? 0 }
        let folders = sites.map(\.node).sorted {
            keeperRank(of: $0, in: store) < keeperRank(of: $1, in: store)
        }
        return FolderGroup(
            digest: digest,
            folders: folders,
            bytesEach: totals.max() ?? 0,
            fileCount: fileCount,
            freeableBytes: freeable,
            // One copy stays, and the one that frees the most is the one worth
            // keeping for free.
            reclaimableBytes: free.reduce(0, +) - (free.max() ?? 0)
        )
    }
}

// MARK: - Framed hashing

private extension SHA256 {
    mutating func update(byte: UInt8) {
        var value = byte
        withUnsafeBytes(of: &value) { update(bufferPointer: $0) }
    }

    mutating func update(number: Int64) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { update(bufferPointer: $0) }
    }

    /// Length first, then the bytes: two adjacent fields can then never be
    /// re-cut into a different pair that hashes the same.
    mutating func update(framed bytes: [UInt8]) {
        update(number: Int64(bytes.count))
        bytes.withUnsafeBytes { update(bufferPointer: $0) }
    }
}
