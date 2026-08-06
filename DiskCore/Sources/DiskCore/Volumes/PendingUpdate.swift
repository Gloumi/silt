import Foundation

/// A macOS update that has been downloaded but not yet installed.
///
/// Worth naming because of how much room one takes and how little of it shows:
/// preparing an update inflates the Preboot volume and rebuilds the System
/// volume beside it, and none of that is visible to a scan. Measured on one
/// machine, a 7,8 GB update grew Preboot by 7,2 GB and the System volume by
/// 5,7 GB.
///
/// **No figure is reported, on purpose.** The packages under `/Library/Updates`
/// can be measured exactly, but they came to under a gigabyte for that same
/// 7,8 GB update — announcing them would invite the reader to conclude the
/// update is small. And the growth that actually matters, the other volumes',
/// can only be seen by comparing against an earlier reading, which an app that
/// has just launched has not got. So this says *that* an update is pending and
/// which volumes it swells, and leaves the arithmetic alone.
public struct PendingUpdate: Sendable {
    /// `softwareupdate` has packages waiting under `/Library/Updates`.
    public let hasDownload: Bool
    /// The next boot's system has been built and is waiting. This is the state
    /// in which the container is at its most swollen.
    public let isStaged: Bool

    public init(hasDownload: Bool, isStaged: Bool) {
        self.hasDownload = hasDownload
        self.isStaged = isStaged
    }
}

extension PendingUpdate {

    /// Where `softwareupdate` leaves what it has downloaded. Root-owned but
    /// world-readable, so this needs no privilege.
    static let downloadDirectory = "/Library/Updates"

    /// The System volume, remounted while macOS builds the next boot's copy of
    /// it. Its presence is the signal that an update is prepared.
    static let stagingMountPoint = "/System/Volumes/Update/mnt1"

    /// Nil when nothing is pending. Only the root volume is probed: these paths
    /// exist nowhere else.
    public static func current(mountPoint: String) -> PendingUpdate? {
        guard mountPoint == "/" else { return nil }
        let update = PendingUpdate(
            hasDownload: !productPaths().isEmpty,
            isStaged: FileManager.default.fileExists(atPath: stagingMountPoint)
        )
        return update.hasDownload || update.isStaged ? update : nil
    }

    /// The product directories `softwareupdate` says are pending.
    ///
    /// Testing `/Library/Updates` for emptiness would be wrong: it always holds
    /// its index, a metadata catalogue and a Rosetta payload, so a Mac with
    /// nothing pending would report an update in progress forever.
    /// `index.plist` is the only thing that says what is genuinely waiting.
    static func productPaths() -> [String] {
        guard let data = FileManager.default.contents(
            atPath: downloadDirectory + "/index.plist"
        ) else { return [] }
        return parseIndex(data)
    }

    /// The `ProductPaths` values of `index.plist`, each a directory name
    /// relative to `/Library/Updates`. Visible for testing.
    static func parseIndex(_ data: Data) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let paths = root["ProductPaths"] as? [String: String]
        else { return [] }
        return paths.values
            .filter { !$0.isEmpty && !$0.contains("/") && $0 != ".." }
            .sorted()
    }
}
