import AppKit
import DiskCore
import SwiftUI

/// The "Corbeille" tool: what Silt has put in the trash and can still put back.
///
/// Its reason to exist is the gap the banner leaves. That undo dies when the
/// message is dismissed and again when the app quits, and the Finder's own
/// "Remettre" is missing on precisely the deletions that most need undoing —
/// anything the Finder had to trash on our behalf. This list is what remains
/// true afterwards.
struct TrashView: View {
    let model: ScanModel

    @State private var selection: Set<String> = []
    @State private var isWorking = false

    private var entries: [TrashLedgerEntry] { model.restorable }
    private var selected: [TrashLedgerEntry] {
        entries.filter { selection.contains($0.id) }
    }

    var body: some View {
        content
            .task { await model.refreshRestorable() }
            // The trash also changes from outside this tool — a deletion, an
            // undo, a Finder emptying. The epoch is how the other tools hear
            // about it, and this one has more reason than most to listen.
            .onChange(of: model.deletionEpoch) {
                Task { await model.refreshRestorable() }
            }
            .onChange(of: entries.map(\.id)) { _, ids in
                // Never leave a tick on something that has left the trash.
                selection.formIntersection(Set(ids))
            }
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("Rien à restaurer", systemImage: "trash")
            } description: {
                Text("Silt n'a rien mis à la corbeille, ou tout ce qu'il y avait mis en est déjà ressorti.")
            } actions: {
                Button("Ouvrir la corbeille", action: openTrash)
            }
        } else {
            VStack(spacing: 0) {
                summary
                List {
                    Section {
                        ForEach(entries) { entry in
                            TrashRow(
                                entry: entry,
                                isSelected: selection.contains(entry.id),
                                toggle: { toggle(entry) }
                            )
                        }
                    } footer: {
                        Text("Ces éléments sont toujours dans la corbeille. Les restaurer les remet à leur emplacement d'origine ; vider la corbeille les supprime définitivement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(entries.reduce(0) { $0 + $1.bytes }))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("\(entries.count) élément(s) restaurable(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !selected.isEmpty {
                Divider().frame(height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.bytes(selected.reduce(0) { $0 + $1.bytes }))
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                    Text("sélectionné(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Tout sélectionner") {
                selection = Set(entries.map(\.id))
            }
            .buttonStyle(.link)
            .disabled(selection.count == entries.count)

            Button {
                Task {
                    isWorking = true
                    await model.restoreFromTrash(selected)
                    isWorking = false
                }
            } label: {
                Label("Restaurer", systemImage: "arrow.uturn.backward")
            }
            .disabled(selected.isEmpty || isWorking)

            Button(role: .destructive) {
                Task {
                    isWorking = true
                    await model.emptyTrash()
                    isWorking = false
                }
            } label: {
                Label("Vider la corbeille", systemImage: "trash")
            }
            .disabled(isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func toggle(_ entry: TrashLedgerEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) }
        else { selection.insert(entry.id) }
    }

    private func openTrash() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
        )
    }
}

// MARK: - Row

private struct TrashRow: View {
    let entry: TrashLedgerEntry
    let isSelected: Bool
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // The ones this whole tool exists for: the Finder trashed
                    // them on our behalf, and its own "Remettre" may be gone.
                    if entry.viaFinder {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Mis à la corbeille par le Finder : « Remettre » peut y être indisponible, restaurez-le ici.")
                    }
                }
                Text(entry.originalFolder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(entry.originalPath)

            Spacer(minLength: 10)

            Button(action: revealInFinder) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Afficher dans la corbeille")
            .accessibilityLabel("Afficher dans la corbeille")

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(entry.bytes))
                    .monospacedDigit()
                    .fontWeight(.medium)
                Text(entry.trashedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button("Afficher dans la corbeille", action: revealInFinder)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: entry.trashPath)]
        )
    }
}
