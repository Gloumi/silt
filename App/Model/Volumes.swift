import AppKit
import Foundation

struct VolumeInfo: Identifiable, Hashable {
    let url: URL
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isInternal: Bool

    var id: URL { url }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

enum Volumes {
    static func mounted() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
            .volumeIsInternalKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }
            return VolumeInfo(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(total),
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                isInternal: values.volumeIsInternal ?? false
            )
        }
        .sorted { $0.isInternal && !$1.isInternal }
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
            QuickLocation(
                name: "Applications", path: "/Applications", symbol: "square.grid.2x2"
            ),
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
