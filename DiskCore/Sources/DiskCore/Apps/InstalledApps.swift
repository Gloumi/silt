import CoreServices
import Foundation

/// The inventory behind the Applications view: what is installed, what each
/// bundle weighs, and what each one keeps outside itself.
///
/// Split from `AppUninstaller` because the costs are different. Uninstalling
/// one app can afford to walk everything twice; listing every app cannot, and
/// the whole point of `leftoverBytes` is to sweep the library folders once for
/// the entire list rather than once per application.
public enum InstalledApps {

    public struct Installed: Sendable, Identifiable {
        public let app: AppBundle
        /// When Spotlight last saw it opened, in Unix seconds. Nil when the
        /// index has nothing to say — never launched, or indexing turned off.
        public let lastUsed: Int32?

        public var id: String { app.path }

        public init(app: AppBundle, lastUsed: Int32?) {
            self.app = app
            self.lastUsed = lastUsed
        }
    }

    /// Where a user installs, and may therefore uninstall.
    ///
    /// `/System/Applications` is deliberately absent: nothing there can be
    /// removed, and listing it would bury the fifty apps that can be under a
    /// hundred that cannot.
    public static var searchDirectories: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// Every application bundle in those directories, measured.
    ///
    /// Measured in parallel, for the reason the scanner documents: this is
    /// syscall latency and nothing else, so a handful of workers buys most of
    /// the win and more buys none of it. Serially, sixty-odd applications —
    /// Xcode among them — take some seven seconds.
    public static func list(
        in directories: [String] = searchDirectories
    ) async -> [Installed] {
        let paths = bundlePaths(in: directories)
        guard !paths.isEmpty else { return [] }
        let workers = min(
            6, max(4, ProcessInfo.processInfo.activeProcessorCount / 2)
        )

        return await withTaskGroup(of: Installed?.self) { group in
            var found: [Installed] = []
            found.reserveCapacity(paths.count)
            var next = 0

            while next < paths.count, next < workers {
                let path = paths[next]
                group.addTask { measure(path) }
                next += 1
            }
            while let result = await group.next() {
                if let result { found.append(result) }
                if next < paths.count, !Task.isCancelled {
                    let path = paths[next]
                    group.addTask { measure(path) }
                    next += 1
                }
            }
            // The group answers in whatever order the disk allows; the caller
            // sorts for display, so this only needs to be stable.
            return found.sorted { $0.app.path < $1.app.path }
        }
    }

    /// The bundles to measure, named but not yet weighed.
    ///
    /// Descends one level into plain folders, and no further: `Utilities` holds
    /// apps, and so does the `Adobe Photoshop 2024` folder an installer makes.
    /// Two levels would start walking into bundles of bundles for nothing.
    ///
    /// Public on its own because it is nearly free — three directory listings —
    /// which is what lets a caller notice that one application has come or gone
    /// without measuring all the others again.
    public static func bundlePaths(
        in directories: [String] = searchDirectories
    ) -> [String] {
        let manager = FileManager.default
        var paths: [String] = []
        var seen: Set<String> = []

        func sweep(_ directory: String, descending: Bool) {
            guard let entries = try? manager.contentsOfDirectory(
                atPath: directory
            ) else { return }

            for entry in entries.sorted() {
                let path = directory + "/" + entry
                if entry.hasSuffix(".app") {
                    if seen.insert(path).inserted { paths.append(path) }
                } else if descending, isDirectory(path) {
                    sweep(path, descending: false)
                }
            }
        }

        for directory in directories { sweep(directory, descending: true) }
        return paths
    }

    /// One bundle: its `Info.plist`, its size on disk, its last known launch.
    public static func measure(_ path: String) -> Installed? {
        guard !Task.isCancelled,
              let app = AppUninstaller.inspect(appPath: path) else { return nil }
        return Installed(app: app, lastUsed: lastUsed(of: path))
    }

    /// What each application keeps outside its own bundle, in one sweep.
    ///
    /// `AppUninstaller.leftovers(for:)` lists all sixteen library folders on
    /// every call; asking it a hundred and fifty times would list them a
    /// hundred and fifty times over for an identical answer. Here they are read
    /// once, then every app is matched against that listing.
    ///
    /// - Parameters:
    ///   - confidence: the weakest match that still counts. The default is the
    ///     only defensible one for a total: `.possible` includes same-publisher
    ///     siblings, so Chrome's preferences would show up inside Android
    ///     Studio's figure — and the number on screen must be the number that
    ///     would actually be freed.
    ///   - onProgress: called with each app's path and total as it is settled,
    ///     so a list can fill in rather than wait.
    /// - Returns: bundle path → bytes held outside the bundle.
    public static func leftoverBytes(
        for apps: [AppBundle],
        upTo confidence: LeftoverConfidence = .certain,
        in locations: [(label: String, path: String)]
            = AppUninstaller.searchLocations,
        onProgress: (@Sendable (String, Int64) -> Void)? = nil
    ) -> [String: Int64] {
        guard !apps.isEmpty else { return [:] }
        let manager = FileManager.default

        // Lowercased here, once per entry, rather than inside the matching loop
        // where it would be paid once per entry *per app*.
        var listings: [(directory: String, entries: [Entry])] = []
        for location in locations {
            guard let names = try? manager.contentsOfDirectory(
                atPath: location.path
            ) else { continue }
            listings.append((location.path, names.map(Entry.init)))
        }

        // Two apps can claim the same path — a shared group container, most
        // often. Measuring it twice would walk the same tree twice.
        var measured: [String: Int64] = [:]
        var totals: [String: Int64] = [:]

        for app in apps {
            if Task.isCancelled { return totals }
            let key = AppUninstaller.Key(app)
            var bytes: Int64 = 0
            var seen: Set<String> = []

            for listing in listings {
                for entry in listing.entries {
                    guard let verdict = AppUninstaller.classify(
                        entry: entry.lower, stem: entry.stem, key: key
                    ), verdict <= confidence else { continue }

                    let path = listing.directory + "/" + entry.name
                    // The bundle is counted on its own, never as debris.
                    guard path != app.path, seen.insert(path).inserted
                    else { continue }

                    if let known = measured[path] {
                        bytes += known
                    } else {
                        let size = PathSize.measure(path).allocated
                        measured[path] = size
                        bytes += size
                    }
                }
            }

            totals[app.path] = bytes
            onProgress?(app.path, bytes)
        }
        return totals
    }

    /// A directory entry with its two folded forms, computed once.
    private struct Entry {
        let name: String
        let lower: String
        let stem: String

        init(_ name: String) {
            self.name = name
            let lower = name.lowercased()
            self.lower = lower
            stem = (lower as NSString).deletingPathExtension
        }
    }

    /// Spotlight's record of the last launch. Nothing else on the system knows
    /// it: the bundle's own dates track the installer, not the user.
    static func lastUsed(of path: String) -> Int32? {
        guard let item = MDItemCreate(nil, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate),
              let date = value as? Date
        else { return nil }
        let seconds = date.timeIntervalSince1970
        guard seconds > 0, seconds < Double(Int32.max) else { return nil }
        return Int32(seconds)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
