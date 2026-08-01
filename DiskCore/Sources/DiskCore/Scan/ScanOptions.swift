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

    /// Never leave the volume the scan started on. Without this, scanning `/`
    /// would wander into every mounted disk and double-count firmlinked data.
    public var stayOnOneVolume: Bool = true

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
