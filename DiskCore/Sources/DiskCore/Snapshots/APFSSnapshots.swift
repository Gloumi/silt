import Darwin
import Foundation

/// A snapshot of an APFS volume, as `diskutil` describes it.
///
/// Snapshots are the usual answer to "I deleted 50 GB and nothing came back":
/// they freeze blocks that the live filesystem has since overwritten, and no
/// walk of the directory tree can see a single one of them.
public struct APFSSnapshot: Identifiable, Sendable, Hashable {

    /// Who made the snapshot, deduced from its name.
    ///
    /// The name is the only reliable signal available without privileges, and
    /// it is a stable contract: Time Machine has stamped its local snapshots
    /// `com.apple.TimeMachine.<date>.local` for as long as they have existed,
    /// and the installer `com.apple.os.update-<hash>`.
    public enum Kind: String, Sendable, Hashable {
        case timeMachine, system, other
    }

    /// The volume this snapshot actually lives on, which on a boot disk is the
    /// Data volume rather than the mount point anyone would name.
    public let mountPoint: String
    public let uuid: String
    public let name: String
    public let xid: UInt64
    /// `diskutil`'s own verdict on whether APFS may reclaim this snapshot.
    public let isPurgeable: Bool
    /// Set on the snapshot that pins the container's minimum size — the one
    /// macOS keeps to be able to roll an update back.
    public let limitsContainerShrink: Bool
    public let kind: Kind
    /// Taken from the name, in local time. Nil for snapshots that carry no date.
    public let date: Date?
    /// The `YYYY-MM-DD-HHMMSS` stamp `tmutil deletelocalsnapshots` expects.
    /// Nil for anything that is not a dated Time Machine snapshot.
    public let stamp: String?
    /// True when `tmutil` also claimed this snapshot, nil when `tmutil` could
    /// not be asked. Informative only — deletability never depends on it, or a
    /// blocked `tmutil` would hide snapshots that plainly exist.
    public let confirmedByTimeMachine: Bool?

    public var id: String { uuid }

    /// Only Time Machine's own snapshots can be removed, and only by date:
    /// `tmutil` is the sole tool that deletes one, and it takes nothing else.
    public var isDeletable: Bool { stamp != nil }

    public init(
        mountPoint: String = "/", uuid: String, name: String, xid: UInt64,
        isPurgeable: Bool, limitsContainerShrink: Bool, kind: Kind, date: Date?,
        stamp: String?, confirmedByTimeMachine: Bool? = nil
    ) {
        self.mountPoint = mountPoint
        self.uuid = uuid
        self.name = name
        self.xid = xid
        self.isPurgeable = isPurgeable
        self.limitsContainerShrink = limitsContainerShrink
        self.kind = kind
        self.date = date
        self.stamp = stamp
        self.confirmedByTimeMachine = confirmedByTimeMachine
    }
}

/// Lists the snapshots of a mounted APFS volume.
///
/// `diskutil` is the source of truth because it sees every snapshot, including
/// the ones the installer leaves behind, and needs no privilege to report them.
/// `tmutil` is consulted only to corroborate; everything the UI needs — type,
/// date, deletability — is derived from the snapshot's name.
public enum APFSSnapshots {

    /// Every snapshot belonging to the disk mounted at `mountPoint`, newest
    /// first — its own and its firmlinked companions'.
    ///
    /// Empty when the volume is not APFS, has none, or `diskutil` failed.
    public static func list(mountPoint: String) -> [APFSSnapshot] {
        var seen: Set<String> = []
        return companions(of: mountPoint)
            .flatMap { snapshots(onMount: $0) }
            .filter { seen.insert($0.uuid).inserted }
            .sorted(by: newestFirst)
    }

    /// The mount points to ask about when someone points at this one.
    ///
    /// Since Catalina the boot disk is two APFS volumes stitched together by
    /// firmlinks: a sealed System volume at `/`, and a Data volume at
    /// /System/Volumes/Data holding everything anyone ever writes. Time Machine
    /// snapshots the Data volume, and `/` never carries one — so asking only
    /// about the mount points the Finder shows finds nothing at all on the one
    /// disk that matters. The Data volume is hidden, which is why enumerating
    /// mounted volumes does not turn it up either.
    ///
    /// An external bootable disk splits the same way, its Data volume mounting
    /// as "<name> - Data".
    public static func companions(of mountPoint: String) -> [String] {
        let candidates = mountPoint == "/"
            ? ["/System/Volumes/Data"]
            : ["\(mountPoint) - Data"]
        return [mountPoint] + candidates.filter(isAPFS(mountPoint:))
    }

    /// Snapshots of one volume, exactly. Nothing firmlinked, nothing merged.
    private static func snapshots(onMount mountPoint: String) -> [APFSSnapshot] {
        guard isAPFS(mountPoint: mountPoint) else { return [] }
        guard let result = Subprocess.run(
            "/usr/sbin/diskutil",
            ["apfs", "listSnapshots", "-plist", mountPoint]
        ), result.status == 0 else { return [] }

        let snapshots = parse(plist: result.output)
        guard !snapshots.isEmpty else { return [] }

        let claimed = timeMachineNames(mountPoint: mountPoint)
        return snapshots.map { snapshot in
            APFSSnapshot(
                mountPoint: mountPoint,
                uuid: snapshot.uuid, name: snapshot.name, xid: snapshot.xid,
                isPurgeable: snapshot.isPurgeable,
                limitsContainerShrink: snapshot.limitsContainerShrink,
                kind: snapshot.kind, date: snapshot.date, stamp: snapshot.stamp,
                confirmedByTimeMachine: claimed.map { $0.contains(snapshot.name) }
            )
        }
    }

    /// Whether the volume mounted here is APFS — snapshots exist nowhere else,
    /// and asking `diskutil` about an HFS+ or SMB mount is a subprocess wasted.
    public static func isAPFS(mountPoint: String) -> Bool {
        var info = statfs()
        guard statfs(mountPoint, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return type == "apfs"
    }

    // MARK: - Parsing

    /// Decodes `diskutil apfs listSnapshots -plist` output. Visible for testing.
    ///
    /// Anything unreadable yields an empty list rather than a partial one: a
    /// malformed plist means we did not understand the volume, and inviting
    /// someone to delete snapshots we only half-recognise is worse than saying
    /// nothing.
    public static func parse(plist data: Data) -> [APFSSnapshot] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let entries = root["Snapshots"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let uuid = entry["SnapshotUUID"] as? String,
                  let name = entry["SnapshotName"] as? String
            else { return nil }
            let stamp = timeMachineStamp(in: name)
            return APFSSnapshot(
                uuid: uuid,
                name: name,
                xid: (entry["SnapshotXID"] as? NSNumber)?.uint64Value ?? 0,
                isPurgeable: entry["Purgeable"] as? Bool ?? false,
                limitsContainerShrink: entry["LimitingContainerShrink"] as? Bool ?? false,
                kind: kind(of: name),
                date: stamp.flatMap(date(fromStamp:)),
                stamp: stamp
            )
        }
    }

    /// The snapshot names `tmutil listlocalsnapshots` reports. Visible for
    /// testing. Nil when `tmutil` could not be run at all, which is a different
    /// thing from a volume with no snapshots.
    public static func parseTimeMachine(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // The first line is a heading — "Snapshots for disk /:" — and the
            // command prints it even when the list below is empty.
            .filter { $0.hasPrefix("com.apple.") }
    }

    static func kind(of name: String) -> APFSSnapshot.Kind {
        if name.hasPrefix("com.apple.TimeMachine.") { return .timeMachine }
        if name.hasPrefix("com.apple.os.update-") { return .system }
        return .other
    }

    /// The date stamp inside `com.apple.TimeMachine.2026-08-05-141530.local`,
    /// or nil for any name that does not carry one in exactly that shape.
    static func timeMachineStamp(in name: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        guard name.hasPrefix(prefix) else { return nil }
        var rest = String(name.dropFirst(prefix.count))
        // Both `.local` and, on some releases, a bare stamp are seen.
        if let dot = rest.firstIndex(of: ".") { rest = String(rest[..<dot]) }
        return isValidStamp(rest) ? rest : nil
    }

    /// `YYYY-MM-DD-HHMMSS` and nothing else.
    ///
    /// This is also the gate that keeps a snapshot name out of the shell: the
    /// deleter refuses any stamp that does not pass here, so no escaping of
    /// user-derived text is ever needed for the date argument.
    public static func isValidStamp(_ stamp: String) -> Bool {
        let groups = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        let lengths = [4, 2, 2, 6]
        for (group, length) in zip(groups, lengths) {
            guard group.count == length,
                  group.allSatisfy({ $0.isASCII && $0.isNumber })
            else { return false }
        }
        return true
    }

    static func date(fromStamp stamp: String) -> Date? {
        // Time Machine names its snapshots in the machine's own time zone, so
        // the reader must be parsed in it too, or every date drifts by the
        // offset from UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }

    // MARK: - Ordering

    /// Newest first, undated snapshots last — an installer snapshot has no date
    /// and belongs at the bottom, under the ones anyone might actually remove.
    private static func newestFirst(_ a: APFSSnapshot, _ b: APFSSnapshot) -> Bool {
        switch (a.date, b.date) {
        case let (x?, y?): return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        // No date on either: the transaction id is monotonic, so it orders them.
        case (nil, nil): return a.xid > b.xid
        }
    }

    private static func timeMachineNames(mountPoint: String) -> [String]? {
        guard let result = Subprocess.run(
            "/usr/bin/tmutil", ["listlocalsnapshots", mountPoint]
        ), result.status == 0,
            let text = String(data: result.output, encoding: .utf8)
        else { return nil }
        return parseTimeMachine(text)
    }
}
