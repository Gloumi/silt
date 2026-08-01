import AppKit
import DiskCore
import SwiftUI

/// The sorted-list view of one directory. Lot 3 adds the sunburst beside it;
/// this stays as the precise, keyboard-friendly counterpart.
struct BrowserView: View {
    let model: ScanModel
    @State private var selection: Int32?

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyStateView()
            case .scanning(let progress):
                ScanningView(progress: progress) { model.cancel() }
            case .failed(let message):
                ContentUnavailableView(
                    "Scan impossible", systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .loaded:
                loadedContent
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let store = model.store {
            let parentSize = max(1, model.size(of: model.currentNode))
            VStack(spacing: 0) {
                BreadcrumbBar(model: model, store: store)
                Divider()
                switch model.presentation {
                case .sunburst:
                    SunburstView(model: model).padding(8)
                case .list:
                    entryList(store: store, parentSize: parentSize)
                }
                StatusBar(model: model, store: store)
            }
        }
    }

    @ViewBuilder
    private func entryList(store: NodeStore, parentSize: Int64) -> some View {
        ZStack {
            List(model.rows, id: \.self, selection: $selection) { node in
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
                    }
                }
            .listStyle(.inset)
            if model.rows.isEmpty {
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
                    .disabled(depth == model.trail.count - 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .scrollIndicators(.never)
        .background(.bar)
    }
}

private struct StatusBar: View {
    let model: ScanModel
    let store: NodeStore

    var body: some View {
        HStack(spacing: 10) {
            Text("\(Format.count(model.rows.count)) éléments")
            Text("·")
            Text("\(Format.count(Int(store.fileCount[Int(model.currentNode)]))) fichiers au total")
            Spacer()
            if let result = model.result, !result.unreadablePaths.isEmpty {
                Label(
                    "\(result.unreadablePaths.count) dossiers illisibles",
                    systemImage: "lock"
                )
                .foregroundStyle(.orange)
                .help("Activez l'accès complet au disque pour les inclure.")
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

private struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Aucun scan", systemImage: "chart.pie")
        } description: {
            Text("Choisissez un volume ou un emplacement dans la barre latérale.")
        }
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
