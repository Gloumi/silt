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
        let (total, alloc) = sizes(of: path, fallback: info)
        let sizeDiffers = logical.map { total != $0 } ?? false
        if sizeDiffers || date != modified {
            return .changed(alloc: alloc)
        }
        return .unchanged
    }

    /// The two sizes the scanner stores, read the way it reads them.
    ///
    /// `st_size` is the data fork only (the uncompressed size for an
    /// HFS-compressed file), whereas the scan records `ATTR_FILE_TOTALSIZE`
    /// and `ATTR_FILE_ALLOCSIZE`. Comparing the two would flag every file with
    /// a resource fork as modified. Shared with `NodeStore.remeasure`, which
    /// has to give back what the scan recorded for the same reason.
    static func sizes(of path: String, fallback: stat) -> (total: Int64, alloc: Int64) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        // Length, returned-attributes set, then the two sizes.
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW))
        }
        let setSize = MemoryLayout<attribute_set_t>.size
        let expected = MemoryLayout<UInt32>.size + setSize + 16
        let returned = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self) }
        guard status == 0,
              returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
                  == attrgroup_t(ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE),
              buffer.count >= expected
        else {
            return (Int64(fallback.st_size), Int64(fallback.st_blocks) * 512)
        }
        return buffer.withUnsafeBytes {
            (
                $0.loadUnaligned(fromByteOffset: 4 + setSize, as: Int64.self),
                $0.loadUnaligned(fromByteOffset: 12 + setSize, as: Int64.self)
            )
        }
    }
}
