import Darwin
import DiskCore
import Foundation
import Observation

/// Measures what a reboot would free: swap files under /private/var/vm, which
/// only a restart can release, and the user's darwin cache directory, which
/// macOS purges at boot and the app can therefore empty right away.
///
/// Deliberately separate from `ScanModel`: the measurement owes nothing to the
/// scan lifecycle and should survive every one of its resets.
@MainActor
@Observable
final class RebootModel {

    struct SwapFile: Identifiable, Sendable {
        let name: String
        let path: String
        let bytes: Int64
        var id: String { path }
    }

    struct CacheEntry: Identifiable, Sendable {
        /// Folder name, usually a bundle identifier — `com.apple.Safari`.
        let name: String
        let path: String
        let bytes: Int64
        var id: String { path }
    }

    struct Estimate: Sendable {
        var swapFiles: [SwapFile]
        /// Largest first.
        var cacheEntries: [CacheEntry]
        /// Nil when confstr failed, which no healthy system does.
        var cacheDirectory: String?
        /// The cache dir exists but could not be listed.
        var cacheUnreadable: Bool

        var swapBytes: Int64 { swapFiles.reduce(0) { $0 + $1.bytes } }
        var cacheBytes: Int64 { cacheEntries.reduce(0) { $0 + $1.bytes } }
        var totalBytes: Int64 { swapBytes + cacheBytes }
    }

    enum Phase {
        case idle, measuring, ready(Estimate)
    }

    private(set) var phase: Phase = .idle
    /// Ticked cache entries, by path — paths survive a re-measure, indices
    /// would not.
    var selection: Set<String> = []
    private var task: Task<Void, Never>?

    var estimate: Estimate? {
        if case .ready(let estimate) = phase { return estimate }
        return nil
    }

    var isMeasuring: Bool {
        if case .measuring = phase { return true }
        return false
    }

    /// First display: measure once, silently.
    func measureIfNeeded() {
        if case .idle = phase { refresh() }
    }

    /// The refresh button, and every deletion or undo.
    func refresh() {
        task?.cancel()
        // Keep the previous numbers on screen during a re-measure; only the
        // very first run has nothing better to show than a spinner.
        if estimate == nil { phase = .measuring }
        task = Task { [weak self] in
            let measured = await Task.detached { Self.measure() }.value
            guard let self, !Task.isCancelled else { return }
            phase = .ready(measured)
            selection = selection.intersection(measured.cacheEntries.map(\.path))
        }
    }

    func toggle(_ entry: CacheEntry) {
        if selection.contains(entry.path) {
            selection.remove(entry.path)
        } else {
            selection.insert(entry.path)
        }
    }

    var selectedEntries: [CacheEntry] {
        estimate?.cacheEntries.filter { selection.contains($0.path) } ?? []
    }

    var selectedBytes: Int64 {
        selectedEntries.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Measurement

    private nonisolated static func measure() -> Estimate {
        // Swap and the sleep image. /private/var/vm is root-owned but
        // world-listable, and stat needs no read permission — sizes come
        // through without any privilege. SIP keeps the files themselves out
        // of reach: this section is informative only.
        let vm = "/private/var/vm"
        var swap: [SwapFile] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: vm)) ?? []
        for name in names.sorted()
        where name.hasPrefix("swapfile") || name == "sleepimage" {
            let path = vm + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG
            else { continue }
            swap.append(SwapFile(
                name: name, path: path, bytes: Int64(info.st_blocks) * 512
            ))
        }

        // The darwin cache dir's children, each measured with the same
        // machinery the uninstaller uses for leftovers. Empty entries free
        // nothing and are dropped.
        var entries: [CacheEntry] = []
        var unreadable = false
        let cacheDirectory = SystemPaths.darwinUserCache
        if let cacheDirectory {
            if let children = try? FileManager.default
                .contentsOfDirectory(atPath: cacheDirectory) {
                for name in children {
                    let path = cacheDirectory + "/" + name
                    let bytes = PathSize.measure(path).allocated
                    guard bytes > 0 else { continue }
                    entries.append(CacheEntry(name: name, path: path, bytes: bytes))
                }
                entries.sort { $0.bytes > $1.bytes }
            } else {
                unreadable = true
            }
        }

        return Estimate(
            swapFiles: swap, cacheEntries: entries,
            cacheDirectory: cacheDirectory, cacheUnreadable: unreadable
        )
    }
}
