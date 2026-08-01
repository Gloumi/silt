import DiskCore
import Foundation
import Observation

/// Drives one scan and the navigation through its result.
///
/// The engine hands progress back from a background task; everything here stays
/// on the main actor so views never observe a torn state.
@MainActor
@Observable
final class ScanModel {

    enum Phase {
        case idle
        case scanning(ScanProgress)
        case loaded(ScanResult)
        case failed(String)
    }

    enum Presentation: String, CaseIterable, Identifiable {
        case sunburst, list
        var id: String { rawValue }
        var label: String { self == .sunburst ? "Anneaux" : "Liste" }
        var symbol: String { self == .sunburst ? "chart.pie" : "list.bullet" }
    }

    var presentation: Presentation = .sunburst

    /// Increments once per scan. Node indices only mean anything within a
    /// single store, so anything caching geometry by node must drop it when
    /// this changes.
    private(set) var scanID = 0

    private(set) var phase: Phase = .idle

    /// Path from the scan root down to the directory on screen. Always starts
    /// at the root node, so it doubles as the breadcrumb.
    private(set) var trail: [Int32] = [0]

    /// Report sizes as logical bytes rather than bytes on disk.
    var useLogicalSize = false {
        didSet { if useLogicalSize != oldValue { refreshRows() } }
    }

    /// Children of the visible directory, largest first. Stored rather than
    /// computed: a directory can hold six figures of entries and re-sorting on
    /// every view update would be felt.
    private(set) var rows: [Int32] = []

    private var scanTask: Task<Void, Never>?

    var currentNode: Int32 { trail.last ?? 0 }

    /// Tree built so far, refreshed a few times a second while scanning.
    private(set) var partialStore: NodeStore?

    /// Whatever tree we can show right now — the finished one, or the partial
    /// one still being built.
    var store: NodeStore? {
        if case .loaded(let result) = phase { return result.store }
        return partialStore
    }

    var result: ScanResult? {
        if case .loaded(let result) = phase { return result }
        return nil
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    // MARK: - Scanning

    func scan(path: String) {
        scanTask?.cancel()
        trail = [0]
        rows = []
        partialStore = nil
        scanID += 1
        phase = .scanning(ScanProgress())

        // Built outside the scan task so the engine's callback holds its own
        // weak reference: capturing the task's `self` binding as well would be
        // a mutable capture, which strict concurrency rejects.
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        let onSnapshot: @Sendable (NodeStore) -> Void = { [weak self] tree in
            Task { @MainActor in self?.apply(partial: tree) }
        }

        // Task inherits this main-actor context, so the completion below is
        // already on the main actor; only the engine's own work is off it.
        scanTask = Task { [weak self] in
            let result = await ScanEngine.scan(
                root: path, progress: onProgress, snapshot: onSnapshot
            )
            guard let self, !Task.isCancelled else { return }
            if result.store.isEmpty {
                phase = .failed("Impossible de lire « \(path) ».")
            } else {
                phase = .loaded(result)
                partialStore = nil
                // Deliberately not a new scanID: indices are append-only within
                // a scan, so the final tree agrees with the last snapshot and
                // the view can settle into it rather than flashing.
                refreshRows()
            }
        }
    }

    private func apply(_ progress: ScanProgress) {
        guard isScanning, !progress.isFinished else { return }
        phase = .scanning(progress)
    }

    private func apply(partial tree: NodeStore) {
        guard isScanning else { return }
        partialStore = tree
        refreshRows()
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            phase = .idle
            rows = []
        }
    }

    // MARK: - Navigation

    func enter(_ node: Int32) {
        guard let store, store.isDirectory(node), store.childCount[Int(node)] > 0
        else { return }
        trail.append(node)
        refreshRows()
    }

    func goUp() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        refreshRows()
    }

    /// Jumps to a breadcrumb entry, dropping everything below it.
    func goTo(depth: Int) {
        guard depth >= 0, depth < trail.count - 1 else { return }
        trail.removeSubrange((depth + 1)...)
        refreshRows()
    }

    // MARK: - Reading

    func size(of node: Int32) -> Int64 {
        guard let store else { return 0 }
        return useLogicalSize
            ? store.totalLogical[Int(node)] : store.totalAlloc[Int(node)]
    }

    private func refreshRows() {
        guard let store else { rows = []; return }
        rows = store.childrenSortedBySize(
            of: currentNode, useLogical: useLogicalSize
        )
    }
}
