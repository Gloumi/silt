import Darwin
import Foundation

/// How many files of each exact size live under a root, and therefore what any
/// duplicates threshold would actually cost.
///
/// Walked once, questioned as often as the slider moves. That is the whole
/// point of keeping a histogram rather than a count: the answer for *every*
/// threshold falls out of one pass, so the control can stay honest while it is
/// being dragged instead of only after the pass has run and the time is spent.
///
/// The cost curve is the thing a threshold hides. Halving it does not halve the
/// work: small sizes collide far more often — thousands of files land on
/// exactly 4 096 bytes — so the candidate count climbs much faster than the
/// file count, and below the prefix length each candidate is read whole rather
/// than capped. A user dragging towards the floor has no way to know that, and
/// this is what tells them.
public enum SizeCensus {

    public struct Result: Sendable {
        /// Logical size in bytes → how many regular files have exactly it.
        /// Only sizes seen at least twice are kept: a size no other file shares
        /// can never produce a candidate, and dropping them keeps the table
        /// small enough to hold on to.
        public var shared: [Int64: Int32]
        /// Every regular file walked, whatever its size.
        public var filesSeen: Int
        /// Where it was measured, for the label.
        public var root: String
        /// True when the walk was cut short — the figures are a floor, not an
        /// estimate.
        public var wasCancelled: Bool

        public init(
            shared: [Int64: Int32], filesSeen: Int,
            root: String, wasCancelled: Bool
        ) {
            self.shared = shared
            self.filesSeen = filesSeen
            self.root = root
            self.wasCancelled = wasCancelled
        }

        /// Files that would enter the hashing pipeline at this threshold: at or
        /// above it, and sharing their exact size with at least one other file.
        ///
        /// This is what `DuplicateFinder.collect` builds its buckets from, so
        /// the figure is the real one rather than "files above the threshold",
        /// which on a disk of unique sizes would overstate it several-fold.
        public func candidates(above threshold: Int64) -> Int {
            var total = 0
            for (size, count) in shared where size >= threshold {
                total += Int(count)
            }
            return total
        }

        /// Bytes the first pass would read for them. Below the prefix length a
        /// file is read whole, which is why the byte curve flattens while the
        /// syscall curve — the one that actually decides how long this takes —
        /// keeps climbing.
        public func bytesToRead(
            above threshold: Int64, prefixLength: Int
        ) -> Int64 {
            var total: Int64 = 0
            for (size, count) in shared where size >= threshold {
                total += Int64(count) * min(size, Int64(prefixLength))
            }
            return total
        }
    }

    // MARK: - From a tree already in memory

    /// Free when a scan is loaded: every size is already in the store.
    public static func measure(
        in store: NodeStore, under root: Int32
    ) -> Result {
        var counts: [Int64: Int32] = [:]
        var filesSeen = 0
        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            let index = Int(node)
            let flags = store.flags[index]
            if flags.contains(.deleted) { continue }
            if flags.contains(.directory) {
                for child in store.children(of: node) { stack.append(child) }
                continue
            }
            // The same exclusions `collect` applies, or the estimate would
            // promise work that is never done.
            if flags.contains(.symlink) || flags.contains(.unreadable)
                || flags.contains(.hardlinkDuplicate)
                || flags.contains(.dataless) { continue }
            filesSeen += 1
            counts[store.totalLogical[index], default: 0] += 1
        }
        return Result(
            shared: counts.filter { $0.value >= 2 },
            filesSeen: filesSeen,
            root: store.count > 0 ? store.name(of: 0) : "",
            wasCancelled: false
        )
    }

    // MARK: - From the disk

    /// Walks `root` counting sizes and nothing else — no tree, no names, no
    /// paths kept. Far cheaper than a scan, and cheap enough to run behind a
    /// button while the user reads the sentence above it.
    ///
    /// Returns nil only if the root cannot be opened; a cancelled walk comes
    /// back with what it had and says so.
    public static func measure(
        root: String,
        options: ScanOptions = ScanOptions(),
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) -> Result? {
        guard let resolved = realpath(root, nil) else { return nil }
        let rootPath = String(cString: resolved)
        free(resolved)

        var info = stat()
        guard lstat(rootPath, &info) == 0 else { return nil }
        let rootDevice = info.st_dev

        var counts: [Int64: Int32] = [:]
        var filesSeen = 0
        var cancelled = false
        // Only inodes with more than one link, so it stays small.
        var seenInodes: Set<InodeKey> = []
        let reader = DirectoryReader()
        var stack: [(path: String, device: Int32)] = [(rootPath, rootDevice)]
        var lastReport = 0

        while let current = stack.popLast() {
            if Task.isCancelled { cancelled = true; break }
            guard let fd = try? DirectoryReader.openDirectory(
                current.path, followSymlink: current.path == rootPath
            ) else { continue }
            var opened = stat()
            let device = fstat(fd, &opened) == 0 ? opened.st_dev : current.device

            try? reader.enumerate(fd: fd) { entry in
                guard entry.nameBytes.count > 0, entry.entryError == 0 else { return }
                let name = entry.nameBytes
                if name.count <= 2, name[0] == UInt8(ascii: ".") {
                    if name.count == 1 { return }
                    if name[1] == UInt8(ascii: ".") { return }
                }
                // Never materialise anything: an evicted file is not a
                // candidate, so it must not be counted as one either.
                if entry.isDataless { return }

                if entry.isDirectory {
                    let childName = String(decoding: name, as: UTF8.self)
                    let crossesFirmlink = entry.isFirmlink && options.followFirmlinks
                    let leaves = !crossesFirmlink
                        && (entry.isMountPoint || entry.isFirmlink
                            || (options.stayOnOneVolume && entry.devID != device))
                    guard !leaves else { return }
                    // Mirrors what the scan would have put in the tree, so the
                    // estimate answers for the pass that will actually run.
                    if !options.descendIntoPackages, isPackageName(childName) { return }
                    if options.collapsedDirectoryNames.contains(childName) { return }
                    stack.append((join(current.path, childName), entry.devID))
                    return
                }
                guard entry.isRegularFile else { return }
                if entry.linkCount > 1 {
                    let key = InodeKey(dev: entry.devID, ino: entry.fileID)
                    guard seenInodes.insert(key).inserted else { return }
                }
                filesSeen += 1
                counts[entry.logicalSize, default: 0] += 1
            }
            close(fd)

            if let onProgress, filesSeen - lastReport >= 5_000 {
                lastReport = filesSeen
                onProgress(filesSeen)
            }
        }

        return Result(
            shared: counts.filter { $0.value >= 2 },
            filesSeen: filesSeen,
            root: rootPath,
            wasCancelled: cancelled
        )
    }

    // MARK: - Helpers

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func isPackageName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return packageExtensions.contains(
            name[name.index(after: dot)...].lowercased()
        )
    }
}
