import DiskCore
import Foundation
import Observation

/// Drives one scan, the navigation through its result, and deletion.
///
/// The engine hands progress and partial trees back from a background task;
/// everything here stays on the main actor so views never observe a torn state.
@MainActor
@Observable
final class ScanModel {

    enum Phase {
        case idle
        case scanning(ScanProgress)
        case loaded
        case failed(String)
    }

    enum Presentation: String, CaseIterable, Identifiable {
        case sunburst, treemap, list, cleanup
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sunburst: "Anneaux"
            case .treemap: "Blocs"
            case .list: "Liste"
            case .cleanup: "Nettoyage"
            }
        }
        var symbol: String {
            switch self {
            case .sunburst: "chart.pie"
            case .treemap: "square.grid.2x2"
            case .list: "list.bullet"
            case .cleanup: "wand.and.sparkles"
            }
        }

        /// Shown on hover: the icons alone do not say what each view is for.
        var hint: String {
            switch self {
            case .sunburst: "Anneaux — vue d'ensemble du dossier"
            case .treemap: "Blocs — surface proportionnelle à la taille"
            case .list: "Liste — éléments triés par taille"
            case .cleanup: "Nettoyage — caches et fichiers récupérables"
            }
        }
    }

    /// Everything the confirmation sheet needs to describe a pending deletion.
    struct DeletionPlan {
        var requests: [SafeDeleter.Request]
        var names: [String]
        var totalBytes: Int64
        var cautions: [String]
        var refused: [String]

        var count: Int { requests.count }
    }

    var presentation: Presentation = .sunburst

    /// Increments once per scan. Node indices only mean anything within a
    /// single store, so anything caching geometry by node must drop it when
    /// this changes.
    private(set) var scanID = 0

    private(set) var phase: Phase = .idle
    /// Held separately from `phase` rather than inside it: deletion mutates the
    /// tree in place, and an enum payload is a poor place to mutate.
    private(set) var result: ScanResult?
    /// Tree built so far, refreshed a few times a second while scanning.
    private(set) var partialStore: NodeStore?

    /// Path from the scan root down to the directory on screen. Always starts
    /// at the root node, so it doubles as the breadcrumb.
    private(set) var trail: [Int32] = [0]
    var selection: Set<Int32> = []

    /// Children of the visible directory, largest first. Stored rather than
    /// computed: a directory can hold six figures of entries and re-sorting on
    /// every view update would be felt.
    private(set) var rows: [Int32] = []

    /// Recoverable space found by the rule engine, recomputed when the tree
    /// changes. Cheap enough (tens of milliseconds) to redo rather than patch.
    private(set) var junkReport: JunkReport?
    var junkSelection: Set<Int32> = []

    /// Set while the confirmation sheet is up.
    var deletionPlan: DeletionPlan? {
        didSet { deletionPlanBox = deletionPlan.map { PlanBox(plan: $0) } }
    }

    /// `sheet(item:)` needs an identity; the plan itself is a plain value.
    struct PlanBox: Identifiable {
        let id = UUID()
        let plan: DeletionPlan
    }
    var deletionPlanBox: PlanBox?
    /// Last successful deletion, kept so it can be undone.
    private(set) var lastDeletion: DeletionReport?
    private(set) var deletionMessage: String?
    /// Sizes captured before deletion; undo needs them to restore the roll-up.
    private var undoSizes: [Int32: (alloc: Int64, logical: Int64, files: Int32)] = [:]

    /// Report sizes as logical bytes rather than bytes on disk.
    var useLogicalSize = false {
        didSet { if useLogicalSize != oldValue { refreshRows() } }
    }

    private var scanTask: Task<Void, Never>?

    var currentNode: Int32 { trail.last ?? 0 }

    /// Whatever tree we can show right now — the finished one, or the partial
    /// one still being built.
    var store: NodeStore? { result?.store ?? partialStore }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    // MARK: - Scanning

    func scan(path: String) {
        scanTask?.cancel()
        trail = [0]
        rows = []
        selection = []
        result = nil
        partialStore = nil
        junkReport = nil
        junkSelection = []
        lastDeletion = nil
        deletionMessage = nil
        scanID += 1
        phase = .scanning(ScanProgress())

        // Built outside the scan task so the engine's callbacks hold their own
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
            let scanned = await ScanEngine.scan(
                root: path, progress: onProgress, snapshot: onSnapshot
            )
            guard let self, !Task.isCancelled else { return }
            if scanned.store.isEmpty {
                phase = .failed("Impossible de lire « \(path) ».")
            } else {
                result = scanned
                partialStore = nil
                phase = .loaded
                refreshJunk()
                // Deliberately not a new scanID: indices are append-only within
                // a scan, so the final tree agrees with the last snapshot and
                // the view settles into it rather than flashing.
                refreshRows()
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        guard isScanning else { return }
        // Keep what was found: a cancelled scan of a huge folder is still worth
        // looking at, and throwing it away would punish an impatient user.
        if let partial = partialStore, !partial.isEmpty {
            result = ScanResult(
                store: partial, unreadablePaths: [],
                filesSeen: 0, directoriesSeen: 0,
                duration: 0, wasCancelled: true
            )
            partialStore = nil
            phase = .loaded
            refreshRows()
        } else {
            phase = .idle
            rows = []
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

    // MARK: - Navigation

    func enter(_ node: Int32) {
        guard let store, store.isDirectory(node), store.childCount[Int(node)] > 0
        else { return }
        trail.append(node)
        selection = []
        refreshRows()
    }

    func goUp() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        selection = []
        refreshRows()
    }

    /// Jumps to a breadcrumb entry, dropping everything below it.
    func goTo(depth: Int) {
        guard depth >= 0, depth < trail.count - 1 else { return }
        trail.removeSubrange((depth + 1)...)
        selection = []
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
        selection = selection.filter { !store.flags[Int($0)].contains(.deleted) }
    }

    // MARK: - Deletion

    /// Builds the plan the confirmation sheet describes. Nothing touches the
    /// filesystem until `confirmDeletion` runs.
    func requestDeletion() {
        guard let store, !selection.isEmpty else { return }
        var plan = DeletionPlan(
            requests: [], names: [], totalBytes: 0, cautions: [], refused: []
        )

        for node in selection.sorted() {
            let path = store.path(of: node)
            let name = store.name(of: node)
            let verdict = DenyList.verdict(for: path)
            if case .forbidden(let reason) = verdict {
                plan.refused.append("\(name) — \(reason)")
                continue
            }
            if case .caution(let reason) = verdict {
                plan.cautions.append("\(name) — \(reason)")
            }
            plan.requests.append(
                .init(node: node, path: path, bytes: store.totalAlloc[Int(node)])
            )
            plan.names.append(name)
            plan.totalBytes += store.totalAlloc[Int(node)]
        }

        guard !plan.requests.isEmpty || !plan.refused.isEmpty else { return }
        deletionPlan = plan
    }

    func confirmDeletion() async {
        guard let plan = deletionPlan, let store else { return }
        deletionPlan = nil

        // Capture sizes first: markDeleted zeroes them, and undo needs them.
        var sizes: [Int32: (alloc: Int64, logical: Int64, files: Int32)] = [:]
        for request in plan.requests {
            let index = Int(request.node)
            sizes[request.node] = (
                store.totalAlloc[index], store.totalLogical[index],
                store.fileCount[index]
            )
        }

        let requests = plan.requests
        let report = await Task.detached { SafeDeleter.moveToTrash(requests) }.value

        for item in report.trashed {
            result?.store.markDeleted(item.node)
        }
        undoSizes = sizes
        lastDeletion = report.trashed.isEmpty ? nil : report
        deletionMessage = summary(of: report)
        selection = []
        junkSelection = []
        refreshRows()
        refreshJunk()
    }

    func undoLastDeletion() async {
        guard let report = lastDeletion else { return }
        let items = report.trashed
        let failures = await Task.detached { SafeDeleter.restore(items) }.value

        let failedPaths = Set(failures.map(\.path))
        for item in items where !failedPaths.contains(item.originalPath) {
            if let sizes = undoSizes[item.node] {
                result?.store.unmarkDeleted(
                    item.node, alloc: sizes.alloc,
                    logical: sizes.logical, files: sizes.files
                )
            }
        }
        lastDeletion = nil
        undoSizes = [:]
        deletionMessage = failures.isEmpty
            ? "Restauration effectuée."
            : "\(failures.count) élément(s) n'ont pas pu être restaurés."
        refreshRows()
        refreshJunk()
    }

    func dismissDeletionMessage() { deletionMessage = nil }

    // MARK: - Cleanup

    private func refreshJunk() {
        guard let store else { junkReport = nil; return }
        junkReport = JunkScanner.scan(store: store)
        let live = Set(junkReport?.findings.map(\.node) ?? [])
        junkSelection = junkSelection.intersection(live)
    }

    func toggleJunk(_ node: Int32) {
        if junkSelection.contains(node) {
            junkSelection.remove(node)
        } else {
            junkSelection.insert(node)
        }
    }

    func selectJunk(_ nodes: [Int32]) {
        // Toggling a whole category off again is the obvious second press.
        if nodes.allSatisfy(junkSelection.contains) {
            junkSelection.subtract(nodes)
        } else {
            junkSelection.formUnion(nodes)
        }
    }

    /// Ticks everything the rules consider regenerable, and nothing that needs
    /// a judgement call.
    func selectSafeJunk() {
        guard let report = junkReport else { return }
        junkSelection = Set(
            report.findings.filter { $0.safety == .safe }.map(\.node)
        )
    }

    func requestJunkDeletion() {
        guard !junkSelection.isEmpty else { return }
        selection = junkSelection
        requestDeletion()
    }

    private func summary(of report: DeletionReport) -> String {
        var parts: [String] = []
        if !report.trashed.isEmpty {
            let bytes = report.reclaimedBytes.formatted(.byteCount(style: .file))
            parts.append(
                "\(report.trashed.count) élément(s) à la corbeille — \(bytes) libérés."
            )
        }
        if !report.refused.isEmpty {
            parts.append("\(report.refused.count) protégé(s).")
        }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) échec(s).")
        }
        return parts.joined(separator: " ")
    }
}
