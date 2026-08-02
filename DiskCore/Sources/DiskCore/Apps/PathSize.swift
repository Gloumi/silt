import Foundation

/// Size of one path on disk, without building a tree.
///
/// The scan engine answers this for anything it walked, but an application's
/// leftovers are found by name all over `~/Library` and were never part of a
/// scan. This is the same `getattrlistbulk` machinery with no bookkeeping:
/// a few dozen directories, measured once, when a sheet is opened.
public enum PathSize {

    public struct Measurement: Sendable {
        public var allocated: Int64
        public var files: Int32
    }

    /// Walks `path` and sums allocated bytes.
    ///
    /// Symlinks are never followed and hard links are counted once, matching
    /// what the scanner reports so the two numbers can sit side by side.
    public static func measure(_ path: String) -> Measurement {
        var info = stat()
        guard lstat(path, &info) == 0 else { return Measurement(allocated: 0, files: 0) }

        if info.st_mode & S_IFMT != S_IFDIR {
            return Measurement(allocated: Int64(info.st_blocks) * 512, files: 1)
        }

        let reader = DirectoryReader()
        var seen: Set<UInt64> = []
        var total: Int64 = Int64(info.st_blocks) * 512
        var files: Int32 = 0
        // Explicit stack: these trees are shallow, but a symlinked cache can
        // still be deep enough to make recursion a bad bet.
        var stack: [String] = [path]

        while let directory = stack.popLast() {
            guard let fd = try? DirectoryReader.openDirectory(
                directory, followSymlink: directory == path
            ) else { continue }
            defer { close(fd) }

            try? reader.enumerate(fd: fd) { entry in
                guard entry.entryError == 0 else { return }
                let name = String(
                    decoding: entry.nameBytes.prefix(
                        entry.nameBytes.firstIndex(of: 0) ?? entry.nameBytes.count
                    ),
                    as: UTF8.self
                )
                guard name != ".", name != ".." else { return }
                let child = directory + "/" + name

                if entry.isDirectory {
                    total += entry.allocSize
                    stack.append(child)
                    return
                }
                guard !entry.isSymlink else { return }
                if entry.linkCount > 1 {
                    guard seen.insert(entry.fileID).inserted else { return }
                }
                total += entry.allocSize
                files += 1
            }
        }
        return Measurement(allocated: total, files: files)
    }
}
