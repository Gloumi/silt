import Foundation

/// A finished scan in a form that can be written to disk and read back after
/// a relaunch.
///
/// The archive is the `NodeStore`'s parallel arrays laid end to end rather than
/// a `Codable` tree: at a million nodes that is a handful of `memcpy`s on the
/// way out and in, where a per-node encoder would take longer than the scan it
/// saves. Compression and encryption are somebody else's business; this layer
/// only turns a scan into bytes and back.
///
/// Layout, all little-endian: magic, version, metadata, then the eleven arrays
/// each prefixed by its element count.
public struct SavedScan: Sendable {
    public static let formatVersion: UInt32 = 1

    /// The path as the user asked for it, which is what a cached scan is
    /// looked up by. The store's own root name is the resolved path.
    public var rootPath: String
    public var scannedAt: Date
    public var result: ScanResult

    public init(rootPath: String, scannedAt: Date, result: ScanResult) {
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.result = result
    }

    private static let magic: [UInt8] = Array("SILT".utf8)

    // MARK: - Encoding

    public func encoded() -> Data {
        encoded(parent: result.store.parent)
    }

    /// Same archive with one `parent` entry replaced, so a test can hand the
    /// decoder a tree that breaks the invariants without hard-coding byte
    /// offsets.
    func encoded(corruptingParentOf node: Int, with value: Int32) -> Data {
        var parent = result.store.parent
        parent[node] = value
        return encoded(parent: parent)
    }

    private func encoded(parent: [Int32]) -> Data {
        precondition(!result.wasCancelled, "A cancelled scan is partial and must not be saved")
        let store = result.store
        var out = Writer()
        out.bytes(Self.magic)
        out.scalar(Self.formatVersion)
        out.scalar(scannedAt.timeIntervalSince1970.bitPattern)
        out.scalar(Int64(result.filesSeen))
        out.scalar(Int64(result.directoriesSeen))
        out.scalar(result.duration.bitPattern)
        out.string(rootPath)
        out.scalar(UInt32(result.unreadablePaths.count))
        for path in result.unreadablePaths { out.string(path) }

        out.array(store.nameBlob)
        out.array(store.nameOffset)
        out.array(store.nameLength)
        out.array(parent)
        out.array(store.childStart)
        out.array(store.childCount)
        out.array(store.totalAlloc)
        out.array(store.totalLogical)
        out.array(store.fileCount)
        out.array(store.modTime)
        out.array(store.flags.map(\.rawValue))
        return out.data
    }

    // MARK: - Decoding

    /// Nil for anything that is not a well-formed archive of this version.
    ///
    /// The bytes come from disk, so nothing here may trap: every read is
    /// bounds-checked and the tree is validated before a `NodeStore` is built
    /// around it, since the rest of the code indexes those arrays unchecked.
    public init?(decoding data: Data) {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(Self.magic.count) == Self.magic[...],
              reader.scalar(UInt32.self) == Self.formatVersion,
              let scanned = reader.scalar(UInt64.self),
              let filesSeen = reader.scalar(Int64.self),
              let directoriesSeen = reader.scalar(Int64.self),
              let duration = reader.scalar(UInt64.self),
              let rootPath = reader.string(),
              let unreadableCount = reader.scalar(UInt32.self)
        else { return nil }

        var unreadable: [String] = []
        for _ in 0..<unreadableCount {
            guard let path = reader.string() else { return nil }
            unreadable.append(path)
        }

        guard let nameBlob = reader.array(UInt8.self),
              let nameOffset = reader.array(UInt32.self),
              let nameLength = reader.array(UInt16.self),
              let parent = reader.array(Int32.self),
              let childStart = reader.array(Int32.self),
              let childCount = reader.array(Int32.self),
              let totalAlloc = reader.array(Int64.self),
              let totalLogical = reader.array(Int64.self),
              let fileCount = reader.array(Int32.self),
              let modTime = reader.array(Int32.self),
              let rawFlags = reader.array(UInt16.self),
              reader.isAtEnd,
              let store = NodeStore(
                validating: nameBlob, nameOffset: nameOffset,
                nameLength: nameLength, parent: parent,
                childStart: childStart, childCount: childCount,
                totalAlloc: totalAlloc, totalLogical: totalLogical,
                fileCount: fileCount, modTime: modTime,
                flags: rawFlags.map(NodeFlags.init(rawValue:))
              )
        else { return nil }

        self.init(
            rootPath: rootPath,
            scannedAt: Date(timeIntervalSince1970: Double(bitPattern: scanned)),
            result: ScanResult(
                store: store,
                unreadablePaths: unreadable,
                filesSeen: Int(filesSeen),
                directoriesSeen: Int(directoriesSeen),
                duration: Double(bitPattern: duration)
            )
        )
    }
}

// MARK: - Byte plumbing

private struct Writer {
    var data = Data()

    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }

    mutating func scalar<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        scalar(UInt32(utf8.count))
        bytes(utf8)
    }

    /// Element count, then the elements. Apple platforms are all
    /// little-endian, so the in-memory layout of the array is the file layout.
    mutating func array<T: FixedWidthInteger>(_ a: [T]) {
        scalar(UInt64(a.count))
        a.withUnsafeBytes { data.append(contentsOf: $0) }
    }
}

private struct Reader {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { position == bytes.count }

    mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard n >= 0, n <= bytes.count - position else { return nil }
        defer { position += n }
        return bytes[position..<(position + n)]
    }

    mutating func scalar<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard let slice = take(MemoryLayout<T>.size) else { return nil }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: slice) }
        return T(littleEndian: value)
    }

    mutating func string() -> String? {
        guard let length = scalar(UInt32.self),
              let slice = take(Int(length))
        else { return nil }
        return String(validating: slice, as: UTF8.self)
    }

    /// The count is checked against what is actually left before anything is
    /// allocated, so a corrupt header cannot ask for gigabytes.
    mutating func array<T: FixedWidthInteger>(_: T.Type) -> [T]? {
        guard let count = scalar(UInt64.self),
              count <= UInt64(bytes.count - position) / UInt64(MemoryLayout<T>.size),
              let slice = take(Int(count) * MemoryLayout<T>.size)
        else { return nil }
        var result = [T](repeating: 0, count: Int(count))
        result.withUnsafeMutableBytes { $0.copyBytes(from: slice) }
        return result
    }
}
