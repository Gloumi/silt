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
        case sunburst, treemap, list, largeFiles, cleanup, reboot
        var id: String { rawValue }

        /// The four ways of looking at the tree. Cleanup and Reboot are not
        /// among them: each is a destination of its own, reached from the
        /// sidebar.
        static let browsing: [Presentation] = [.sunburst, .treemap, .list, .largeFiles]

        /// The three ways of *standing in* a folder. Large files browses the
        /// tree like the others, but it is a flat extract of a whole subtree —
        /// "show me where this lives" needs an actual tree view to land in.
        static let treeViews: [Presentation] = [.sunburst, .treemap, .list]

        /// The two drawn views. They share a palette, so the colour mode means
        /// something in these and nowhere else.
        static let charts: [Presentation] = [.sunburst, .treemap]

        var label: String {
            switch self {
            case .sunburst: "Anneaux"
            case .treemap: "Blocs"
            case .list: "Liste"
            case .largeFiles: "Fichiers volumineux"
            case .cleanup: "Nettoyage"
            case .reboot: "Redémarrage"
            }
        }
        var symbol: String {
            switch self {
            case .sunburst: "chart.pie"
            case .treemap: "square.grid.2x2"
            case .list: "list.bullet"
            case .largeFiles: "doc.text.magnifyingglass"
            case .cleanup: "wand.and.sparkles"
            case .reboot: "restart.circle"
            }
        }

        /// Shown on hover: the icons alone do not say what each view is for.
        var hint: String {
            switch self {
            case .sunburst: "Anneaux — vue d'ensemble du dossier"
            case .treemap: "Blocs — surface proportionnelle à la taille"
            case .list: "Liste — éléments triés par taille"
            case .largeFiles: "Fichiers volumineux — les plus gros du dossier et de ses sous-dossiers"
            case .cleanup: "Nettoyage — caches et fichiers récupérables"
            case .reboot: "Redémarrage — espace qu'un redémarrage libérerait"
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

    var presentation: Presentation = .sunburst {
        didSet {
            if Presentation.treeViews.contains(presentation) {
                lastBrowsingPresentation = presentation
            }
            // Remembered across folders and launches for "Dernière utilisée".
            if Presentation.browsing.contains(presentation),
               Preferences.shared.lastUsedPresentation != presentation {
                Preferences.shared.lastUsedPresentation = presentation
            }
        }
    }
    /// Where "show me where this lives" should land. Cleanup, Reboot and the
    /// large-files extract are lists of findings, not places in the tree, so
    /// none of them can ever be that destination.
    private var lastBrowsingPresentation: Presentation = .sunburst

    init() {
        let initial = Preferences.shared.resolvedDefaultView
        presentation = initial
        // didSet does not fire during init, so the mirror is set by hand.
        // A large-files default still needs a tree view to land in.
        if Presentation.treeViews.contains(initial) {
            lastBrowsingPresentation = initial
        }
    }

    /// Increments once per scan. Node indices only mean anything within a
    /// single store, so anything caching geometry by node must drop it when
    /// this changes.
    private(set) var scanID = 0

    /// Bumped every time the tree's contents change — a scan snapshot, the
    /// final result, a deletion, an undo.
    ///
    /// The visualisations used to key off `rows.count`, which only moves when
    /// the *number* of children changes. A home folder settles on its twenty-odd
    /// entries within the first second while their sizes keep growing for ten
    /// more, so the rings froze almost immediately and only caught up at the end.
    private(set) var treeVersion = 0

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

    /// Contents of an "others" slice the user has stepped into.
    ///
    /// Not part of the trail: an aggregated slice has no node of its own, so it
    /// cannot be an index. It restricts what the visualisations show without
    /// moving where we stand — going up from here simply drops it.
    private(set) var othersScope: [Int32]?

    /// Children of the visible directory, largest first. Stored rather than
    /// computed: a directory can hold six figures of entries and re-sorting on
    /// every view update would be felt.
    private(set) var rows: [Int32] = []

    /// Recoverable space found by the rule engine.
    ///
    /// Computed lazily, the first time the Cleanup view asks for it, and never
    /// as part of finishing a scan: it walks the whole tree, and the end of a
    /// scan is precisely the moment the user is waiting for the first picture.
    private(set) var junkReport: JunkReport?
    private(set) var junkPhase: JunkPhase = .idle
    var junkSelection: Set<Int32> = []
    private var junkTask: Task<Void, Never>?

    enum JunkPhase {
        case idle, running, ready
    }

    /// Biggest files under the directory on screen, largest first.
    ///
    /// Computed lazily when the Files view asks, like the junk report, and for
    /// the same reason: it walks a whole subtree, and that cost belongs to the
    /// view that wants it, never to the end of a scan.
    private(set) var largeFiles: [Int32]?
    private(set) var largeFilesPhase: LargeFilesPhase = .idle
    private var largeFilesTask: Task<Void, Never>?

    enum LargeFilesPhase {
        case idle, running, ready
    }

    /// Everything the large-files extract depends on, folded into one value the
    /// view can key its `.task` on: any change recomputes, anything else does
    /// not. Navigation, deletion, undo and the size toggle all pass through
    /// `refreshRows`, so `treeVersion` carries most of the weight.
    struct LargeFilesKey: Hashable {
        var scanID: Int
        var treeVersion: Int
        var node: Int32
        var useLogical: Bool
        var age: AgeFilter
        var scanning: Bool
    }

    var largeFilesKey: LargeFilesKey {
        LargeFilesKey(
            scanID: scanID, treeVersion: treeVersion,
            node: currentNode, useLogical: useLogicalSize,
            age: largeFilesAgeFilter, scanning: isScanning
        )
    }

    /// How stale a file has to be to make the list at all. Stored in
    /// `Preferences`, like the colour mode and for the same reason.
    var largeFilesAgeFilter: AgeFilter {
        get { Preferences.shared.largeFilesAgeFilter }
        set { Preferences.shared.largeFilesAgeFilter = newValue }
    }

    /// Set while the uninstall sheet is up, and while it is being built.
    var uninstallPlan: UninstallPlan?
    private(set) var uninstallPhase: UninstallPhase = .idle

    enum UninstallPhase {
        case idle, preparing
    }

    /// File currently shown in Quick Look, if any.
    var previewURL: URL?
    /// Full Disk Access explainer, shown once and reachable from the Help menu
    /// and from the warning in the status bar.
    var showsWelcome = !Preferences.shared.hasSeenWelcome

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
    /// Bumped after every confirmed deletion and every undo, so tools that
    /// measure the disk outside the tree know to look again.
    private(set) var deletionEpoch = 0
    private(set) var deletionMessage: String?
    /// A deletion failed because macOS refused to let us touch another app's
    /// bundle — the fix is the « Gestion des apps » toggle in Settings, not a
    /// retry, so the banner grows a button when this is set.
    private(set) var needsAppManagement = false
    /// Sizes captured before deletion; undo needs them to restore the roll-up.
    private var undoSizes: [Int32: (alloc: Int64, logical: Int64, files: Int32)] = [:]

    /// Report sizes as logical bytes rather than bytes on disk.
    var useLogicalSize = Preferences.shared.useLogicalSize {
        didSet {
            guard useLogicalSize != oldValue else { return }
            Preferences.shared.useLogicalSize = useLogicalSize
            refreshRows()
        }
    }

    /// What the treemap and the sunburst paint with. Purely a drawing choice —
    /// no geometry depends on it, so nothing needs rebuilding when it changes.
    ///
    /// Reads straight through to `Preferences` rather than keeping a copy: this
    /// one is settable from two places at once — the Présentation menu and the
    /// Settings window — and a cached copy would let them drift apart. Both are
    /// `@Observable`, so a view reading it here still tracks changes made there.
    var colorMode: ColorMode {
        get { Preferences.shared.colorMode }
        set { Preferences.shared.colorMode = newValue }
    }

    private var scanTask: Task<Void, Never>?

    /// Root of the scan on screen, and when it was taken.
    private(set) var rootPath: String?
    private(set) var scannedAt: Date?

    /// What the sidebar points at, which is not the same as what has been
    /// scanned: the app opens with a volume highlighted and waits to be told to
    /// start, rather than seizing the disk on launch.
    private(set) var selectedRoot: String?
    /// How the sidebar names it. Carried rather than re-derived so the prompt
    /// calls the folder exactly what the row the user clicked calls it —
    /// the system's display name says "Downloads" where the row says
    /// "Téléchargements".
    private(set) var selectedRootName: String?

    private struct CachedScan {
        let result: ScanResult
        let date: Date
    }

    /// Roots visited earlier this session, oldest first.
    ///
    /// The tree on screen is deliberately *not* in here: deletions mutate
    /// `result` in place, so a second copy would quietly go stale and start
    /// showing files that no longer exist. A root enters the cache only when we
    /// leave it, which also means there is exactly one copy of each tree.
    private var cache: [(path: String, scan: CachedScan)] = []
    /// Roughly 60 MB per million files, so this is a memory decision more than
    /// anything else.
    private static let cacheLimit = 3

    var currentNode: Int32 { trail.last ?? 0 }

    /// What the inspector describes: an explicitly picked item, or failing that
    /// the directory we are standing in. Since a click now navigates, "where I
    /// am" is the thing the user most often wants to act on.
    var inspectedNode: Int32? {
        if selection.count == 1 { return selection.first }
        if selection.count > 1 { return nil }
        return store == nil ? nil : currentNode
    }

    /// True when the node can be opened. A file cannot, and neither can a
    /// collapsed directory — those get selected instead.
    func canEnter(_ node: Int32) -> Bool {
        guard let store else { return false }
        return store.isDirectory(node) && store.childCount[Int(node)] > 0
    }

    /// Single click in a visualisation: open it if we can, otherwise pick it.
    func activate(_ node: Int32) {
        if canEnter(node) {
            enter(node)
        } else {
            selection = [node]
        }
    }

    /// Whatever tree we can show right now — the finished one, or the partial
    /// one still being built.
    var store: NodeStore? { result?.store ?? partialStore }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    // MARK: - Scanning

    /// Scans a root, or brings back the tree if it is still in memory.
    ///
    /// `force` is what the refresh button sends: re-tapping a volume in the
    /// sidebar should be free, but asking for fresh numbers has to mean it.
    func scan(path: String, force: Bool = false) {
        // Asking for the root you are already on is not a request to redo the
        // work. The cache cannot help here: while a scan is in flight there is
        // nothing cached yet, so every extra tap used to cancel it and start
        // again from zero — the more impatient the user, the less progress.
        // Once it has finished, re-running it would only flash the same tree.
        // Keeps the sidebar highlight honest when a scan starts from somewhere
        // else — the Open panel, a drag onto the window.
        if selectedRoot != path {
            selectedRoot = path
            selectedRootName = QuickLocation.displayName(of: path)
        }

        if !force, rootPath == path, isScanning || result != nil { return }

        scanTask?.cancel()
        stashCurrentScan()

        if !force, let index = cache.firstIndex(where: { $0.path == path }) {
            restore(cache.remove(at: index), path: path)
            return
        }
        cache.removeAll { $0.path == path }

        trail = [0]
        othersScope = nil
        rows = []
        selection = []
        result = nil
        partialStore = nil
        junkTask?.cancel()
        junkReport = nil
        junkPhase = .idle
        junkSelection = []
        largeFilesTask?.cancel()
        largeFiles = nil
        largeFilesPhase = .idle
        lastDeletion = nil
        deletionMessage = nil
        scanID += 1
        rootPath = path
        // Only stamped on success, which is also what keeps a failed or
        // cancelled scan out of the cache.
        scannedAt = nil
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
                root: path, options: Preferences.shared.scanOptions(),
                progress: onProgress, snapshot: onSnapshot
            )
            guard let self, !Task.isCancelled else { return }
            if scanned.store.isEmpty {
                phase = .failed("Impossible de lire « \(path) ».")
            } else {
                result = scanned
                partialStore = nil
                scannedAt = Date()
                phase = .loaded
                // Deliberately not a new scanID: indices are append-only within
                // a scan, so the final tree agrees with the last snapshot and
                // the view settles into it rather than flashing.
                refreshRows()
                // The Cleanup view sat out the scan showing its progress; its
                // `.task` fired at scan *start*, when there was no tree yet, so
                // the finished tree has to hand it the report itself.
                if presentation == .cleanup, rootPath == "/" { rescanJunk() }
            }
        }
    }

    /// Points the window at a root without reading anything.
    ///
    /// Selecting is not analysing: a whole-disk walk takes minutes and starting
    /// one is the user's call. Bringing back a tree we already hold is not an
    /// analysis either — it costs nothing and is what returning somewhere is
    /// supposed to feel like — so that case is honoured immediately.
    func select(path: String, name: String? = nil) {
        selectedRoot = path
        selectedRootName = name ?? QuickLocation.displayName(of: path)
        // Every selection lands in the folder's own view, or the global
        // default without one. With a fixed global default a view picked by
        // hand lasts only until the next selection; in "Dernière utilisée"
        // mode the resolved default *is* the view in use, so it carries over.
        presentation = Preferences.shared.presentation(for: path)
            ?? Preferences.shared.resolvedDefaultView
        guard path != rootPath,
              let index = cache.firstIndex(where: { $0.path == path })
        else { return }
        stashCurrentScan()
        restore(cache.remove(at: index), path: path)
    }

    /// True when the sidebar points somewhere that has not been analysed.
    var needsScan: Bool {
        guard let selectedRoot else { return false }
        return selectedRoot != rootPath
    }

    /// Starts the analysis the selection is waiting on.
    func startSelectedScan() {
        guard let selectedRoot else { return }
        scan(path: selectedRoot)
    }

    /// Re-scans the current root from disk, discarding what is on screen.
    func rescan() {
        guard let rootPath else { return }
        scan(path: rootPath, force: true)
    }

    var canRescan: Bool { rootPath != nil && !isScanning }

    /// Parks the finished tree we are leaving so returning to it is instant.
    ///
    /// A cancelled scan is never cached: it is a partial tree, and silently
    /// serving it later as if it were complete would under-report.
    private func stashCurrentScan() {
        guard let result, let rootPath, let scannedAt,
              !result.wasCancelled
        else { return }
        cache.removeAll { $0.path == rootPath }
        cache.append((rootPath, CachedScan(result: result, date: scannedAt)))
        if cache.count > Self.cacheLimit {
            cache.removeFirst(cache.count - Self.cacheLimit)
        }
    }

    private func restore(_ entry: (path: String, scan: CachedScan), path: String) {
        // A scan may still be running — leaving Cleanup mid-walk lands here —
        // and letting it finish would drop its tree on top of the restored one.
        scanTask?.cancel()
        scanTask = nil
        junkTask?.cancel()
        trail = [0]
        othersScope = nil
        rows = []
        selection = []
        partialStore = nil
        junkReport = nil
        junkPhase = .idle
        junkSelection = []
        largeFilesTask?.cancel()
        largeFiles = nil
        largeFilesPhase = .idle
        lastDeletion = nil
        deletionMessage = nil
        scanID += 1
        result = entry.scan.result
        rootPath = path
        scannedAt = entry.scan.date
        phase = .loaded
        refreshRows()
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
            // A cancelled scan still ends one: same hand-off as a finished scan.
            if presentation == .cleanup, rootPath == "/" { rescanJunk() }
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
        // Entering something found inside an "others" slice leaves the slice
        // behind: we are in a real folder now.
        othersScope = nil
        trail.append(node)
        selection = []
        refreshRows()
    }

    /// Steps into an aggregated slice, showing only what it stood for.
    func enterOthers(_ nodes: [Int32]) {
        guard !nodes.isEmpty else { return }
        othersScope = nodes
        selection = []
        refreshRows()
    }

    func goUp() {
        // The slice is the innermost level, so it is what a step up leaves.
        if othersScope != nil {
            othersScope = nil
            selection = []
            refreshRows()
            return
        }
        guard trail.count > 1 else { return }
        trail.removeLast()
        selection = []
        refreshRows()
    }

    var canGoUp: Bool { othersScope != nil || trail.count > 1 }

    /// Total of what an entered "others" slice holds, for the centre label.
    var scopeSize: Int64 {
        guard let othersScope else { return size(of: currentNode) }
        return othersScope.reduce(0) { $0 + size(of: $1) }
    }

    var scopeFileCount: Int32 {
        guard let othersScope, let store else { return 0 }
        return othersScope.reduce(0) { $0 + store.fileCount[Int($1)] }
    }

    /// Navigates the tree to a node, opening every folder above it.
    ///
    /// Used from the cleanup list, where a finding is a path with no relation to
    /// where the user currently stands.
    func reveal(_ node: Int32) {
        guard let store, node >= 0, Int(node) < store.count else { return }
        var ancestors: [Int32] = []
        var current = node
        while current != 0 {
            ancestors.append(current)
            current = store.parent[Int(current)]
        }
        ancestors.append(0)
        othersScope = nil
        trail = ancestors.reversed()

        // Standing *inside* a file is not a thing, and neither is standing
        // inside a folder the scanner collapsed: show it selected in its parent.
        if canEnter(node) {
            selection = []
        } else {
            trail.removeLast()
            selection = [node]
        }
        presentation = lastBrowsingPresentation
        refreshRows()
    }

    /// Jumps to a breadcrumb entry, dropping everything below it.
    func goTo(depth: Int) {
        guard depth >= 0, depth < trail.count - 1 else { return }
        othersScope = nil
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
        treeVersion += 1
        guard let store else { rows = []; return }
        if let othersScope {
            // Already ordered largest first by the layout that built the slice.
            rows = othersScope.filter { !store.flags[Int($0)].contains(.deleted) }
        } else {
            rows = Signposts.measure("refreshRows") {
                store.childrenSortedBySize(of: currentNode, useLogical: useLogicalSize)
            }
        }
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

    /// Builds a plan from paths that were never part of any scanned tree —
    /// the Reboot tool measures /private/var/folders itself, scan or no scan.
    func requestDeletion(outOfTree items: [(name: String, path: String, bytes: Int64)]) {
        guard !items.isEmpty else { return }
        var plan = DeletionPlan(
            requests: [], names: [], totalBytes: 0, cautions: [], refused: []
        )

        for item in items {
            let verdict = DenyList.verdict(for: item.path)
            if case .forbidden(let reason) = verdict {
                plan.refused.append("\(item.name) — \(reason)")
                continue
            }
            if case .caution(let reason) = verdict {
                plan.cautions.append("\(item.name) — \(reason)")
            }
            plan.requests.append(.init(node: nil, path: item.path, bytes: item.bytes))
            plan.names.append(item.name)
            plan.totalBytes += item.bytes
        }

        guard !plan.requests.isEmpty || !plan.refused.isEmpty else { return }
        deletionPlan = plan
    }

    func confirmDeletion() async {
        // No store guard: an out-of-tree plan is deletable before any scan.
        guard let plan = deletionPlan else { return }
        deletionPlan = nil

        // Capture sizes first: markDeleted zeroes them, and undo needs them.
        // Only for requests that came from the tree — an uninstaller's leftovers
        // have no node, and feeding a made-up index to the roll-up would corrupt
        // every ancestor's total.
        var sizes: [Int32: (alloc: Int64, logical: Int64, files: Int32)] = [:]
        if let store {
            for request in plan.requests {
                guard let node = request.node else { continue }
                let index = Int(node)
                sizes[node] = (
                    store.totalAlloc[index], store.totalLogical[index],
                    store.fileCount[index]
                )
            }
        }

        let requests = plan.requests
        let report = await Task.detached { SafeDeleter.moveToTrash(requests) }.value

        for item in report.trashed {
            if let node = item.node { result?.store.markDeleted(node) }
        }
        // Acting on a folder now means having opened it, so the deleted node is
        // often the one under our feet. Climb out before it becomes a view of
        // something that no longer exists.
        let removed = Set(report.trashed.compactMap(\.node))
        if let index = trail.firstIndex(where: removed.contains) {
            trail.removeSubrange(max(1, index)...)
        }
        undoSizes = sizes
        lastDeletion = report.trashed.isEmpty ? nil : report
        present(report)
        selection = []
        junkSelection = []
        deletionEpoch += 1
        refreshRows()
        refreshJunkIfShown()
    }

    func undoLastDeletion() async {
        guard let report = lastDeletion else { return }
        let items = report.trashed
        let failures = await Task.detached { SafeDeleter.restore(items) }.value

        let failedPaths = Set(failures.map(\.path))
        for item in items where !failedPaths.contains(item.originalPath) {
            // Out-of-tree items restore on disk like any other; there is simply
            // no roll-up to put back.
            if let node = item.node, let sizes = undoSizes[node] {
                result?.store.unmarkDeleted(
                    node, alloc: sizes.alloc,
                    logical: sizes.logical, files: sizes.files
                )
            }
        }
        lastDeletion = nil
        undoSizes = [:]
        needsAppManagement = false
        deletionMessage = failures.isEmpty
            ? "Restauration effectuée."
            : "\(failures.count) élément(s) n'ont pas pu être restaurés."
        deletionEpoch += 1
        refreshRows()
        refreshJunkIfShown()
    }

    func dismissDeletionMessage() {
        deletionMessage = nil
        needsAppManagement = false
    }

    /// Empties the trash through the Finder: it owns the per-volume trash
    /// folders and their "put back" records, and TCC would deny us direct
    /// access to `~/.Trash` anyway.
    func emptyTrash() async {
        deletionMessage = "Vidage de la corbeille…"
        needsAppManagement = false
        let success = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "tell application \"Finder\" to empty trash",
            ]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
        if success {
            // The trashed items are gone for good; keeping the undo around
            // would offer a restoration that cannot happen.
            lastDeletion = nil
            undoSizes = [:]
            deletionMessage = "Corbeille vidée."
            deletionEpoch += 1
        } else {
            deletionMessage = "Le Finder n'a pas pu vider la corbeille."
        }
    }

    /// Space opens a preview of the inspected item, and closes it again.
    /// Directories have nothing to preview, so they are ignored rather than
    /// opening an empty panel.
    func togglePreview() {
        if previewURL != nil { previewURL = nil; return }
        guard let store, let node = inspectedNode,
              !store.isDirectory(node) || store.flags[Int(node)].contains(.package)
        else { return }
        previewURL = URL(fileURLWithPath: store.path(of: node))
    }

    // MARK: - Uninstalling an application

    /// True for a node that is an application bundle.
    ///
    /// Tested on the name rather than `NodeFlags.package`, which does not tell
    /// `.app` from `.framework` and is not even set when the user turns on
    /// "descend into packages".
    func isApplication(_ node: Int32) -> Bool {
        guard let store, store.isDirectory(node) else { return false }
        return store.name(of: node).lowercased().hasSuffix(".app")
    }

    /// Gathers the bundle and its leftovers. Off the main actor: it stats every
    /// candidate under `~/Library`, which is far too much for a button press.
    func prepareUninstall(_ node: Int32) {
        guard let store, isApplication(node) else { return }
        let path = store.path(of: node)
        uninstallPhase = .preparing

        Task { [weak self] in
            let gathered = await Task.detached {
                () -> (AppBundle, [Leftover])? in
                guard let app = AppUninstaller.inspect(appPath: path) else {
                    return nil
                }
                return (app, AppUninstaller.leftovers(for: app))
            }.value

            guard let self else { return }
            uninstallPhase = .idle
            guard let (app, leftovers) = gathered else {
                deletionMessage = "« \((path as NSString).lastPathComponent) » n'est pas une application lisible."
                return
            }
            uninstallPlan = UninstallPlan(
                app: app, node: node, leftovers: leftovers,
                isRunning: RunningApps.isRunning(bundleID: app.bundleID)
            )
        }
    }

    /// Trashes the bundle and whichever leftovers were ticked.
    ///
    /// Goes through `SafeDeleter` like everything else, so the deny list still
    /// applies per path and the whole thing stays undoable.
    func uninstall(_ plan: UninstallPlan, keeping selected: Set<String>) async {
        var requests: [SafeDeleter.Request] = [
            .init(node: plan.node, path: plan.app.path, bytes: plan.app.bytes)
        ]
        for leftover in plan.leftovers where selected.contains(leftover.path) {
            // No node: these were never part of the scanned tree.
            requests.append(
                .init(node: nil, path: leftover.path, bytes: leftover.bytes)
            )
        }
        uninstallPlan = nil

        var sizes: [Int32: (alloc: Int64, logical: Int64, files: Int32)] = [:]
        if let node = plan.node, let store {
            let index = Int(node)
            sizes[node] = (
                store.totalAlloc[index], store.totalLogical[index],
                store.fileCount[index]
            )
        }

        let report = await Task.detached {
            SafeDeleter.moveToTrash(requests)
        }.value

        for item in report.trashed {
            if let node = item.node { result?.store.markDeleted(node) }
        }
        let removed = Set(report.trashed.compactMap(\.node))
        if let index = trail.firstIndex(where: removed.contains) {
            trail.removeSubrange(max(1, index)...)
        }
        undoSizes = sizes
        lastDeletion = report.trashed.isEmpty ? nil : report
        present(report)
        selection = []
        deletionEpoch += 1
        refreshRows()
        refreshJunkIfShown()
    }

    // MARK: - Cleanup

    /// Called by the Cleanup view when it appears. Computing the report is the
    /// view's own cost to pay, not the scan's.
    func ensureJunkReport() {
        // Only for the disk: the tool never reports on a lone folder. And not
        // while scanning — the report would describe a partial tree, and the
        // end of the scan hands over a fresh one anyway.
        guard rootPath == "/", junkReport == nil, junkPhase != .running,
              !isScanning
        else { return }
        rescanJunk()
    }

    /// "Nettoyage" entry in the sidebar: the whole disk, every time.
    ///
    /// The tool is global by design — caches live under `~/Library`, `/Library`,
    /// `/private` — so it only ever speaks about the boot volume. A disk still
    /// in memory comes back for free; actually walking it stays behind the
    /// "Démarrer l'analyse" button, like every other view.
    func showCleanup() {
        presentation = .cleanup
        if rootPath != "/", cache.contains(where: { $0.path == "/" }) {
            scan(path: "/") // Cache hit: restored instantly, no walk starts.
        }
    }

    var showsCleanup: Bool { presentation == .cleanup }

    /// "Redémarrage" entry in the sidebar. Unlike Cleanup it never scans:
    /// its two measurements are targeted and independent of any tree.
    func showReboot() { presentation = .reboot }

    var showsReboot: Bool { presentation == .reboot }

    /// After a deletion or an undo. Only worth redoing if a report is already on
    /// screen — otherwise the next visit to the Cleanup view will build it.
    private func refreshJunkIfShown() {
        guard junkReport != nil else { return }
        rescanJunk()
    }

    /// Runs the rule engine off the main actor.
    ///
    /// `NodeStore` is a struct of arrays and `Sendable`, so handing it to a
    /// detached task copies nothing while nobody mutates it.
    private func rescanJunk() {
        guard let store else {
            junkReport = nil
            junkPhase = .idle
            return
        }
        junkTask?.cancel()
        junkPhase = .running
        junkTask = Task { [weak self] in
            let report = await Task.detached {
                Signposts.measure("junkScan") {
                    JunkScanner.scan(store: store, root: 0)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            junkReport = report
            junkPhase = .ready
            junkSelection = junkSelection.intersection(Set(report.findings.map(\.node)))
        }
    }

    // MARK: - Large files

    /// Called by the Files view when it appears and whenever its key changes.
    ///
    /// Not while scanning — the extract would describe a partial tree, and the
    /// key changes once more when the scan settles, which lands back here.
    /// Runs off the main actor exactly like `rescanJunk`, and for the same
    /// `NodeStore`-is-Sendable reason.
    func ensureLargeFiles() {
        guard presentation == .largeFiles, !isScanning, let store else {
            largeFilesTask?.cancel()
            largeFiles = nil
            largeFilesPhase = .idle
            return
        }
        largeFilesTask?.cancel()
        largeFilesPhase = .running
        let node = currentNode
        let useLogical = useLogicalSize
        let id = scanID
        // Captured once here rather than read per node: "now" drifting mid-walk
        // would make the cutoff mean something slightly different at each end
        // of the tree.
        let cutoff = largeFilesAgeFilter.cutoff()
        largeFilesTask = Task { [weak self] in
            let top = await Task.detached {
                Signposts.measure("largestFiles") {
                    LargestFiles.top(
                        in: store, under: node,
                        useLogical: useLogical, modifiedBefore: cutoff
                    )
                }
            }.value
            // Indices only mean anything within the store they came from: a
            // result computed against the previous scan must die here.
            guard let self, !Task.isCancelled, self.scanID == id else { return }
            largeFiles = top
            largeFilesPhase = .ready
        }
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

    /// Turns a report into the banner: the counts, the first failure's actual
    /// reason — a bare "1 échec" left the user with nothing to act on — and,
    /// when macOS refused to touch an app bundle, the Settings toggle that
    /// unlocks it.
    private func present(_ report: DeletionReport) {
        // Only when the bundle is ours: a permission failure on someone else's
        // app is an ownership problem, and no Settings toggle changes that.
        needsAppManagement = report.failures.contains {
            $0.isPermissionDenied && $0.path.hasSuffix(".app")
                && foreignOwner(of: $0.path) == nil
        }

        var parts: [String] = []
        if !report.trashed.isEmpty {
            let bytes = report.reclaimedBytes.formatted(.byteCount(style: .file))
            parts.append(
                "\(report.trashed.count) élément(s) à la corbeille — \(bytes) purgeables."
            )
        }
        if !report.refused.isEmpty {
            parts.append("\(report.refused.count) protégé(s).")
        }
        if let failure = report.failures.first {
            let name = (failure.path as NSString).lastPathComponent
            let others = report.failures.count - 1
            parts.append(
                others == 0
                    ? "Échec : \(name) — \(failure.reason)"
                    : "\(report.failures.count) échecs, dont \(name) — \(failure.reason)"
            )
            if failure.isPermissionDenied,
               let owner = foreignOwner(of: failure.path) {
                parts.append(
                    "Cet élément appartient au compte « \(owner) » : le Finder demande un mot de passe administrateur pour le supprimer."
                )
            }
        }
        if needsAppManagement {
            parts.append(
                "macOS protège les applications : autorisez Silt dans « Gestion des apps », puis relancez-le."
            )
        }
        deletionMessage = parts.joined(separator: " ")
    }

    /// The account owning this path, or nil when it is the current user's —
    /// or unreadable, which permission-wise amounts to the same advice.
    private func foreignOwner(of path: String) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let owner = attributes?[.ownerAccountName] as? String,
              owner != NSUserName()
        else { return nil }
        return owner
    }
}
