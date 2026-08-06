import Darwin
import Foundation

/// The APFS container behind a mounted volume, and every volume sharing it.
///
/// A container is the pool; the volumes inside it grow and shrink against one
/// shared free space. On a Mac that means the disk anyone calls "Macintosh HD"
/// is really six volumes — the sealed System, the Data volume everything is
/// written to, and four the user never sees: Preboot, Recovery, VM, Update.
///
/// Those four are why a disk fills up with nothing to show for it. They are
/// hidden from `mountedVolumeURLs`, no firmlink leads to them from `/`, and so
/// no walk of the filesystem — Silt's or anyone else's — can account for a byte
/// of them. On the machine this was written against they hold 38 GB.
public struct APFSContainer: Sendable {
    public let reference: String
    /// The pool's size — the same figure `volumeTotalCapacity` reports for any
    /// volume in it.
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let volumes: [Volume]

    public init(
        reference: String, totalBytes: Int64, freeBytes: Int64, volumes: [Volume]
    ) {
        self.reference = reference
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.volumes = volumes
    }

    /// What the volumes hold, largest first.
    public var usedBytes: Int64 { volumes.reduce(0) { $0 + $1.bytes } }

    /// What no scan can account for: everything outside the two volumes a walk
    /// of the mount point reaches.
    public var unreachableBytes: Int64 {
        volumes.filter { !$0.role.isReachableByScan }.reduce(0) { $0 + $1.bytes }
    }
}

extension APFSContainer {

    public struct Volume: Identifiable, Sendable, Hashable {
        public let deviceIdentifier: String
        public let name: String
        public let role: Role
        /// `CapacityInUse` — what this volume takes out of the shared pool.
        public let bytes: Int64

        public var id: String { deviceIdentifier }

        public init(
            deviceIdentifier: String, name: String, role: Role, bytes: Int64
        ) {
            self.deviceIdentifier = deviceIdentifier
            self.name = name
            self.role = role
            self.bytes = bytes
        }
    }

    /// What macOS uses a volume for. Unknown roles — a future macOS may invent
    /// one — decode as `.none` rather than failing the whole container.
    public enum Role: String, Sendable, Hashable {
        case system, data, preboot, recovery, vm, update, hardware, xart, none

        /// Whether walking the volume's mount point reaches this one.
        ///
        /// Only the sealed System volume and the Data volume firmlinked into it.
        /// Everything else is a sibling in the same pool, invisible to any
        /// directory traversal.
        public var isReachableByScan: Bool { self == .system || self == .data }

        init(diskutil roles: [String]) {
            // Volumes carry at most one role in practice, and a plain data
            // volume — a disk image, a simulator runtime — carries none.
            switch roles.first?.lowercased() {
            case "system": self = .system
            case "data": self = .data
            case "preboot": self = .preboot
            case "recovery": self = .recovery
            case "vm": self = .vm
            case "update": self = .update
            case "hardware": self = .hardware
            case "xart": self = .xart
            default: self = .none
            }
        }
    }

    // MARK: - Reading

    /// Every APFS container on the machine, in one `diskutil` call.
    ///
    /// One subprocess for the whole picture rather than one per volume: the
    /// command costs about a third of a second, and asking it six times to
    /// describe one disk would be six.
    public static func list() -> [APFSContainer] {
        guard let result = Subprocess.run(
            "/usr/sbin/diskutil", ["apfs", "list", "-plist"]
        ), result.status == 0 else { return [] }
        return parse(plist: result.output)
    }

    /// The container behind this mount point, or nil when it is not APFS.
    public static func container(forMountPoint path: String) -> APFSContainer? {
        guard let device = deviceIdentifier(forMountPoint: path) else { return nil }
        return list().first { $0.contains(device: device) }
    }

    /// The bare device name behind a mount point — `disk3s1s1` for `/`.
    ///
    /// `f_mntfromname` is the only place this is published; the container
    /// listing itself carries no mount point at all.
    public static func deviceIdentifier(forMountPoint path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let device = withUnsafeBytes(of: info.f_mntfromname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        guard device.hasPrefix("/dev/") else { return nil }
        return String(device.dropFirst("/dev/".count))
    }

    /// Whether one of this container's volumes backs the given device.
    ///
    /// A prefix test, because `/` is mounted from a *snapshot* of its volume:
    /// `disk3s1s1` is the sealed snapshot of `disk3s1`. The boundary check
    /// matters — without it `disk3s1` would also claim `disk30s1`.
    func contains(device: String) -> Bool {
        volumes.contains { volume in
            device == volume.deviceIdentifier
                || device.hasPrefix(volume.deviceIdentifier + "s")
        }
    }

    // MARK: - Parsing

    /// Decodes `diskutil apfs list -plist`. Visible for testing.
    ///
    /// Anything unreadable yields an empty list rather than a partial one: half
    /// a container's volumes would make the figures fail to add up, and a
    /// breakdown whose lines do not reach the total is worse than none.
    public static func parse(plist data: Data) -> [APFSContainer] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let containers = root["Containers"] as? [[String: Any]]
        else { return [] }

        return containers.compactMap { entry in
            guard let reference = entry["ContainerReference"] as? String,
                  let ceiling = (entry["CapacityCeiling"] as? NSNumber)?.int64Value,
                  ceiling > 0
            else { return nil }

            let volumes = (entry["Volumes"] as? [[String: Any]] ?? [])
                .compactMap(volume(from:))
                .sorted { $0.bytes > $1.bytes }

            return APFSContainer(
                reference: reference,
                totalBytes: ceiling,
                freeBytes: (entry["CapacityFree"] as? NSNumber)?.int64Value ?? 0,
                volumes: volumes
            )
        }
    }

    private static func volume(from entry: [String: Any]) -> Volume? {
        guard let identifier = entry["DeviceIdentifier"] as? String
        else { return nil }
        return Volume(
            deviceIdentifier: identifier,
            // A volume can genuinely have no name — an unformatted one — and
            // its device identifier is then the only thing to call it.
            name: (entry["Name"] as? String) ?? identifier,
            role: Role(diskutil: entry["Roles"] as? [String] ?? []),
            bytes: (entry["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
        )
    }
}
