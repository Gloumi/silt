import Foundation
import SwiftUI

/// The folders pinned to the sidebar, and the view each one opens in.
///
/// Neither was reachable from Settings before: adding went through a `+` in a
/// section header, removing and setting a folder's own view through a context
/// menu. A context menu is a fine shortcut and a poor only door — nothing on
/// screen said the per-folder view existed at all.
struct LocationsSettings: View {
    let model: ScanModel
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                if preferences.customLocations.isEmpty {
                    Text("Aucun dossier ajouté.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(preferences.customLocations, id: \.self) { row($0) }
                }
                Button {
                    PinnedLocations.add(to: model)
                } label: {
                    Label("Ajouter un dossier…", systemImage: "plus")
                }
            } footer: {
                Text("Ces dossiers apparaissent dans la barre latérale, sous les emplacements standards. « Vue par défaut » ne vaut que pour le dossier de sa ligne et l'emporte sur le réglage global — c'est le même choix que le clic droit dans la barre latérale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ path: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(QuickLocation.displayName(of: path))
                // Truncated at the head: the end of a path is what tells two
                // folders called "Projets" apart.
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(path)
            Spacer(minLength: 10)
            Picker("", selection: defaultView(for: path)) {
                Text("Globale").tag(ScanModel.Presentation?.none)
                Divider()
                ForEach(ScanModel.Presentation.browsing) {
                    Text($0.label).tag(ScanModel.Presentation?.some($0))
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                PinnedLocations.remove(path, from: model)
            } label: {
                Image(systemName: "minus.circle.fill").imageScale(.large)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Retirer de la liste")
        }
    }

    /// Nil is "follow the global setting", which is what clearing the override
    /// means — the same binding the sidebar's context menu writes.
    private func defaultView(for path: String) -> Binding<ScanModel.Presentation?> {
        Binding(
            get: { preferences.presentation(for: path) },
            set: { new in
                preferences.setPresentation(new, for: path)
                // Seeing the change at once beats waiting for the next
                // selection — but only when this folder is the one on screen.
                if model.selectedRoot == path, let new { model.presentation = new }
            }
        )
    }
}
