import Darwin

// MARK: - Vnode types (sys/vnode.h)

public enum VType: UInt32 {
    case none = 0, regular = 1, directory = 2, block = 3, character = 4
    case symlink = 5, socket = 6, fifo = 7, bad = 8
}

// MARK: - BSD flags we care about (sys/stat.h)

public let SF_FIRMLINK_FLAG: UInt32 = 0x0080_0000
public let UF_COMPRESSED_FLAG: UInt32 = 0x0000_0020
public let DIR_MNTSTATUS_MNTPOINT_FLAG: UInt32 = 0x0000_0001

/// One directory entry, as handed to the enumeration callback.
///
/// `nameBytes` points into the shared scan buffer and is **only valid for the
/// duration of the callback** — copy it if you need to keep it.
public struct RawEntry {
    public var nameBytes: UnsafeRawBufferPointer
    public var objType: UInt32
    public var fileID: UInt64
    public var devID: Int32
    public var linkCount: UInt32
    /// Bytes actually occupied on disk (all forks). Zero if unsupported.
    public var allocSize: Int64
    /// Logical size (all forks). Zero if unsupported.
    public var logicalSize: Int64
    public var modTime: Int64
    public var bsdFlags: UInt32
    public var mountStatus: UInt32
    /// Per-entry error reported by the filesystem; 0 when fine.
    public var entryError: UInt32

    public var isDirectory: Bool { objType == VType.directory.rawValue }
    public var isRegularFile: Bool { objType == VType.regular.rawValue }
    public var isSymlink: Bool { objType == VType.symlink.rawValue }
    public var isFirmlink: Bool { bsdFlags & SF_FIRMLINK_FLAG != 0 }
    public var isMountPoint: Bool { mountStatus & DIR_MNTSTATUS_MNTPOINT_FLAG != 0 }
}

// MARK: - Attribute list

// Canonical packing order, per getattrlist(2):
//   1. ATTR_CMN_RETURNED_ATTRS is always first.
//   2. ATTR_CMN_ERROR is special-cased to come immediately after it.
//   3. Everything else follows ascending bit order, group by group
//      (common, then dir, then file).
//   4. Every attribute is 4-byte aligned — including 64-bit types, which are
//      therefore *not* padded to 8. Hence the unaligned loads below.

// The C macros import with inconsistent signedness (ATTR_CMN_* as UInt32,
// ATTR_DIR_*/ATTR_FILE_* as Int32), so normalise them once here.
private let aReturned = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
private let aError = attrgroup_t(ATTR_CMN_ERROR)
private let aName = attrgroup_t(ATTR_CMN_NAME)
private let aDevID = attrgroup_t(ATTR_CMN_DEVID)
private let aObjType = attrgroup_t(ATTR_CMN_OBJTYPE)
private let aModTime = attrgroup_t(ATTR_CMN_MODTIME)
private let aFlags = attrgroup_t(ATTR_CMN_FLAGS)
private let aFileID = attrgroup_t(ATTR_CMN_FILEID)

private let aDirMountStatus = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
private let aDirAllocSize = attrgroup_t(ATTR_DIR_ALLOCSIZE)

private let aFileLinkCount = attrgroup_t(ATTR_FILE_LINKCOUNT)
private let aFileTotalSize = attrgroup_t(ATTR_FILE_TOTALSIZE)
private let aFileAllocSize = attrgroup_t(ATTR_FILE_ALLOCSIZE)

private let cmnAttrs: attrgroup_t =
    aReturned | aName | aDevID | aObjType | aModTime | aFlags | aFileID | aError

private let dirAttrs: attrgroup_t = aDirMountStatus | aDirAllocSize

private let fileAttrs: attrgroup_t =
    aFileLinkCount | aFileTotalSize | aFileAllocSize

/// Errors that abort enumeration of a whole directory.
public enum DirectoryReadError: Error {
    case open(errno: Int32)
    case read(errno: Int32)
}

/// Reads a directory's entries in bulk via `getattrlistbulk(2)`.
///
/// One instance owns one reusable buffer, so a scan worker should keep a single
/// reader alive and call `enumerate` for each directory it handles rather than
/// allocating per directory.
public final class DirectoryReader {
    /// 256 KiB holds several thousand entries per syscall on APFS.
    private static let bufferSize = 256 * 1024

    private let buffer: UnsafeMutableRawPointer
    private var attrList: attrlist

    public init() {
        buffer = .allocate(byteCount: Self.bufferSize, alignment: 8)
        attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = cmnAttrs
        attrList.dirattr = dirAttrs
        attrList.fileattr = fileAttrs
    }

    deinit { buffer.deallocate() }

    /// Opens `path` as a directory. `followSymlink` should be true only for the
    /// scan root — during descent we must never traverse a symlink, or a single
    /// `~/link-to-parent` turns the walk into an infinite loop.
    public static func openDirectory(
        _ path: String, followSymlink: Bool
    ) throws -> Int32 {
        var flags = O_RDONLY | O_DIRECTORY
        if !followSymlink { flags |= O_NOFOLLOW }
        let fd = path.withCString { open($0, flags) }
        if fd < 0 { throw DirectoryReadError.open(errno: errno) }
        return fd
    }

    /// Calls `body` once per entry in the directory referenced by `fd`.
    ///
    /// The callback is non-escaping and receives pointers into the internal
    /// buffer, which is overwritten on the next batch.
    public func enumerate(
        fd: Int32, _ body: (RawEntry) throws -> Void
    ) throws {
        while true {
            let count = getattrlistbulk(
                fd, &attrList, buffer, Self.bufferSize, 0
            )
            if count == 0 { return }
            if count < 0 {
                // A directory can vanish mid-scan; the caller decides whether
                // that is fatal.
                throw DirectoryReadError.read(errno: errno)
            }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let entryLength = Int(cursor.loadUnaligned(as: UInt32.self))
                if let entry = Self.parse(cursor) {
                    try body(entry)
                }
                cursor = cursor.advanced(by: entryLength)
            }
        }
    }

    /// Decodes one packed attribute group. Returns nil for entries we can make
    /// no sense of (missing name).
    private static func parse(_ base: UnsafeRawPointer) -> RawEntry? {
        var p = base.advanced(by: 4) // skip the group length

        // ATTR_CMN_RETURNED_ATTRS — tells us which fields are actually present.
        let returned = p.loadUnaligned(as: attribute_set_t.self)
        p = p.advanced(by: MemoryLayout<attribute_set_t>.size)

        let common = returned.commonattr
        let dir = returned.dirattr
        let file = returned.fileattr

        var entry = RawEntry(
            nameBytes: UnsafeRawBufferPointer(start: nil, count: 0),
            objType: 0, fileID: 0, devID: 0, linkCount: 1,
            allocSize: 0, logicalSize: 0, modTime: 0,
            bsdFlags: 0, mountStatus: 0, entryError: 0
        )

        // ATTR_CMN_ERROR is packed immediately after RETURNED_ATTRS, out of
        // bit order — see getattrlistbulk(2).
        if common & aError != 0 {
            entry.entryError = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: 4)
        }

        // From here on, ascending bit order within each group.
        if common & aName != 0 {
            let ref = p.loadUnaligned(as: attrreference_t.self)
            let start = p.advanced(by: Int(ref.attr_dataoffset))
            // attr_length includes the trailing NUL.
            let length = max(0, Int(ref.attr_length) - 1)
            entry.nameBytes = UnsafeRawBufferPointer(start: start, count: length)
            p = p.advanced(by: MemoryLayout<attrreference_t>.size)
        } else {
            return nil
        }
        if common & aDevID != 0 {
            entry.devID = p.loadUnaligned(as: Int32.self)
            p = p.advanced(by: 4)
        }
        if common & aObjType != 0 {
            entry.objType = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: 4)
        }
        if common & aModTime != 0 {
            entry.modTime = p.loadUnaligned(as: Int64.self) // tv_sec
            p = p.advanced(by: MemoryLayout<timespec>.size)
        }
        if common & aFlags != 0 {
            entry.bsdFlags = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: 4)
        }
        if common & aFileID != 0 {
            entry.fileID = p.loadUnaligned(as: UInt64.self)
            p = p.advanced(by: 8)
        }

        if dir & aDirMountStatus != 0 {
            entry.mountStatus = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: 4)
        }
        if dir & aDirAllocSize != 0 {
            entry.allocSize = p.loadUnaligned(as: Int64.self)
            entry.logicalSize = entry.allocSize
            p = p.advanced(by: 8)
        }

        if file & aFileLinkCount != 0 {
            entry.linkCount = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: 4)
        }
        if file & aFileTotalSize != 0 {
            entry.logicalSize = p.loadUnaligned(as: Int64.self)
            p = p.advanced(by: 8)
        }
        if file & aFileAllocSize != 0 {
            entry.allocSize = p.loadUnaligned(as: Int64.self)
            p = p.advanced(by: 8)
        }

        return entry
    }
}
