import Foundation

/// An installed application, as far as its own `Info.plist` describes it.
public struct AppBundle: Sendable {
    public let path: String
    /// Display name without the `.app` extension.
    public let name: String
    public let bundleID: String?
    public let bytes: Int64

    public init(path: String, name: String, bundleID: String?, bytes: Int64) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.bytes = bytes
    }
}

/// How sure we are that a file belongs to the application being removed.
///
/// The whole point of the feature is to sweep widely, and the whole risk is
/// sweeping up a neighbour's data. Rather than choose between the two, every
/// candidate carries how it was matched, and only `certain` is ticked by
/// default.
public enum LeftoverConfidence: Int, Sendable, Comparable, CaseIterable {
    /// Carries the bundle identifier itself. A file called
    /// `com.spotify.client.plist` belongs to exactly one application.
    case certain
    /// Named exactly like the app. Very likely, but two vendors can ship an
    /// app with the same name.
    case probable
    /// Shares the app's name or its vendor prefix. This is where a
    /// same-publisher sibling — Word finding Excel's data — would land.
    case possible

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct Leftover: Sendable, Identifiable {
    public let path: String
    /// Which library folder it came from, for grouping in the UI.
    public let location: String
    public let confidence: LeftoverConfidence
    public let bytes: Int64

    public var id: String { path }
}

/// Finds what an application leaves behind outside its own bundle.
///
/// Everything here is name matching over a fixed list of library folders. It
/// deliberately does not touch the filesystem beyond reading directory listings
/// and sizes — deciding is the user's job, and deleting is `SafeDeleter`'s.
public enum AppUninstaller {

    /// Reads an `.app` bundle. Nil if it is not one, or has no `Info.plist`.
    public static func inspect(appPath: String) -> AppBundle? {
        guard appPath.hasSuffix(".app") else { return nil }
        let plist = appPath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any]
        else { return nil }

        let fallback = (appPath as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
        let name = (info["CFBundleName"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? fallback

        return AppBundle(
            path: appPath,
            name: name,
            bundleID: info["CFBundleIdentifier"] as? String,
            bytes: PathSize.measure(appPath).allocated
        )
    }

    /// Folders macOS applications actually write to, with the label shown in the
    /// UI. Both the user's library and the machine-wide one.
    private static var searchLocations: [(label: String, path: String)] {
        let home = NSHomeDirectory()
        let user: [(String, String)] = [
            ("Application Support", "/Library/Application Support"),
            ("Caches", "/Library/Caches"),
            ("Préférences", "/Library/Preferences"),
            ("Conteneurs", "/Library/Containers"),
            ("Conteneurs de groupe", "/Library/Group Containers"),
            ("État des applications", "/Library/Saved Application State"),
            ("Stockage HTTP", "/Library/HTTPStorages"),
            ("WebKit", "/Library/WebKit"),
            ("Scripts d'application", "/Library/Application Scripts"),
            ("Journaux", "/Library/Logs"),
            ("Cookies", "/Library/Cookies"),
            ("Agents de lancement", "/Library/LaunchAgents"),
        ]
        let system: [(String, String)] = [
            ("Application Support (système)", "/Library/Application Support"),
            ("Préférences (système)", "/Library/Preferences"),
            ("Agents de lancement (système)", "/Library/LaunchAgents"),
            ("Démons de lancement", "/Library/LaunchDaemons"),
        ]
        return user.map { ($0.0, home + $0.1) } + system.map { ($0.0, $0.1) }
    }

    public static func leftovers(for app: AppBundle) -> [Leftover] {
        let manager = FileManager.default
        var found: [Leftover] = []
        var seen: Set<String> = []

        for location in searchLocations {
            guard let entries = try? manager.contentsOfDirectory(
                atPath: location.path
            ) else { continue }

            for entry in entries {
                let path = location.path + "/" + entry
                // The bundle itself is presented separately, never as debris.
                guard path != app.path, !seen.contains(path) else { continue }
                guard let confidence = classify(entry: entry, app: app) else {
                    continue
                }
                seen.insert(path)
                found.append(Leftover(
                    path: path,
                    location: location.label,
                    confidence: confidence,
                    bytes: PathSize.measure(path).allocated
                ))
            }
        }

        // Most certain first, then biggest — the top of the list should be both
        // the safest to remove and the most worth removing.
        return found.sorted {
            $0.confidence == $1.confidence
                ? $0.bytes > $1.bytes
                : $0.confidence < $1.confidence
        }
    }

    /// How an entry name relates to the application, or nil if not at all.
    static func classify(entry: String, app: AppBundle) -> LeftoverConfidence? {
        let stem = (entry as NSString).deletingPathExtension
        let lowerEntry = entry.lowercased()
        let lowerStem = stem.lowercased()

        if let bundleID = app.bundleID?.lowercased(), !bundleID.isEmpty {
            // `com.x.y`, `com.x.y.plist`, `com.x.y.helper`, `com.x.y.savedState`
            if lowerStem == bundleID || lowerEntry == bundleID { return .certain }
            if lowerEntry.hasPrefix(bundleID + ".") { return .certain }
            // Group containers are `group.com.x.y`, sometimes with a suffix.
            if lowerEntry.hasPrefix("group." + bundleID) { return .certain }

            // A same-vendor sibling: `com.spotify.` matches every Spotify
            // product, which is why this is the weakest tier and stays
            // unticked.
            if let vendor = vendorPrefix(of: bundleID),
               lowerEntry.hasPrefix(vendor) {
                return .possible
            }
        }

        // Names are only discriminating once they are long enough. "Go", "X" or
        // "Notes" as a substring would match half the library.
        let appName = app.name.lowercased()
        guard appName.count >= 4 else { return nil }
        if lowerStem == appName { return .probable }
        if lowerEntry.contains(appName) { return .possible }
        return nil
    }

    /// `com.spotify.client` → `com.spotify.`, the publisher's namespace.
    private static func vendorPrefix(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".") + "."
    }
}
