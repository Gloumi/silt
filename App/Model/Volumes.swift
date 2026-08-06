import AppKit
import Foundation

struct VolumeInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let totalBytes: Int64
    /// Free right now, this instant, without macOS reclaiming anything first.
    let availableBytes: Int64
    /// What the Finder calls "available": the free space plus everything macOS
    /// would purge to make room — caches, the trash, and above all local APFS
    /// snapshots. Always ≥ `availableBytes`.
    let importantBytes: Int64
    /// The stingier figure macOS applies to background downloads: it keeps a
    /// reserve rather than filling the disk on their behalf. Shown in the
    /// tooltip only, but it is the number that explains a download refused on
    /// a disk the Finder calls free.
    let opportunisticBytes: Int64
    let isInternal: Bool

    var id: URL { url }

    /// The space macOS is holding but would give back — the whole reason the
    /// Finder and a file-by-file total never agree.
    var purgeableBytes: Int64 { max(0, importantBytes - availableBytes) }

    /// Below a gigabyte the gap is noise — rounding, a few caches — and saying
    /// so out loud in the sidebar would be alarming about nothing.
    var hasPurgeable: Bool { purgeableBytes >= 1_000_000_000 }

    /// Occupied in the Finder's sense: purgeable space counts as free, because
    /// that is what the row above it announces.
    var usedBytes: Int64 { max(0, totalBytes - importantBytes) }
    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
    var purgeableFraction: Double {
        totalBytes > 0 ? Double(purgeableBytes) / Double(totalBytes) : 0
    }
}

enum Volumes {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
        .volumeIsInternalKey, .volumeIsRootFileSystemKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityForOpportunisticUsageKey,
    ]

    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { info(at: $0, browsableOnly: true) }
            .sorted { $0.isInternal && !$1.isInternal }
    }

    /// One volume, re-read. Used to check what a deletion actually gave back:
    /// APFS frees blocks on its own schedule, so the only honest answer to
    /// "how much did that free" is to look again a moment later.
    static func info(at path: String) -> VolumeInfo? {
        info(at: URL(fileURLWithPath: path), browsableOnly: false)
    }

    private static func info(at url: URL, browsableOnly: Bool) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              !browsableOnly || values.volumeIsBrowsable == true,
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        // The two usage keys are an APFS notion; a disk image, a network share
        // or an HFS+ volume answers zero. Clamping to `available` makes those
        // volumes fall back to exactly the old behaviour — no purgeable space,
        // no second line, no claim we cannot support.
        let important = max(
            available, values.volumeAvailableCapacityForImportantUsage ?? 0
        )
        let opportunistic = max(
            0, values.volumeAvailableCapacityForOpportunisticUsage ?? 0
        )
        return VolumeInfo(
            url: url,
            name: values.volumeName ?? url.lastPathComponent,
            totalBytes: Int64(total),
            availableBytes: available,
            importantBytes: important,
            opportunisticBytes: opportunistic,
            isInternal: values.volumeIsInternal ?? false
        )
    }
}

/// A shortcut offered in the sidebar.
struct QuickLocation: Identifiable, Hashable {
    let name: String
    let path: String
    let symbol: String
    var id: String { path }

    /// The name the Finder shows for a folder, which for the home directory is
    /// the account's own name rather than the generic "Départ".
    static func displayName(of path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.isEmpty ? (path as NSString).lastPathComponent : name
    }

    static func standard() -> [QuickLocation] {
        let home = NSHomeDirectory()
        let candidates = [
            QuickLocation(name: displayName(of: home), path: home, symbol: "house"),
            QuickLocation(
                name: "Téléchargements", path: home + "/Downloads",
                symbol: "arrow.down.circle"
            ),
            QuickLocation(
                name: "Documents", path: home + "/Documents", symbol: "doc"
            ),
            QuickLocation(
                name: "Bureau", path: home + "/Desktop", symbol: "menubar.dock.rectangle"
            ),
            QuickLocation(
                name: "Bibliothèque", path: home + "/Library", symbol: "building.columns"
            ),
            // No /Applications here: the Applications tool covers it, and
            // better — it counts what each app keeps under ~/Library too.
            // Anyone who wants the folder as a tree can still add it by hand.
        ]
        return candidates.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

/// Finder-style icons, cached by file extension rather than by path — a million
/// files share a few hundred types, and `NSWorkspace` lookups are not free.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byExtension: [String: NSImage] = [:]
    private lazy var folderIcon = NSWorkspace.shared.icon(
        for: .folder
    )
    private lazy var genericIcon = NSWorkspace.shared.icon(for: .item)

    func icon(name: String, isDirectory: Bool, isPackage: Bool) -> NSImage {
        if isDirectory && !isPackage { return folderIcon }

        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return isDirectory ? folderIcon : genericIcon }
        if let cached = byExtension[ext] { return cached }

        let icon = NSWorkspace.shared.icon(
            for: .init(filenameExtension: ext) ?? .item
        )
        byExtension[ext] = icon
        return icon
    }
}
