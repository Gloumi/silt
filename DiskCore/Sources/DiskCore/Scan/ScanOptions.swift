import Foundation

public struct ScanOptions: Sendable {
    /// Descend into bundles (`.app`, `.photoslibrary`…). Off by default, which
    /// matches how Finder presents them.
    public var descendIntoPackages: Bool = false

    /// Directories whose contents are summed but given no individual nodes.
    /// Their total still counts; only the per-file detail is dropped, which is
    /// what keeps a `node_modules`-heavy home directory from producing millions
    /// of nodes nobody will ever look at.
    public var collapsedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".svn", "vendor", ".venv", "venv",
        "Pods", ".gradle", ".terraform",
    ]

    /// Never descend into another mounted volume.
    public var stayOnOneVolume: Bool = true

    /// Follow firmlinks, which is what makes scanning `/` mean what a user
    /// expects it to mean.
    ///
    /// Since Catalina the boot disk is two volumes: a read-only system volume
    /// mounted at `/` (~11 GB) and a data volume holding everything else
    /// (~450 GB). They are stitched together by firmlinks — `/Users`,
    /// `/Applications`, `/Library`, `/private`… all live on the data volume
    /// (`/usr/share/firmlinks` is the authoritative list). Refusing to cross
    /// them makes a scan of `/` report only the system volume, which is both
    /// technically defensible and completely useless.
    ///
    /// Crossing them does not double-count: the data volume's own mount point,
    /// `/System/Volumes/Data`, is a plain mount point rather than a firmlink,
    /// so `stayOnOneVolume` still keeps us out of it.
    public var followFirmlinks: Bool = true

    /// Worker count.
    ///
    /// Scanning is almost pure syscall latency — a single worker spends under
    /// 0.3s of user CPU walking 400k files — so parallelism buys a lot (roughly
    /// 5x from 1 to 4 workers). But it plateaus quickly: past ~6 workers the
    /// wall clock stops improving while system time keeps climbing, so there is
    /// nothing to gain from matching the core count on a big machine.
    public var workerCount: Int = min(
        6, max(4, ProcessInfo.processInfo.activeProcessorCount / 2)
    )

    public init() {}
}

/// Bundle extensions treated as leaves.
let packageExtensions: Set<String> = [
    "app", "photoslibrary", "rtfd", "framework", "bundle", "kext", "plugin",
    "xcodeproj", "xcworkspace", "playground", "pkg", "mpkg", "download",
    "musiclibrary", "tvlibrary", "theater", "logicx", "band", "sparsebundle",
]

public struct ScanProgress: Sendable {
    public var filesSeen: Int = 0
    public var directoriesSeen: Int = 0
    public var bytesSeen: Int64 = 0
    public var currentPath: String = ""
    public var isFinished: Bool = false

    public init(
        filesSeen: Int = 0,
        directoriesSeen: Int = 0,
        bytesSeen: Int64 = 0,
        currentPath: String = "",
        isFinished: Bool = false
    ) {
        self.filesSeen = filesSeen
        self.directoriesSeen = directoriesSeen
        self.bytesSeen = bytesSeen
        self.currentPath = currentPath
        self.isFinished = isFinished
    }
}

public struct ScanResult: Sendable {
    public var store: NodeStore
    /// Directories that could not be opened — almost always TCC (Full Disk
    /// Access) rather than genuine corruption. Their subtrees are missing from
    /// the totals, so the UI must surface this.
    public var unreadablePaths: [String]
    public var filesSeen: Int
    public var directoriesSeen: Int
    public var duration: TimeInterval
    public var wasCancelled: Bool

    public var rootTotalAlloc: Int64 { store.isEmpty ? 0 : store.totalAlloc[0] }
    public var rootTotalLogical: Int64 { store.isEmpty ? 0 : store.totalLogical[0] }
}
