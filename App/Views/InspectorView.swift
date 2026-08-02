import AppKit
import DiskCore
import QuickLookThumbnailing
import SwiftUI

struct InspectorView: View {
    let model: ScanModel

    var body: some View {
        Group {
            if model.selection.count > 1 {
                MultipleSelection(model: model)
            } else if let store = model.store, let node = model.inspectedNode {
                Details(model: model, store: store, node: node)
            } else {
                ContentUnavailableView(
                    "Aucun scan", systemImage: "sidebar.right",
                    description: Text("Analysez un dossier pour voir son détail.")
                )
            }
        }
        .frame(minWidth: 240)
    }

}

// MARK: - Single item

private struct Details: View {
    let model: ScanModel
    let store: NodeStore
    let node: Int32

    private var path: String { store.path(of: node) }
    private var flags: NodeFlags { store.flags[Int(node)] }
    private var verdict: DeletionVerdict { DenyList.verdict(for: path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                LabeledContent("Taille") {
                    Text(Format.bytes(model.size(of: node)))
                        .monospacedDigit()
                }
                if store.isDirectory(node) {
                    LabeledContent("Contient") {
                        Text("\(Format.count(Int(store.fileCount[Int(node)]))) fichiers")
                    }
                }
                LabeledContent("Emplacement") {
                    Text((path as NSString).deletingLastPathComponent)
                        .lineLimit(3)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }

                if let note = noteForFlags {
                    Callout(text: note, tone: .neutral)
                }
                if let message = verdict.message {
                    Callout(
                        text: message,
                        tone: verdict.isForbidden ? .blocked : .warning
                    )
                }

                Divider()
                actions
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ThumbnailView(path: path, isDirectory: store.isDirectory(node),
                          isPackage: flags.contains(.package))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name(of: node))
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let friendly = AppNames.shared.friendlyName(
                    for: store.name(of: node), path: path
                ) {
                    Text(friendly)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(store.isDirectory(node) ? "Dossier" : "Fichier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)]
                )
            } label: {
                Label("Afficher dans le Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r")

            if model.isApplication(node) {
                Button {
                    model.prepareUninstall(node)
                } label: {
                    Label(
                        model.uninstallPhase == .preparing
                            ? "Recherche des fichiers liés…"
                            : "Désinstaller l'application…",
                        systemImage: "trash.slash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.uninstallPhase == .preparing)
            }

            // Only for directories: the rules match folders, so offering this
            // on a file would always come back empty.
            if store.isDirectory(node) {
                Button {
                    model.cleanFolder(node)
                } label: {
                    Label("Nettoyer ce dossier", systemImage: "wand.and.sparkles")
                        .frame(maxWidth: .infinity)
                }
            }

            Button(role: .destructive) {
                model.selection = [node]
                model.requestDeletion()
            } label: {
                Label("Mettre à la corbeille", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .disabled(verdict.isForbidden)
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    /// Explains the badges the list shows, so "replié" or "lien dur" is not
    /// left as a riddle.
    private var noteForFlags: String? {
        if flags.contains(.unreadable) {
            return "Dossier illisible — son contenu n'est pas compté. Activez l'accès complet au disque."
        }
        if flags.contains(.hardlinkDuplicate) {
            return "Autre nom d'un fichier déjà compté ailleurs. Le supprimer ne libère rien."
        }
        if flags.contains(.notDescended) && flags.contains(.package) {
            return "Paquet traité comme un seul élément, comme dans le Finder."
        }
        if flags.contains(.notDescended) {
            return "Contenu replié : la taille est exacte, le détail par fichier n'est pas indexé."
        }
        if flags.contains(.symlink) {
            return "Lien symbolique. Il n'occupe pratiquement rien et n'a pas été suivi."
        }
        return nil
    }
}

// MARK: - Multiple items

private struct MultipleSelection: View {
    let model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.selection.count) éléments")
                .font(.headline)
            LabeledContent("Taille totale") {
                Text(Format.bytes(
                    model.selection.reduce(0) { $0 + model.size(of: $1) }
                ))
                .monospacedDigit()
            }
            Divider()
            Button(role: .destructive) {
                model.requestDeletion()
            } label: {
                Label("Mettre à la corbeille", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Spacer()
        }
        .padding(14)
    }
}

// MARK: - Pieces

private struct Callout: View {
    enum Tone { case neutral, warning, blocked }
    let text: String
    let tone: Tone

    private var symbol: String {
        switch tone {
        case .neutral: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocked: "lock"
        }
    }

    private var tint: Color {
        switch tone {
        case .neutral: .secondary
        case .warning: .orange
        case .blocked: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 7))
    }
}

/// Quick Look thumbnail, falling back to the file-type icon.
///
/// Uses the thumbnail service rather than a live `QLPreviewView`: this panel can
/// be re-rendered on every selection change, and spinning up a preview each time
/// would be far heavier than the picture it produces.
private struct ThumbnailView: View {
    let path: String
    let isDirectory: Bool
    let isPackage: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: IconCache.shared.icon(
                    name: (path as NSString).lastPathComponent,
                    isDirectory: isDirectory, isPackage: isPackage
                ))
                .resizable()
                .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 52, height: 52)
        .task(id: path) { await load() }
    }

    private func load() async {
        thumbnail = nil
        guard !isDirectory || isPackage else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 104, height: 104),
            scale: 2,
            representationTypes: .thumbnail
        )
        let generated = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
        guard !Task.isCancelled else { return }
        thumbnail = generated?.nsImage
    }
}
