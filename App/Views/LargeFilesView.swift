import AppKit
import DiskCore
import SwiftUI

/// Flat extract of the biggest files under the current folder.
///
/// The other browsing modes show one level and make you dig; this one answers
/// the question they keep raising — "fine, but *which files* are eating the
/// disk" — by pulling the heaviest items out of the whole subtree, however
/// deep they hide. It scopes to the breadcrumb like its siblings: step into a
/// folder and the extract narrows with you.
struct LargeFilesView: View {
    let model: ScanModel
    let store: NodeStore

    var body: some View {
        content
            .task(id: model.largeFilesKey) { model.ensureLargeFiles() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            // The extract only ever describes a finished tree; the key changes
            // again when the scan settles and the list appears by itself.
            VStack(spacing: 10) {
                ProgressView()
                Text("L'analyse doit d'abord se terminer.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let files = model.largeFiles {
            if files.isEmpty, model.isFiltering {
                // A search matching nothing is neither an empty folder nor an
                // age cutoff being strict, so it gets its own way out.
                ContentUnavailableView {
                    Label("Aucun fichier ne correspond", systemImage: "doc")
                } description: {
                    Text("Rien ne correspond à « \(model.searchText) » ici.")
                } actions: {
                    Button("Effacer la recherche") { model.searchText = "" }
                }
            } else if files.isEmpty {
                // The filter has its own wording: "aucun fichier" under a
                // two-year cutoff would read as an empty folder, when the
                // folder is in fact full of things that are simply still in use.
                ContentUnavailableView {
                    Label(
                        model.largeFilesAgeFilter == .all
                            ? "Aucun fichier" : "Rien d'aussi ancien",
                        systemImage: "doc"
                    )
                } description: {
                    Text(model.largeFilesAgeFilter.emptyStateDescription)
                } actions: {
                    if model.largeFilesAgeFilter != .all {
                        Button("Voir toutes les dates") {
                            model.largeFilesAgeFilter = .all
                        }
                    }
                }
            } else {
                loaded(files)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Recherche des fichiers volumineux…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loaded(_ files: [Int32]) -> some View {
        VStack(spacing: 0) {
            summary(files)
            Divider()
            // A real list selection, like the tree and like the Finder. The
            // tick boxes this replaces made "marked for the trash" and "being
            // looked at" the same act, and the inspector reads that one state
            // as the second: ticking a file to compare it with the first
            // emptied the preview pane, since anything past one item routes to
            // a panel with no thumbnail and no path. Without a selection
            // binding there was no keyboard either — the arrow keys belong to
            // the table, and there was no table selection to move.
            NodeList(
                nodes: files,
                selection: Bindable(model).selection,
                // "Ouvrir" here means going to where the file lives: it was
                // pulled out of a subtree, and its own folder is the one thing
                // the row cannot show. The Finder stays one item down.
                primaryAction: { Open.perform($0, in: model) },
                row: { node, isSelected in
                    LargeFileRow(
                        store: store,
                        node: node,
                        size: model.size(of: node),
                        // Relative to the biggest of the list, not to the
                        // folder: a top-100 where every bar is 2 % of the
                        // parent reads as a wall of slivers and says nothing
                        // about the ranking.
                        fraction: Double(model.size(of: node))
                            / Double(max(1, model.size(of: files[0]))),
                        currentPath: store.path(of: model.currentNode),
                        isSelected: isSelected
                    )
                },
                menu: { items in
                    if let node = items.count == 1 ? items.first : nil {
                        Button("Voir dans l'arborescence") { model.reveal(node) }
                        Button("Afficher dans le Finder") {
                            Open.inFinder(store.path(of: node))
                        }
                        Button("Aperçu rapide") {
                            QuickLookPanel.shared.show(
                                [URL(fileURLWithPath: store.path(of: node))]
                            )
                        }
                        Divider()
                    }
                    if !items.isEmpty {
                        Button("Mettre à la corbeille", role: .destructive) {
                            model.requestDeletion(items)
                        }
                    }
                }
            )
        }
    }

    private func summary(_ files: [Int32]) -> some View {
        let total = files.reduce(Int64(0)) { $0 + model.size(of: $1) }
        // A set, not `files.contains`: this is recomputed on every arrow key
        // now that the keyboard walks the list, and a linear scan per selected
        // row through a hundred of them is a scan too many.
        let visible = Set(files)
        let selected = model.selection
            .filter(visible.contains)
            .reduce(Int64(0)) { $0 + model.size(of: $1) }

        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(total))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                caption(files.count)
            }

            Spacer()

            // Only past one row: a single file's size is already in its own row
            // and in the inspector, and a third copy of it flickering at every
            // arrow key is noise. Several is the case where the running total
            // is the point.
            if model.selection.count > 1, selected > 0 {
                Text(Format.bytes(selected))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            if !model.selection.isEmpty {
                Button("Tout désélectionner") { model.selection = [] }
            }
            Button(role: .destructive) {
                model.requestDeletion()
            } label: {
                Label("Mettre à la corbeille", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The subtitle, with its last words turned into the age filter.
    ///
    /// The control *replaces* the caption instead of joining the bar: that bar
    /// already carries a total, a selection size and two buttons, and a picker
    /// wedged in there would be the sixth thing competing for the same glance.
    /// Styled as the running text it grew out of, so the line still reads as a
    /// sentence — "dans les 100 plus gros fichiers, plus d'un an".
    private func caption(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Text("dans les \(Format.count(count)) plus gros fichiers ·")
            Menu {
                Picker("Ancienneté", selection: Binding(
                    get: { model.largeFilesAgeFilter },
                    set: { model.largeFilesAgeFilter = $0 }
                )) {
                    ForEach(AgeFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 2) {
                    Text(model.largeFilesAgeFilter.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("N'afficher que les fichiers qui n'ont pas bougé depuis…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Rows

private struct LargeFileRow: View {
    let store: NodeStore
    let node: Int32
    let size: Int64
    let fraction: Double
    let currentPath: String
    let isSelected: Bool

    var body: some View {
        let flags = store.flags[Int(node)]

        HStack(spacing: 9) {
            Image(nsImage: IconCache.shared.icon(
                name: store.name(of: node),
                isDirectory: flags.contains(.directory),
                isPackage: flags.contains(.package)
            ))
            .resizable()
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(store.name(of: node))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let friendly = AppNames.shared.friendlyName(
                        for: store.name(of: node), path: store.path(of: node)
                    ) {
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
                }

                // The whole point of the extract is files pulled from anywhere
                // in the subtree; without saying where from, the name alone is
                // ten indistinguishable `data.bin`.
                if let relative = relativeFolder {
                    Text(relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .help(store.path(of: node))

            Spacer(minLength: 12)

            // A column of its own rather than another clause appended to the
            // secondary line, which already carries the friendly name, the
            // badge and the containing folder. A column gets scanned; one more
            // "·" in a sentence has to be read.
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(size))
                    .monospacedDigit()
                if let age = Format.age(unixSeconds: store.modTime[Int(node)]) {
                    Text(age)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .proportionBar(fraction, isSelected: isSelected)
    }

    /// Folder holding the file, relative to the folder on screen. Nil for a
    /// direct child: "right here" is what the breadcrumb already says.
    private var relativeFolder: String? {
        let parent = store.path(of: store.parent[Int(node)])
        guard parent != currentPath else { return nil }
        let prefix = currentPath.hasSuffix("/") ? currentPath : currentPath + "/"
        guard parent.hasPrefix(prefix) else { return parent }
        return String(parent.dropFirst(prefix.count))
    }

    private func badgeText(_ flags: NodeFlags) -> String? {
        if flags.contains(.unreadable) { return "illisible" }
        if flags.contains(.package) { return "paquet" }
        if flags.contains(.notDescended) { return "replié" }
        if flags.contains(.symlink) { return "alias" }
        return nil
    }
}
