import Darwin
import Foundation
import Synchronization

/// Identifies a physical inode, so a file reachable through several hard links
/// is only counted once.
struct InodeKey: Hashable {
    var dev: Int32
    var ino: UInt64
}

private struct WorkItem {
    var node: Int32
    var path: String
    /// Device of this directory as actually opened. Not inherited from the
    /// parent's listing: a firmlink is reported with the *source* volume's
    /// device, so only an fstat on the opened descriptor tells the truth.
    var dev: Int32
}

/// Everything the workers share, behind one lock.
///
/// The lock is taken once per *directory*, never per file: a worker reads a
/// whole directory into thread-local buffers first and only then merges. That
/// keeps contention negligible even with a dozen workers.
private final class ScanState: Sendable {
    struct Inner {
        var store = NodeStore()
        var queue: [WorkItem] = []
        var activeWorkers = 0
        /// Only ever holds inodes whose link count is > 1, so it stays small.
        var seenInodes: Set<InodeKey> = []
        var unreadable: [String] = []
        var filesSeen = 0
        var directoriesSeen = 0
        var bytesSeen: Int64 = 0
        var currentPath = ""
    }

    let mutex = Mutex(Inner())
}

/// A child discovered while reading a directory, before it gets a node index.
private struct PendingChild {
    var nameStart: Int
    var nameCount: Int
    var alloc: Int64
    var logical: Int64
    var files: Int32
    var modified: Int32
    var flags: NodeFlags
    var inode: InodeKey
    var isHardlinkCandidate: Bool
    var descendPath: String?
    var dev: Int32
}

/// Reusable per-worker scratch space, so a scan of a million files does not
/// allocate a million times.
private final class Worker {
    let reader = DirectoryReader()
    var nameBuffer: [UInt8] = []
    var pending: [PendingChild] = []
    /// Inodes seen inside collapsed subtrees, deduplicated later under the lock.
    var collapsedLinks: [InodeKey] = []

    func reset() {
        nameBuffer.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        collapsedLinks.removeAll(keepingCapacity: true)
    }
}

private enum WorkResult {
    case item(WorkItem)
    /// Queue is empty and every worker is idle — the scan is over.
    case finished
    /// Queue is momentarily empty but peers are still producing work.
    case retry
}

public enum ScanEngine {

    /// Walks `root` and returns the fully rolled-up tree.
    ///
    /// Honours task cancellation: the result is still returned, with
    /// `wasCancelled` set and partial totals.
    /// - Parameter snapshot: called periodically with a rolled-up copy of the
    ///   tree built so far, so a UI can draw the result taking shape instead of
    ///   a spinner. Node indices are append-only within one scan, so successive
    ///   snapshots agree about which index means which file.
    public static func scan(
        root: String,
        options: ScanOptions = ScanOptions(),
        progress: (@Sendable (ScanProgress) -> Void)? = nil,
        snapshot: (@Sendable (NodeStore) -> Void)? = nil
    ) async -> ScanResult {
        let started = Date()

        guard let resolvedRoot = resolvePath(root) else {
            return ScanResult(
                store: NodeStore(), unreadablePaths: [root],
                filesSeen: 0, directoriesSeen: 0,
                duration: 0, wasCancelled: false
            )
        }

        var rootStat = stat()
        guard lstat(resolvedRoot, &rootStat) == 0 else {
            return ScanResult(
                store: NodeStore(), unreadablePaths: [resolvedRoot],
                filesSeen: 0, directoriesSeen: 0,
                duration: 0, wasCancelled: false
            )
        }
        let rootDev = rootStat.st_dev

        let state = ScanState()
        state.mutex.withLock { inner in
            inner.store.reserveCapacity(1 << 16)
            let rootIndex = inner.store.append(
                name: Array(resolvedRoot.utf8),
                parent: 0, // the root is its own parent; `path(of:)` relies on it
                alloc: Int64(rootStat.st_blocks) * 512,
                logical: Int64(rootStat.st_size),
                files: 0,
                modified: Int32(clamping: rootStat.st_mtimespec.tv_sec),
                flags: .directory
            )
            inner.queue.append(
                WorkItem(node: rootIndex, path: resolvedRoot, dev: rootDev)
            )
        }

        // Progress is polled rather than pushed: a callback per file would cost
        // more than the scan itself, and the UI only needs ~10 Hz.
        let reporter = (progress != nil || snapshot != nil) ? Task {
            var tick = 0
            while !Task.isCancelled {
                let (counts, partial) = state.mutex.withLock { inner -> (ScanProgress, NodeStore?) in
                    let counts = ScanProgress(
                        filesSeen: inner.filesSeen,
                        directoriesSeen: inner.directoriesSeen,
                        bytesSeen: inner.bytesSeen,
                        currentPath: inner.currentPath,
                        isFinished: false
                    )
                    // Copying the store is a few tens of megabytes, so it runs
                    // at a quarter of the progress rate — often enough to look
                    // live, rare enough not to tax the workers.
                    let wantsTree = snapshot != nil && tick % 4 == 0
                    return (counts, wantsTree ? inner.store : nil)
                }
                progress?(counts)
                if var partial, !partial.isEmpty {
                    // Rolled up outside the lock: it is a linear pass over a
                    // private copy, so the workers keep running meanwhile.
                    partial.rollUp()
                    snapshot?(partial)
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        } : nil

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<options.workerCount {
                group.addTask {
                    let worker = Worker()
                    while true {
                        if Task.isCancelled { return }
                        let next = state.mutex.withLock { inner -> WorkResult in
                            if let item = inner.queue.popLast() {
                                inner.activeWorkers += 1
                                return .item(item)
                            }
                            return inner.activeWorkers == 0 ? .finished : .retry
                        }
                        switch next {
                        case .finished:
                            return
                        case .retry:
                            // Peers are still discovering directories. Yielding
                            // in a tight loop here burns real CPU — measurably
                            // so past ~8 workers — whereas a short sleep costs
                            // nothing and the queue refills within microseconds.
                            try? await Task.sleep(for: .microseconds(200))
                        case .item(let item):
                            processDirectory(
                                item, worker: worker, state: state,
                                options: options
                            )
                            state.mutex.withLock { $0.activeWorkers -= 1 }
                        }
                    }
                }
            }
        }

        reporter?.cancel()
        let cancelled = Task.isCancelled

        var result = state.mutex.withLock { inner -> ScanResult in
            ScanResult(
                store: inner.store,
                unreadablePaths: inner.unreadable,
                filesSeen: inner.filesSeen,
                directoriesSeen: inner.directoriesSeen,
                duration: Date().timeIntervalSince(started),
                wasCancelled: cancelled
            )
        }
        result.store.rollUp()

        if let progress {
            progress(ScanProgress(
                filesSeen: result.filesSeen,
                directoriesSeen: result.directoriesSeen,
                bytesSeen: result.rootTotalAlloc,
                currentPath: "",
                isFinished: true
            ))
        }
        return result
    }

    // MARK: - One directory

    private static func processDirectory(
        _ item: WorkItem,
        worker: Worker,
        state: ScanState,
        options: ScanOptions
    ) {
        let isRoot = item.node == 0
        let fd: Int32
        do {
            fd = try DirectoryReader.openDirectory(item.path, followSymlink: isRoot)
        } catch {
            state.mutex.withLock { inner in
                inner.store.markFlag(.unreadable, on: item.node)
                if inner.unreadable.count < 4096 { inner.unreadable.append(item.path) }
            }
            return
        }
        defer { close(fd) }

        // The device of the directory we actually opened, which for a firmlink
        // is the target volume rather than the one the parent listing claimed.
        var opened = stat()
        let currentDev = fstat(fd, &opened) == 0 ? opened.st_dev : item.dev

        worker.reset()

        do {
            try worker.reader.enumerate(fd: fd) { entry in
                guard entry.nameBytes.count > 0 else { return }
                // getattrlistbulk does not vend "." or "..", but a hostile or
                // exotic filesystem might.
                let name = entry.nameBytes
                if name.count <= 2, name[0] == UInt8(ascii: ".") {
                    if name.count == 1 { return }
                    if name[1] == UInt8(ascii: ".") { return }
                }

                let nameStart = worker.nameBuffer.count
                worker.nameBuffer.append(contentsOf: name)

                var flags = NodeFlags()
                var alloc = entry.allocSize
                var logical = entry.logicalSize
                var files: Int32 = 1
                var modified = Int32(clamping: entry.modTime)
                var descendPath: String?

                if entry.isSymlink {
                    flags.insert(.symlink)
                } else if entry.isDirectory {
                    flags.insert(.directory)
                    files = 0
                    let childName = String(decoding: name, as: UTF8.self)
                    let childPath = join(item.path, childName)

                    if entry.isFirmlink { flags.insert(.firmlink) }
                    if entry.isMountPoint { flags.insert(.mountPoint) }

                    // A firmlink is a seam inside one logical volume, not a
                    // boundary between two; everything else that changes device
                    // is a genuinely separate disk.
                    let crossesFirmlink = entry.isFirmlink && options.followFirmlinks
                    let leavesVolume = !crossesFirmlink
                        && (entry.isMountPoint || entry.isFirmlink
                            || (options.stayOnOneVolume && entry.devID != currentDev))
                    let isPackage = !options.descendIntoPackages
                        && isPackageName(childName)
                    if isPackage { flags.insert(.package) }
                    let isCollapsed =
                        options.collapsedDirectoryNames.contains(childName)

                    if leavesVolume {
                        // Counted as an empty node: its contents belong to
                        // another volume and would be double-counted.
                        flags.insert(.notDescended)
                    } else if isPackage || isCollapsed {
                        flags.insert(.notDescended)
                        let sum = aggregateSubtree(
                            path: childPath, worker: worker,
                            options: options, parentDev: currentDev
                        )
                        alloc += sum.alloc
                        logical += sum.logical
                        files = sum.files
                        // Nothing inside a collapsed directory gets a node, so
                        // `rollUp` has nothing to raise its date with. Without
                        // this a busy node_modules would read as abandoned.
                        modified = max(modified, sum.newestMod)
                    } else {
                        descendPath = childPath
                    }
                } else if !entry.isRegularFile {
                    // Sockets, fifos, devices: they exist, they take no space.
                    files = 1
                }

                if entry.bsdFlags & UF_COMPRESSED_FLAG != 0 {
                    flags.insert(.compressed)
                }
                if entry.isDataless { flags.insert(.dataless) }

                worker.pending.append(PendingChild(
                    nameStart: nameStart,
                    nameCount: name.count,
                    alloc: alloc,
                    logical: logical,
                    files: files,
                    modified: modified,
                    flags: flags,
                    inode: InodeKey(dev: entry.devID, ino: entry.fileID),
                    isHardlinkCandidate: entry.linkCount > 1 && !entry.isDirectory,
                    descendPath: descendPath,
                    dev: entry.devID
                ))
            }
        } catch {
            // Partial read: keep whatever we already collected, but flag it.
            state.mutex.withLock { inner in
                inner.store.markFlag(.unreadable, on: item.node)
                if inner.unreadable.count < 4096 { inner.unreadable.append(item.path) }
            }
        }

        merge(worker: worker, into: state, parent: item.node, parentPath: item.path)
    }

    /// Publishes one directory's children into the shared tree.
    private static func merge(
        worker: Worker, into state: ScanState, parent: Int32, parentPath: String
    ) {
        state.mutex.withLock { inner in
            let start = Int32(inner.store.count)

            // Hard-linked files inside collapsed subtrees were already paid for
            // by the aggregate (deduplicated within that subtree). Register them
            // globally so a later regular file pointing at the same inode is not
            // charged a second time.
            inner.seenInodes.formUnion(worker.collapsedLinks)

            for child in worker.pending {
                var alloc = child.alloc
                var logical = child.logical
                var flags = child.flags

                if child.isHardlinkCandidate {
                    if !inner.seenInodes.insert(child.inode).inserted {
                        // Another link to this inode already paid for the bytes.
                        alloc = 0
                        logical = 0
                        flags.insert(.hardlinkDuplicate)
                    }
                }

                let nameSlice = worker.nameBuffer[
                    child.nameStart..<(child.nameStart + child.nameCount)
                ]
                let index = inner.store.append(
                    name: nameSlice,
                    parent: parent,
                    alloc: alloc,
                    logical: logical,
                    files: child.files,
                    modified: child.modified,
                    flags: flags
                )

                if flags.contains(.directory) {
                    inner.directoriesSeen += 1
                    // Non-zero only for collapsed directories, whose files got
                    // no nodes of their own.
                    inner.filesSeen += Int(child.files)
                } else {
                    inner.filesSeen += 1
                }
                inner.bytesSeen += alloc

                if let path = child.descendPath {
                    inner.queue.append(WorkItem(
                        node: index, path: path, dev: child.dev
                    ))
                }
            }

            inner.store.setChildren(
                of: parent, start: start,
                count: Int32(worker.pending.count)
            )
            inner.currentPath = parentPath
        }
    }

    // MARK: - Collapsed subtrees

    private struct Aggregate {
        var alloc: Int64 = 0
        var logical: Int64 = 0
        var files: Int32 = 0
        /// Newest mtime seen anywhere below, the equivalent of what `rollUp`
        /// does for the parts of the tree that do get nodes.
        var newestMod: Int32 = 0
    }

    /// Sums a subtree without creating any nodes for it.
    ///
    /// Used for `node_modules`, `.git`, bundles… where the total matters but the
    /// per-file breakdown is noise. Note this walks the subtree on the calling
    /// worker, so one very large collapsed directory is handled serially.
    private static func aggregateSubtree(
        path: String, worker: Worker, options: ScanOptions, parentDev: Int32
    ) -> Aggregate {
        var result = Aggregate()
        var stack = [(path: path, dev: parentDev)]
        // A dedicated reader: this runs *inside* the caller's `enumerate`
        // callback, so reusing the worker's reader would overwrite the buffer
        // the caller is still reading from.
        let reader = DirectoryReader()
        // Hard links are common inside collapsed trees (pnpm's store links every
        // package file), so deduplicate within the subtree.
        var localLinks: Set<InodeKey> = []

        while let current = stack.popLast() {
            if Task.isCancelled { return result }
            guard let fd = try? DirectoryReader.openDirectory(
                current.path, followSymlink: false
            ) else { continue }
            defer { close(fd) }
            var opened = stat()
            let dev = fstat(fd, &opened) == 0 ? opened.st_dev : current.dev

            try? reader.enumerate(fd: fd) { entry in
                guard entry.nameBytes.count > 0 else { return }

                // Before the hard-link guard below: a duplicate link pays no
                // bytes, but the file it points at is still activity in here.
                result.newestMod = max(result.newestMod, Int32(clamping: entry.modTime))

                if entry.isDirectory {
                    result.alloc += entry.allocSize
                    result.logical += entry.logicalSize
                    let crossesFirmlink = entry.isFirmlink && options.followFirmlinks
                    let leaves = !crossesFirmlink
                        && (entry.isMountPoint || entry.isFirmlink
                            || (options.stayOnOneVolume && entry.devID != dev))
                    if !leaves {
                        let name = String(decoding: entry.nameBytes, as: UTF8.self)
                        stack.append((join(current.path, name), entry.devID))
                    }
                    return
                }

                result.files += 1
                if entry.linkCount > 1 {
                    let key = InodeKey(dev: entry.devID, ino: entry.fileID)
                    guard localLinks.insert(key).inserted else { return }
                }
                result.alloc += entry.allocSize
                result.logical += entry.logicalSize
            }
        }
        worker.collapsedLinks.append(contentsOf: localLinks)
        return result
    }

    // MARK: - Helpers

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func isPackageName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return packageExtensions.contains(ext)
    }

    private static func resolvePath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
