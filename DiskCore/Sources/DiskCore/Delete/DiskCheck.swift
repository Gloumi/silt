import Darwin
import Foundation

/// Re-reads one item from the disk right before it is trashed.
///
/// A scan can now be saved for days, so the path in the tree may name a
/// different file than the one that was measured. The recap would then promise
/// bytes that are not the ones about to leave, or the item may be gone, or
/// have turned from a file into a folder.
public enum DiskCheck {
    public enum Verdict: Equatable, Sendable {
        case unchanged
        /// Still there but no longer what the scan saw; carries the current
        /// allocated size so the recap can be corrected.
        case changed(alloc: Int64)
        /// Absent, or no longer the same kind (file versus folder).
        case missing
    }

    /// `logical` and `modified` are only compared for a file. A folder's size
    /// and date are rolled up from everything below it, so they say nothing
    /// about the folder itself. `logical` is `nil` when the scan did not record
    /// a real size (the extra hard links of an inode are stored as 0 bytes),
    /// and only the date is compared then. `modified` is in Unix seconds,
    /// clamped like `NodeStore.modTime` so an untouched file compares equal.
    public static func verdict(
        path: String, isDirectory: Bool, logical: Int64?, modified: Int32
    ) -> Verdict {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        let isFolderNow = (info.st_mode & S_IFMT) == S_IFDIR
        guard isFolderNow == isDirectory else { return .missing }
        guard !isDirectory else { return .unchanged }

        let date = Int32(clamping: info.st_mtimespec.tv_sec)
        let sizeDiffers = logical.map { Int64(info.st_size) != $0 } ?? false
        if sizeDiffers || date != modified {
            return .changed(alloc: Int64(info.st_blocks) * 512)
        }
        return .unchanged
    }
}
