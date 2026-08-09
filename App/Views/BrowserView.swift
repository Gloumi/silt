import AppKit
import DiskCore
import SwiftUI

/// The sorted-list view of one directory. Lot 3 adds the sunburst beside it;
/// this stays as the precise, keyboard-friendly counterpart.
struct BrowserView: View {
    let model: ScanModel
    let reboot: RebootModel
    let apps: AppsModel
    let snapshots: SnapshotsModel

    var body: some View {
        Group {
            // Keyed on whether there is a tree, not on the phase.
            //
            // Two branches of a switch are two structural identities to
            // SwiftUI: building `loadedContent` once under `.scanning` and
            // again under `.loaded` tore the whole subtree down at the end of
            // every scan. The visualisation lost its @State, blanked, and came
            // back a frame later — which is exactly what it looked like.
            if model.presentation == .cleanup {
                // Cleanup is a destination, not a way of looking at the current
                // folder: it owns its empty, scanning and loaded states, and
                // the breadcrumb or "Prêt à analyser" would describe a place
                // rather than what the tool is doing.
                CleanupView(model: model)
            } else if model.presentation == .reboot {
                RebootView(model: model, reboot: reboot)
            } else if model.presentation == .snapshots {
                // The one destination no scan could ever feed: snapshots are
                // invisible to a walk of the tree by design.
                SnapshotsView(model: model, snapshots: snapshots)
            } else if model.presentation == .trash {
                // Reads nothing but its own ledger and the trash folders it
                // names, so like Snapshots it stands entirely outside the scan.
                TrashView(model: model)
            } else if model.presentation == .apps {
                // Also a destination, and the one that owes the scan the least:
                // it lists /Applications itself, so it works with no volume
                // read at all.
                AppsView(model: model, apps: apps)
            } else if model.needsScan {
                // The sidebar points somewhere unread. Showing the previous
                // tree here would attach it to the wrong name.
                EmptyStateView(model: model)
            } else if model.store != nil {
                loadedContent.overlay(alignment: .top) {
                    // The tree is already worth looking at — show it growing,
                    // with the counters demoted to a strip.
                    if case .scanning(let progress) = model.phase {
                        ScanStrip(progress: progress) { model.cancel() }
                    }
                }
            } else {
                switch model.phase {
                case .scanning(let progress):
                    ScanningView(progress: progress) { model.cancel() }
                case .failed(let message):
                    ContentUnavailableView(
                        "Scan impossible", systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                case .idle, .loaded:
                    EmptyStateView(model: model)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        // On the whole body rather than inside `loadedContent`: leaving for
        // Cleanup has to drop the mask, and a task that only exists in the
        // browsing views would never run to do it.
        .task(id: model.searchKey) { model.ensureSearchMask() }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let store = model.store {
            let parentSize = max(1, model.size(of: model.currentNode))
            VStack(spacing: 0) {
                BreadcrumbBar(model: model, store: store)
                Divider()
                Group {
                    switch model.presentation {
                    case .sunburst:
                        SunburstView(model: model).padding(8)
                    case .treemap:
                        TreemapView(model: model).padding(6)
                    case .largeFiles:
                        LargeFilesView(model: model, store: store)
                    case .duplicates:
                        DuplicatesView(model: model, store: store)
                    // The tools never reach here — the body branches to their
                    // views before this — but the switch must cover them.
                    case .list, .apps, .cleanup, .reboot, .snapshots, .trash:
                        entryList(store: store, parentSize: parentSize)
                    }
                }
                // The middle takes whatever is left, whatever is in it. Without
                // this an empty state — "Dossier vide", a filter matching
                // nothing — reports its intrinsic height, the stack shrinks to
                // fit and both bars drift into the middle of the window.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Over the whole group, not inside the list: the charts draw a
                // blank canvas when nothing survives the filter and have no
                // empty state of their own to say why.
                .overlay {
                    if model.isFiltering, model.rows.isEmpty {
                        ContentUnavailableView.search(text: model.searchText)
                    }
                }
                StatusBar(model: model, store: store)
            }
        }
    }

    @ViewBuilder
    private func entryList(store: NodeStore, parentSize: Int64) -> some View {
        ZStack {
            List(model.rows, id: \.self, selection: Bindable(model).selection) { node in
                    EntryRow(
                        store: store,
                        node: node,
                        size: model.size(of: node),
                        fraction: Double(model.size(of: node)) / Double(parentSize)
                    )
                    .listRowSeparator(.hidden)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { model.enter(node) }
                    .contextMenu {
                        Button("Afficher dans le Finder") { reveal(store, node) }
                        Divider()
                        Button("Mettre à la corbeille", role: .destructive) {
                            if !model.selection.contains(node) {
                                model.selection = [node]
                            }
                            model.requestDeletion()
                        }
                    }
                }
            .listStyle(.inset)
            // A filter matching nothing is not an empty folder, and the
            // group above already says so.
            if model.rows.isEmpty, !model.isFiltering {
                ContentUnavailableView("Dossier vide", systemImage: "folder")
            }
        }
    }

    private func reveal(_ store: NodeStore, _ node: Int32) {
        NSWorkspace.shared.selectFile(
            store.path(of: node), inFileViewerRootedAtPath: ""
        )
    }
}

// MARK: - Rows

private struct EntryRow: View {
    let store: NodeStore
    let node: Int32
    let size: Int64
    let fraction: Double

    var body: some View {
        let flags = store.flags[Int(node)]
        let isDirectory = flags.contains(.directory)

        HStack(spacing: 9) {
            Image(nsImage: IconCache.shared.icon(
                name: store.name(of: node),
                isDirectory: isDirectory,
                isPackage: flags.contains(.package)
            ))
            .resizable()
            .frame(width: 16, height: 16)

            Text(store.name(of: node))
                .lineLimit(1)
                .truncationMode(.middle)

            // A folder named after a bundle id says nothing on its own; the
            // application it belongs to is the useful part.
            if let friendly = friendlyName {
                Text(friendly)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let badge = badgeText(flags) {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(Format.percent(fraction))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)

            Text(Format.bytes(size))
                .monospacedDigit()
                .frame(width: 78, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .opacity(isDirectory && store.childCount[Int(node)] > 0 ? 1 : 0)
        }
        .padding(.vertical, 2)
        // The bar is the row: size is readable at a glance without reading a
        // single number.
        .background(alignment: .leading) {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.proportionBar)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
    }

    private var friendlyName: String? {
        AppNames.shared.friendlyName(
            for: store.name(of: node), path: store.path(of: node)
        )
    }

    private func badgeText(_ flags: NodeFlags) -> String? {
        if flags.contains(.unreadable) { return "illisible" }
        if flags.contains(.hardlinkDuplicate) { return "lien dur" }
        if flags.contains(.package) { return "paquet" }
        if flags.contains(.notDescended) { return "replié" }
        if flags.contains(.symlink) { return "alias" }
        return nil
    }
}

// MARK: - Chrome

private struct BreadcrumbBar: View {
    let model: ScanModel
    let store: NodeStore

    var body: some View {
        HStack(spacing: 10) {
            // The sunburst has its centre to climb out through; the treemap and
            // the list have nothing, so the way back lives here for all of them.
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canGoUp ? Color.accentColor : Color.secondary)
            .disabled(!model.canGoUp)
            .padding(.leading, 10)
            .help("Remonter d'un niveau")

            breadcrumbs
            Spacer(minLength: 8)

            // First of the trailing run, against the spacer: everything to its
            // right keeps a constant distance from the window edge, so this
            // one can come and go with the drawn views without sliding the
            // buttons the pointer is usually aiming for.
            ColorModeSwitcher(model: model)

            // Re-tapping a volume in the sidebar now reuses the tree in memory,
            // so refreshing has to be something the user asks for explicitly.
            BarButton(
                symbol: "arrow.clockwise",
                help: "Actualiser l'analyse",
                isEnabled: model.canRescan
            ) {
                model.rescan()
            }

            ViewModeSwitcher(model: model)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 5)
        .background(.bar)
        // The switcher's tooltip hangs below this bar and must draw over the
        // content beneath it.
        .zIndex(1)
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(model.trail.enumerated()), id: \.offset) { depth, node in
                    if depth > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        model.goTo(depth: depth)
                    } label: {
                        Text(depth == 0
                             ? (store.path(of: 0) as NSString).lastPathComponent
                             : store.name(of: node))
                            .fontWeight(depth == model.trail.count - 1 ? .semibold : .regular)
                    }
                    .buttonStyle(.link)
                    .disabled(depth == model.trail.count - 1 && model.othersScope == nil)
                }

                // An aggregated slice has no node, so it cannot be a trail
                // entry — but standing inside one has to be visible somewhere,
                // and the breadcrumb is where "where am I" is answered.
                if let scope = model.othersScope {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                    Text("Autres (\(scope.count))")
                        .fontWeight(.semibold)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
    }
}

private struct StatusBar: View {
    let model: ScanModel
    let store: NodeStore

    var body: some View {
        HStack(spacing: 10) {
            if let mask = model.searchMask {
                // The total on the right is already the retained part, which on
                // its own reads as the folder having shrunk. Say what it is a
                // part of.
                Text("\(Format.count(mask.resultCount(under: model.currentNode))) résultats")
                Text("·")
                Text("sur \(Format.bytes(model.trueSize(of: model.currentNode))) dans ce dossier")
            } else {
                Text("\(Format.count(model.rows.count)) éléments")
                Text("·")
                Text("\(Format.count(Int(store.fileCount[Int(model.currentNode)]))) fichiers au total")
            }
            if let scannedAt = model.scannedAt {
                Text("·")
                // Says how stale the numbers are, which matters now that a tree
                // can come straight back from memory.
                Text("analysé \(Format.age(since: scannedAt))")
            }
            Spacer()
            if let result = model.result, !result.unreadablePaths.isEmpty {
                Button {
                    model.showsWelcome = true
                } label: {
                    Label(
                        "\(result.unreadablePaths.count) dossiers illisibles",
                        systemImage: "lock"
                    )
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Ces dossiers manquent aux totaux. Cliquez pour savoir comment y donner accès.")
            }
            Text(Format.bytes(model.size(of: model.currentNode)))
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - States

/// Before anything has been scanned.
///
/// A volume is already highlighted in the sidebar, but nothing has been read:
/// walking a whole disk takes minutes, and that is a decision to hand to the
/// user rather than to make for them at launch.
private struct EmptyStateView: View {
    let model: ScanModel

    var body: some View {
        ContentUnavailableView {
            Label("Prêt à analyser", systemImage: "chart.pie")
        } description: {
            if let target {
                Text("Silt va parcourir \(target) et vous montrer où part la place.")
            } else {
                Text("Choisissez un volume ou un emplacement dans la barre latérale.")
            }
        } actions: {
            if model.selectedRoot != nil {
                Button {
                    model.startSelectedScan()
                } label: {
                    Label("Démarrer l'analyse", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// What the button promises to scan, named as the sidebar names it.
    ///
    /// The previous version asked the URL whether it sat on the root file
    /// system and used the volume's name if so — which is true of *every*
    /// folder on the boot disk, so "/Applications" announced itself as
    /// "Macintosh HD". The name now travels with the selection instead of
    /// being re-derived from the path.
    private var target: String? {
        model.selectedRootName.map { "« \($0) »" }
    }
}

/// Slim live counter shown over the growing tree.
private struct ScanStrip: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("\(Format.count(progress.filesSeen)) fichiers")
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(Format.bytes(progress.bytesSeen))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Annuler", action: onCancel)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .font(.caption)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .shadow(radius: 6, y: 2)
        .padding(.top, 10)
        .animation(.default, value: progress.filesSeen)
    }
}

private struct ScanningView: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("\(Format.count(progress.filesSeen)) fichiers")
                .font(.title3)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(Format.bytes(progress.bytesSeen))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(progress.currentPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 380)
            Button("Annuler", action: onCancel)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .animation(.default, value: progress.filesSeen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
