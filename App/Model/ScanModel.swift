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
        case sunburst, treemap, list, largeFiles, apps, cleanup, reboot, snapshots
        case trash
        var id: String { rawValue }

        /// The four ways of looking at the tree. Applications, Cleanup and
        /// Reboot are not among them: each is a destination of its own, reached
        /// from the sidebar.
        static let browsing: [Presentation] = [.sunburst, .treemap, .list, .largeFiles]

        /// The three ways of *standing in* a folder. Large files browses the
        /// tree like the others, but it is a flat extract of a whole subtree —
        /// "show me where this lives" needs an actual tree view to land in.
        static let treeViews: [Presentation] = [.sunburst, .treemap, .list]

        /// The two drawn views. They share a palette, so the colour mode means
        /// something in these and nowhere else.
        static let charts: [Presentation] = [.sunburst, .treemap]

        /// The destinations that are not a view of the tree. Each shows its own
        /// findings, so the inspector must not go on describing whatever folder
        /// was selected before arriving here.
        static let tools: [Presentation] = [
            .apps, .cleanup, .reboot, .snapshots, .trash,
        ]

        var label: String {
            switch self {
            case .sunburst: "Anneaux"
            case .treemap: "Blocs"
            case .list: "Liste"
            case .largeFiles: "Fichiers volumineux"
            case .apps: "Applications"
            case .cleanup: "Caches et résidus"
            case .reboot: "Redémarrage"
            case .snapshots: "Snapshots"
            case .trash: "Corbeille"
            }
        }
        var symbol: String {
            switch self {
            case .sunburst: "chart.pie"
            case .treemap: "square.grid.2x2"
            case .list: "list.bullet"
            case .largeFiles: "doc.text.magnifyingglass"
            case .apps: "app.badge"
            case .cleanup: "wand.and.sparkles"
            case .reboot: "restart.circle"
            case .snapshots: "clock.arrow.circlepath"
            case .trash: "trash"
            }
        }

        /// Shown on hover: the icons alone do not say what each view is for.
        var hint: String {
            switch self {
            case .sunburst: "Anneaux — vue d'ensemble du dossier"
            case .treemap: "Blocs — surface proportionnelle à la taille"
            case .list: "Liste — éléments triés par taille"
            case .largeFiles: "Fichiers volumineux — les plus gros du dossier et de ses sous-dossiers"
            case .apps: "Applications — ce que chaque application occupe, bundle et fichiers liés"
            case .cleanup: "Caches et résidus — ce que vos outils régénèrent tout seuls"
            case .reboot: "Redémarrage — espace qu'un redémarrage libérerait"
            case .snapshots: "Snapshots — copies APFS locales qui retiennent de l'espace"
            case .trash: "Corbeille — ce que Silt y a mis, et qu'il peut remettre en place"
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

    /// Bumped every time what is on screen changes — a scan snapshot, the final
    /// result, a deletion, an undo, and every step of navigation.
    ///
    /// The visualisations used to key off `rows.count`, which only moves when
    /// the *number* of children changes. A home folder settles on its twenty-odd
    /// entries within the first second while their sizes keep growing for ten
    /// more, so the rings froze almost immediately and only caught up at the end.
    private(set) var treeVersion = 0

    /// Bumped only when the tree's *contents* change, never when we merely walk
    /// around in it.
    ///
    /// `treeVersion` cannot serve here because it moves on every `enter` and
    /// `goUp` too, and a search mask is a full pass over every name in the
    /// store. Keying it on navigation would make opening a folder cost more
    /// than the scan that found it.
    private(set) var contentVersion = 0

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
        var searchVersion: Int
    }

    var largeFilesKey: LargeFilesKey {
        LargeFilesKey(
            scanID: scanID, treeVersion: treeVersion,
            node: currentNode, useLogical: useLogicalSize,
            age: largeFilesAgeFilter, scanning: isScanning,
            searchVersion: searchVersion
        )
    }

    /// How stale a file has to be to make the list at all. Stored in
    /// `Preferences`, like the colour mode and for the same reason.
    var largeFilesAgeFilter: AgeFilter {
        get { Preferences.shared.largeFilesAgeFilter }
        set { Preferences.shared.largeFilesAgeFilter = newValue }
    }

    /// Where the search looks. Both scopes read the *same* mask — retained bytes
    /// depend only on a node's own subtree — so this moves the view rather than
    /// filtering anything differently.
    enum SearchScope: String, CaseIterable, Identifiable {
        /// From the scan root, recentring on wherever the results turn out to be.
        case everywhere
        /// The folder on screen and below, without moving.
        case here

        var id: String { rawValue }

        var label: String {
            switch self {
            case .everywhere: "Tout"
            case .here: "Ici"
            }
        }
    }

    enum SearchPhase {
        case idle, running, ready
    }

    /// What the user typed, pushed here by the search field. Raw text —
    /// `SearchQuery` decides what it means, and refuses anything that would not
    /// narrow the tree.
    var searchText = "" {
        didSet { untrackedSearchText = searchText }
    }

    /// The same string, readable without registering an observation.
    ///
    /// The search box lives in the toolbar. Any observed read of `searchText`
    /// from there re-renders the toolbar on every keystroke, and SwiftUI
    /// answers that by tearing the `NSSearchField` down and building a new one
    /// — which retakes focus, and taking focus selects all the text. That is
    /// what made the field unusable past one character.
    @ObservationIgnored private(set) var untrackedSearchText = ""

    /// Bumped when something other than typing changes the query — a new scan
    /// clearing it. The field syncs from the model only then.
    private(set) var searchResetToken = 0

    var searchScope: SearchScope = .everywhere {
        didSet {
            guard searchScope != oldValue, searchMask != nil else { return }
            applyScope()
        }
    }

    /// What survives the current query, or nil when nothing is being searched.
    private(set) var searchMask: SearchMask?
    private(set) var searchPhase: SearchPhase = .idle
    /// Bumped whenever the mask is replaced or dropped. The visualisations cache
    /// their geometry, so they need something to key a rebuild on — exactly what
    /// `treeVersion` does for the tree itself.
    private(set) var searchVersion = 0
    private var searchTask: Task<Void, Never>?

    /// Where the user stood when the search took over, so clearing it can put
    /// them back. Carries its own `scanID`: indices from a previous scan are
    /// meaningless, and a stale trail would be worse than no restore at all.
    private var placeBeforeSearch: (trail: [Int32], others: [Int32]?, scanID: Int)?
    /// The trail the recentring itself produced, compared against the current one
    /// to tell "the search moved me" from "I walked off on my own".
    private var focusedTrail: [Int32]?
    /// Query the last recentring was done for. A running scan rebuilds the mask
    /// two or three times a second, and recentring on each of them would drag the
    /// view around while the tree fills in.
    private var focusedFor: String?

    var isFiltering: Bool { searchMask != nil }

    /// Whether there is a tree to search and a view drawing the field. The
    /// breadcrumb bar — and with it the field — only exists in the browsing
    /// views, so ⌘F has to be dark everywhere else.
    var canSearch: Bool {
        store != nil && Presentation.browsing.contains(presentation)
    }

    /// Bumped by the Rechercher command. The field watches it and takes focus:
    /// a menu item has no other way to reach a control buried in the detail.
    private(set) var focusSearchRequests = 0

    func requestSearchFocus() {
        focusSearchRequests += 1
    }

    /// Files the current query away for the magnifying glass menu.
    ///
    /// Only queries that found something: offering a typo back as a suggestion
    /// makes the list a record of mistakes. Called when the user leaves a query
    /// behind, never per keystroke.
    func rememberSearch() {
        guard let mask = searchMask, !mask.isEmpty else { return }
        Preferences.shared.rememberSearch(mask.query.text)
    }

    /// Everything the mask depends on, folded into one value a view can key its
    /// `.task` on.
    ///
    /// The scope is deliberately absent, and so is `treeVersion`: the first
    /// changes nothing about the mask, and the second moves on every step of
    /// navigation.
    struct SearchKey: Hashable {
        var scanID: Int
        var contentVersion: Int
        var text: String
        var useLogical: Bool
        var filtersTree: Bool
    }

    var searchKey: SearchKey {
        SearchKey(
            scanID: scanID, contentVersion: contentVersion,
            text: searchText, useLogical: useLogicalSize,
            filtersTree: Presentation.browsing.contains(presentation)
        )
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
    /// Whether the inspector column is open. Held here rather than in the view
    /// so the menu command can reach it: its keyboard shortcut has to keep
    /// working when the column — and the toolbar button that lives in it — is
    /// folded away, which is exactly when you need it most.
    ///
    /// Open by default, and never opened or closed by the app afterwards. A
    /// column that comes and goes on its own was tried: it opened on a landed
    /// scan and on the Applications view, and had to stay shut on Cleanup,
    /// Reboot and Snapshots — a rule plus its exceptions, for a window whose
    /// behaviour nobody could predict. It also opened on "Aucune sélection" in
    /// Applications, which is the very emptiness it was meant to spare us.
    /// What the open column buys, on top of that, is discovery: showing in the
    /// Finder, uninstalling, what an app leaves behind all live in there.
    var showsInspector = true

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
    ///
    /// The banner's undo, and only that: it dies with the launch. Anything that
    /// has to outlive the banner belongs in `restorable` below.
    private(set) var lastDeletion: DeletionReport?
    /// Everything this app has trashed that is still in a trash folder, newest
    /// first — the Corbeille tool's contents, and the durable route back once
    /// the banner is gone.
    private(set) var restorable: [TrashLedgerEntry] = []
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
        resetSearch()
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
                treeDidChange()
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
        resetSearch()
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
        treeDidChange()
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
            treeDidChange()
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
        treeDidChange()
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
        othersScope = nil
        trail = ancestry(of: node)

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

    /// Path from the scan root down to `node`, which is what `trail` is.
    private func ancestry(of node: Int32) -> [Int32] {
        guard let store, node >= 0, Int(node) < store.count else { return [0] }
        var ancestors: [Int32] = []
        var current = node
        while current != 0 {
            ancestors.append(current)
            current = store.parent[Int(current)]
        }
        ancestors.append(0)
        return ancestors.reversed()
    }

    // MARK: - Reading

    /// Size to *show* for a node, which under a filter is only the part of it
    /// that matched. The single place the rest of the app reads a size from, so
    /// the rows, the charts, the status bar and the inspector cannot disagree.
    func size(of node: Int32) -> Int64 {
        guard let store else { return 0 }
        return store.size(of: node, useLogical: useLogicalSize, through: searchMask)
    }

    /// Size a node really is, whatever is being searched for.
    ///
    /// What anything describing an *item* rather than the view has to report:
    /// the inspector sits above a "move to Trash" button, and a filtered figure
    /// there would understate what is about to go.
    func trueSize(of node: Int32) -> Int64 {
        guard let store else { return 0 }
        return store.size(of: node, useLogical: useLogicalSize, through: nil)
    }

    /// An entered "others" slice as the views should draw it: what the
    /// aggregation stood for, minus whatever a deletion or a filter has taken
    /// out of it since.
    var visibleOthersScope: [Int32]? {
        guard let othersScope, let store else { return othersScope }
        return othersScope.filter {
            !store.flags[Int($0)].contains(.deleted)
                && (searchMask?.keeps($0) ?? true)
        }
    }

    /// Records that the tree itself changed, not just where we are standing in
    /// it. Anything derived from the whole store — the search mask above all —
    /// keys off `contentVersion` so that walking around costs nothing.
    private func treeDidChange() {
        contentVersion += 1
        refreshRows()
    }

    private func refreshRows() {
        treeVersion += 1
        guard let store else { rows = []; return }
        if othersScope != nil {
            // Already ordered largest first by the layout that built the slice.
            rows = visibleOthersScope ?? []
        } else {
            rows = Signposts.measure("refreshRows") {
                store.childrenSortedBySize(
                    of: currentNode, useLogical: useLogicalSize,
                    through: searchMask
                )
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
        remember(report.trashed)
        present(report)
        selection = []
        junkSelection = []
        deletionEpoch += 1
        treeDidChange()
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
        // What went back is no longer in the trash, so it leaves the ledger too
        // — otherwise the Corbeille tool would offer to restore it a second
        // time, onto a path that is now occupied.
        forget(trashPaths: items
            .filter { !failedPaths.contains($0.originalPath) }
            .compactMap(\.trashPath))
        deletionMessage = failures.isEmpty
            ? "Restauration effectuée."
            : "\(failures.count) élément(s) n'ont pas pu être restaurés."
        deletionEpoch += 1
        treeDidChange()
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
            // Verified against the trash rather than cleared outright. The
            // Finder reports success while leaving behind what it could not
            // remove — a stranded system container is the case in point — and
            // that item is the one whose record matters most. Retiring the
            // ledger wholesale would erase it precisely then.
            await refreshRestorable()
            deletionMessage = restorable.isEmpty
                ? "Corbeille vidée."
                : "Corbeille vidée — \(restorable.count) élément(s) ont résisté et restent restaurables ici."
            deletionEpoch += 1
        } else {
            // The Finder balks at items it cannot remove — a stranded system
            // container is the usual one. The ledger is re-read rather than
            // cleared: what survived is still restorable, and saying so is the
            // whole point of the tool.
            await refreshRestorable()
            deletionMessage = restorable.isEmpty
                ? "Le Finder n'a pas pu vider la corbeille."
                : "Le Finder n'a pas pu vider la corbeille — \(restorable.count) élément(s) y sont encore, restaurables depuis « Corbeille »."
        }
    }

    // MARK: - The durable trash ledger

    /// Re-reads the ledger and retires whatever has left the trash since.
    ///
    /// Called when the Corbeille tool appears and after every deletion epoch,
    /// rather than on a timer: the trash changes under us — the user empties it
    /// in the Finder — but not so often that polling would earn its keep.
    func refreshRestorable() async {
        restorable = await Task.detached {
            let survivors = TrashLedger.survivors(of: TrashLedger.load())
            TrashLedger.save(survivors)
            return survivors
        }.value
    }

    /// Puts back a selection from the Corbeille tool.
    ///
    /// Unlike the banner's undo this cannot repair the tree's roll-up — the
    /// nodes these came from belong to a scan that may no longer exist — so the
    /// figures are refreshed and the next scan tells the truth. Restoring the
    /// file itself is identical either way.
    func restoreFromTrash(_ entries: [TrashLedgerEntry]) async {
        guard !entries.isEmpty else { return }
        let items = entries.map(\.item)
        let failures = await Task.detached { SafeDeleter.restore(items) }.value

        let failedPaths = Set(failures.map(\.path))
        forget(trashPaths: entries
            .filter { !failedPaths.contains($0.originalPath) }
            .map(\.trashPath))
        // A restore can fail because the item is no longer there to restore —
        // the trash was emptied since. Re-probing retires those too, instead of
        // leaving an entry that will fail the same way for ever.
        await refreshRestorable()

        let restored = entries.count - failures.count
        var parts: [String] = []
        if restored > 0 { parts.append("\(restored) élément(s) restauré(s).") }
        if let failure = failures.first {
            let name = (failure.path as NSString).lastPathComponent
            parts.append(
                failures.count == 1
                    ? "Échec : \(name) — \(failure.reason)"
                    : "\(failures.count) échecs, dont \(name) — \(failure.reason)"
            )
        }
        deletionMessage = parts.joined(separator: " ")
        needsAppManagement = false
        deletionEpoch += 1
        treeDidChange()
        refreshJunkIfShown()
    }

    /// Records what just went to the trash, so it survives the banner.
    private func remember(_ items: [TrashedItem]) {
        guard !items.isEmpty else { return }
        let entries = TrashLedger.record(
            items, at: Date(), into: TrashLedger.load()
        )
        TrashLedger.save(entries)
        restorable = entries
    }

    /// Retires trash paths whose items went back where they came from.
    ///
    /// Only ever the successes: an item whose restore failed is still sitting
    /// in the trash, and dropping it would strand it exactly as before.
    private func forget(trashPaths: [String]) {
        guard !trashPaths.isEmpty else { return }
        let kept = TrashLedger.forget(
            trashPaths: trashPaths, from: TrashLedger.load()
        )
        TrashLedger.save(kept)
        restorable = kept
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

    /// The inspector's route in: an application picked out of a scanned tree.
    func prepareUninstall(_ node: Int32) {
        guard let store, isApplication(node) else { return }
        prepareUninstall(appPath: store.path(of: node), node: node)
    }

    /// Gathers the bundle and its leftovers. Off the main actor: it stats every
    /// candidate under `~/Library`, which is far too much for a button press.
    ///
    /// The node is optional because the Applications view knows nothing of any
    /// tree — it lists `/Applications` itself, scan or no scan. Everything
    /// downstream was already built for that: `UninstallPlan.node` is optional,
    /// and `uninstall` only rolls a deletion back up when there is a node.
    func prepareUninstall(appPath path: String, node: Int32? = nil) {
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
        remember(report.trashed)
        present(report)
        selection = []
        deletionEpoch += 1
        treeDidChange()
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

    /// "Caches et résidus" entry in the sidebar: the whole disk, every time.
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

    /// "Applications" entry in the sidebar. Never scans either: the list walks
    /// `/Applications` on its own, so the tool works before any volume is read.
    func showApps() { presentation = .apps }

    var showsApps: Bool { presentation == .apps }

    /// "Snapshots" entry in the sidebar, and the purgeable line under every
    /// volume gauge. `volume` says which one to open on; nil keeps whatever
    /// the tool was already showing.
    func showSnapshots(volume: String?) {
        if let volume { snapshotVolumeRequest = volume }
        presentation = .snapshots
    }

    var showsSnapshots: Bool { presentation == .snapshots }

    func showTrash() { presentation = .trash }

    var showsTrash: Bool { presentation == .trash }

    /// The mount point the Snapshots view should scroll to on arrival. Set by
    /// the sidebar, cleared by the view once it has honoured it — the model
    /// carries the request rather than the answer, so nothing here needs to
    /// know whether the tool is even on screen.
    var snapshotVolumeRequest: String?

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
        // A mask on its way in will change the answer, and the key moves again
        // when it lands. Keeping the previous list beats flashing an unfiltered
        // one for the length of the debounce.
        guard searchPhase != .running else { return }
        largeFilesTask?.cancel()
        largeFilesPhase = .running
        let node = currentNode
        let useLogical = useLogicalSize
        let id = scanID
        // Captured once here rather than read per node: "now" drifting mid-walk
        // would make the cutoff mean something slightly different at each end
        // of the tree.
        let cutoff = largeFilesAgeFilter.cutoff()
        let filter = searchMask
        largeFilesTask = Task { [weak self] in
            let top = await Task.detached {
                Signposts.measure("largestFiles") {
                    LargestFiles.top(
                        in: store, under: node,
                        useLogical: useLogical, modifiedBefore: cutoff,
                        filter: filter
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

    // MARK: - Search

    /// Called by the browser whenever `searchKey` changes.
    ///
    /// Runs off the main actor exactly like `ensureLargeFiles`, and for the same
    /// `NodeStore`-is-Sendable reason: handing a struct of arrays to a detached
    /// task copies nothing while nobody mutates it.
    func ensureSearchMask() {
        guard Presentation.browsing.contains(presentation),
              let store, let query = SearchQuery(searchText)
        else {
            clearSearch()
            return
        }

        searchTask?.cancel()
        searchPhase = .running
        let useLogical = useLogicalSize
        let id = scanID

        searchTask = Task { [weak self] in
            // Typing is a stream of keystrokes, not a stream of questions. One
            // pass over every name in the store per keypress makes the field
            // feel gummy, and every pass but the last is thrown away anyway.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let mask = await Task.detached {
                Signposts.measure("searchMask") {
                    SearchMask.build(
                        store: store, query: query, useLogical: useLogical
                    )
                }
            }.value

            guard let self, !Task.isCancelled, self.scanID == id else { return }
            apply(mask)
        }
    }

    private func apply(_ mask: SearchMask) {
        if placeBeforeSearch == nil {
            placeBeforeSearch = (trail, othersScope, scanID)
        }
        searchMask = mask
        searchPhase = .ready
        searchVersion += 1
        if searchScope == .everywhere, focusedFor != mask.query.text {
            recenter(using: mask)
            focusedFor = mask.query.text
        }
        refreshRows()
    }

    /// Drops the filter and, if the user has not walked away since, puts them
    /// back where the search found them.
    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        guard searchMask != nil || searchPhase != .idle else { return }
        searchMask = nil
        searchPhase = .idle
        searchVersion += 1

        // Only when the recentring is still the reason they are standing here.
        // Yanking someone out of a folder they deliberately opened is how a
        // filter stops being trusted.
        if let place = placeBeforeSearch, place.scanID == scanID,
           trail == focusedTrail {
            trail = validated(place.trail)
            othersScope = place.others
        }
        forgetSearchPlace()
        refreshRows()
    }

    /// Moves onto the closest folder that holds every result.
    private func recenter(using mask: SearchMask) {
        guard let store else { return }
        let path = ancestry(of: mask.focus(from: 0, in: store))
        guard path != trail else {
            focusedTrail = trail
            return
        }
        othersScope = nil
        trail = path
        focusedTrail = path
    }

    /// Switching scope moves the view and nothing else: "Tout" recentres on the
    /// results wherever they are, "Ici" hands back the folder the user was
    /// standing in when they started typing.
    private func applyScope() {
        guard let mask = searchMask else { return }
        switch searchScope {
        case .everywhere:
            recenter(using: mask)
            focusedFor = mask.query.text
        case .here:
            if let place = placeBeforeSearch, place.scanID == scanID {
                othersScope = nil
                trail = validated(place.trail)
                focusedTrail = trail
            }
            focusedFor = nil
        }
        refreshRows()
    }

    private func forgetSearchPlace() {
        placeBeforeSearch = nil
        focusedTrail = nil
        focusedFor = nil
    }

    /// A trail that may have gone stale — a folder trashed while the filter was
    /// up — truncated at the first entry that no longer holds.
    private func validated(_ candidate: [Int32]) -> [Int32] {
        guard let store else { return [0] }
        var result: [Int32] = [0]
        for node in candidate.dropFirst() {
            guard Int(node) < store.count,
                  !store.flags[Int(node)].contains(.deleted)
            else { break }
            result.append(node)
        }
        return result
    }

    /// Wipes every trace of a search. A fresh tree starts unfiltered: keeping
    /// the query would land the user at the bottom of an arbitrary branch of a
    /// disk they only just asked to look at.
    private func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchText = ""
        searchResetToken += 1
        searchMask = nil
        searchPhase = .idle
        searchVersion += 1
        forgetSearchPlace()
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
            // Not "purgeables": that word now means the space macOS itself
            // holds back — snapshots and caches — and the Snapshots tool is
            // built around it. Trashed bytes are freed by emptying the trash,
            // which is a different gesture with a different button.
            parts.append(
                "\(report.trashed.count) élément(s) à la corbeille — \(bytes) libérés en la vidant."
            )
        }
        // The Finder route loses the Finder's own "Remettre" often enough that
        // saying nothing would leave the user believing in an undo that is not
        // there. "Annuler" here still works — until this banner is dismissed.
        if !report.finderAssisted.isEmpty {
            parts.append(
                "\(report.finderAssisted.count) élément(s) sont passés par le Finder : « Remettre » peut y être indisponible, « Annuler » reste fiable tant que ce message est affiché."
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

    /// The banner, after the Snapshots tool has been at work.
    ///
    /// Its own entry point rather than a shared one: a deleted snapshot cannot
    /// be restored, so `lastDeletion` must stay nil and the banner must not
    /// grow an "Annuler" button it could not honour.
    func reportSnapshotOutcome(_ message: String) {
        guard !message.isEmpty else { return }
        lastDeletion = nil
        needsAppManagement = false
        deletionMessage = message
        // Moves the sidebar gauges now rather than at the next 30 s poll.
        deletionEpoch += 1
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
