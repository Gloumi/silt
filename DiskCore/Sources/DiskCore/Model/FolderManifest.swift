import Darwin
import Foundation

/// What a folder holds *right now*, read off the disk rather than taken from
/// the scanned tree.
///
/// The tree cannot answer this question. Everything else that drifts between a
/// scan and a comparison is caught by the hasher — it `lstat`s again, rechecks
/// the size, reopens by path — but a file *added* since the scan is invisible
/// to all of that. Two folders would then confirm as identical moments before
/// the user sends one of them to the Trash, taking the new file with it. A real
/// directory read is the only thing that sees it.
///
/// The second benefit is that folded folders become comparable at all:
/// `node_modules`, a `.app` bundle, anything the scan deliberately stopped at
/// has no nodes in the tree, and here it is just another directory to read.
///
/// Everything is memoised by directory inode, so a candidate nested inside
/// another candidate costs nothing the second time.
///
/// This is the first code in the project to walk the filesystem outside
/// `ScanEngine`, and it replicates that engine's invariants on purpose: never
/// follow a symlink, never leave the volume, never open anything that is not a
/// regular file. Those three rules are the whole reason this is not twenty
/// lines of `FileManager`.
public final class FolderManifest {

    public enum Kind: UInt8, Sendable {
        case file = 1
        case symlink = 2
        case directory = 3
        /// Fifos, sockets, devices. Recorded — their presence is part of what
        /// makes two folders differ — but never, ever opened. `open()` on a
        /// named pipe with no writer blocks inside the kernel, and
        /// `Task.isCancelled` is only ever tested between blocks: one fifo
        /// would pin a worker until the app quits.
        case other = 4
    }

    public struct Entry: Sendable {
        public var name: [UInt8]
        public var kind: Kind
        /// Logical size of a regular file, zero for everything else.
        public var size: Int64
        /// Bytes this entry costs on disk. Zero for a directory, whose own
        /// blocks are recorded on its `Listing` instead.
        public var allocated: Int64
        /// Storage identity — what the digest cache and the reclaim
        /// arithmetic key on.
        public var fileID: DuplicateFinder.FileID
        /// `st_nlink`. More links than a folder holds means those bytes
        /// survive the folder's deletion.
        public var linkCount: Int
        /// Raw destination bytes of a symlink; empty otherwise. Part of the
        /// identity: two links of the same length pointing elsewhere do not
        /// make the same folder.
        public var linkTarget: [UInt8]
        /// Index into the manifest's listings for a directory; `-1` otherwise.
        public var listing: Int
        /// Last modification, used to validate a cached digest.
        public var modTime: Int64
    }

    public struct Listing: Sendable {
        /// Sorted by raw name bytes. The scan keeps children in whatever order
        /// the filesystem vends them, which differs between two copies of one
        /// folder; a fingerprint has to be built on an order that does not.
        public var entries: [Entry]
        /// The directory's own bytes on disk.
        public var allocated: Int64
    }

    public enum Outcome: Sendable, Equatable {
        case listed(Int)
        /// Something could not be resolved. Deliberately not "whatever we
        /// could read": a folder that fails here is dropped, never confirmed.
        case unreadable
        case cancelled
    }

    /// Nil while a listing is being filled, and for ever after if reading it
    /// failed — a later candidate reaching the same inode fails closed on it.
    private var contents: [Listing?] = []
    private var paths: [String] = []
    private var byInode: [DuplicateFinder.FileID: Int] = [:]
    private let reader = DirectoryReader()

    /// Entries seen across every read, for the progress bar. A folder pass is
    /// bound by syscalls per entry rather than by bytes, so this is the only
    /// honest thing to count while it runs.
    public private(set) var entriesRead = 0

    public init() {}

    public func listing(_ index: Int) -> Listing? {
        index >= 0 && index < contents.count ? contents[index] : nil
    }

    /// Where a listing was first reached. Every path to one inode names the
    /// same directory, so the first is as good as any.
    public func path(_ index: Int) -> String {
        index >= 0 && index < paths.count ? paths[index] : ""
    }

    // MARK: - Reading

    /// Reads `path` and everything below it, memoising as it goes.
    public func read(path: String) -> Outcome {
        guard let opened = openDirectory(path) else { return .unreadable }
        let device = opened.device
        let fileID = opened.fileID
        close(opened.fd)

        if let known = byInode[fileID] {
            return contents[known] == nil ? .unreadable : .listed(known)
        }
        let rootIndex = allocate(fileID: fileID, path: path)

        // Explicit stack, and one descriptor open at a time. Recursion would
        // overflow on a deep tree, and keeping a descriptor per pending
        // directory would run the process out of them on a wide one.
        var stack: [(path: String, index: Int)] = [(path, rootIndex)]
        while let frame = stack.popLast() {
            if let failure = fill(
                frame.index, path: frame.path,
                device: device, pushing: &stack
            ) { return failure }
        }
        return .listed(rootIndex)
    }

    /// Fills one listing. Returns nil on success, or the outcome that ends the
    /// whole read — there is no partial success here by design.
    private func fill(
        _ index: Int,
        path: String,
        device: Int32,
        pushing stack: inout [(path: String, index: Int)]
    ) -> Outcome? {
        guard let opened = openDirectory(path) else { return .unreadable }
        defer { close(opened.fd) }
        // The device of the directory as actually opened, which is the only
        // thing that catches a mount that appeared since the parent listing.
        guard opened.device == device else { return .unreadable }

        var entries: [Entry] = []
        var children: [(path: String, index: Int)] = []
        var failure: Outcome?

        do {
            try reader.enumerate(fd: opened.fd) { raw in
                guard failure == nil else { return }
                let name = Array(raw.nameBytes)
                guard !name.isEmpty else { return }
                // getattrlistbulk does not vend "." or "..", but an exotic
                // filesystem might.
                if name.count <= 2, name[0] == UInt8(ascii: ".") {
                    if name.count == 1 { return }
                    if name[1] == UInt8(ascii: ".") { return }
                }
                self.entriesRead += 1
                if self.entriesRead & 0x3FF == 0, Task.isCancelled {
                    failure = .cancelled
                    return
                }
                // The filesystem told us it could not describe this entry.
                // Composing a fingerprint around the hole is exactly the
                // mistake that would let two folders with the same unreadable
                // path confirm as identical.
                guard raw.entryError == 0 else {
                    failure = .unreadable
                    return
                }

                var entry = Entry(
                    name: name, kind: .other, size: 0,
                    allocated: raw.allocSize,
                    fileID: DuplicateFinder.FileID(
                        device: raw.devID, inode: raw.fileID
                    ),
                    linkCount: Int(raw.linkCount), linkTarget: [],
                    listing: -1, modTime: raw.modTime
                )

                if raw.isDirectory {
                    // `ScanEngine.leavesVolume`, replayed. A mount point here
                    // would send the walk onto another disk: a network share
                    // reads gigabytes over a link no cancellation interrupts,
                    // and ends in a Trash that fails.
                    guard !raw.isMountPoint, !raw.isFirmlink,
                          raw.devID == device
                    else { failure = .unreadable; return }
                    entry.kind = .directory
                    entry.allocated = 0 // carried by the listing instead
                    // A name that is not valid UTF-8 composes a path that will
                    // not resolve, and the open then fails closed. The hasher
                    // works from paths too, so nothing is lost that was not
                    // already lost.
                    let childPath = join(path, String(decoding: name, as: UTF8.self))
                    let reserved = self.reserve(
                        fileID: entry.fileID, path: childPath
                    )
                    entry.listing = reserved.index
                    if reserved.isNew {
                        children.append((childPath, reserved.index))
                    } else if self.contents[reserved.index] == nil {
                        failure = .unreadable // tried before, failed before
                        return
                    }
                } else if raw.isSymlink {
                    entry.kind = .symlink
                    guard let target = self.linkTarget(
                        at: opened.fd, name: name
                    ) else { failure = .unreadable; return }
                    entry.linkTarget = target
                } else if raw.isRegularFile {
                    entry.kind = .file
                    entry.size = raw.logicalSize
                }
                entries.append(entry)
            }
        } catch {
            return .unreadable
        }
        if let failure { return failure }

        entries.sort { $0.name.lexicographicallyPrecedes($1.name) }
        contents[index] = Listing(
            entries: entries, allocated: opened.allocated
        )
        stack.append(contentsOf: children)
        return nil
    }

    // MARK: - Bookkeeping

    private func allocate(fileID: DuplicateFinder.FileID, path: String) -> Int {
        let index = contents.count
        contents.append(nil)
        paths.append(path)
        byInode[fileID] = index
        return index
    }

    /// The index for this inode, allocating one the first time it is seen.
    private func reserve(
        fileID: DuplicateFinder.FileID, path: String
    ) -> (index: Int, isNew: Bool) {
        if let known = byInode[fileID] { return (known, false) }
        return (allocate(fileID: fileID, path: path), true)
    }

    private struct Opened {
        var fd: Int32
        var device: Int32
        var allocated: Int64
        var fileID: DuplicateFinder.FileID
    }

    private func openDirectory(_ path: String) -> Opened? {
        guard let fd = try? DirectoryReader.openDirectory(
            path, followSymlink: false
        ) else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); return nil }
        return Opened(
            fd: fd, device: info.st_dev,
            allocated: Int64(info.st_blocks) * 512,
            fileID: DuplicateFinder.FileID(
                device: info.st_dev, inode: info.st_ino
            )
        )
    }

    /// Where a symlink points, in raw bytes — never resolved, never followed.
    private func linkTarget(at fd: Int32, name: [UInt8]) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let written = withCName(name) { cName in
            buffer.withUnsafeMutableBytes { raw in
                readlinkat(
                    fd, cName,
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }
        }
        // A target that filled the buffer may have been truncated, and a
        // truncated target is not a target.
        guard written >= 0, written < buffer.count else { return nil }
        return Array(buffer[0..<written])
    }

    private func withCName<R>(
        _ name: [UInt8], _ body: (UnsafePointer<CChar>) -> R
    ) -> R {
        var terminated = name
        terminated.append(0)
        return terminated.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(
                to: CChar.self, capacity: buffer.count
            ) { body($0) }
        }
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }
}
