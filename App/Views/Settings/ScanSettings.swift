import DiskCore
import SwiftUI

/// What a scan walks into, and what it sums without walking.
struct ScanSettings: View {
    @Bindable private var preferences = Preferences.shared

    /// Read from the engine's own defaults rather than retyped here: a second
    /// copy would go stale the first time DiskCore adds a name. Sorted because
    /// it is a Set, and a list whose order changes between launches reads as
    /// a bug.
    private let collapsed = ScanOptions().collapsedDirectoryNames.sorted()

    var body: some View {
        Form {
            Section {
                Toggle("Détailler le contenu des paquets",
                       isOn: $preferences.descendIntoPackages)
                SettingHelp("Les applications et bibliothèques Photos sont traitées comme un seul élément, comme dans le Finder.")
            }

            Section {
                Toggle("Replier les dossiers de dépendances",
                       isOn: $preferences.collapseDependencies)
                SettingHelp("Ces dossiers gardent leur taille exacte mais ne sont pas indexés fichier par fichier. Sur un dossier de développement, cela divise par deux le nombre d'éléments.")
                names
            } footer: {
                // Nothing said this before, and it is the one thing about
                // these two options that surprises: they are read when a scan
                // starts, so the tree already on screen keeps its old shape.
                Text("Ces options sont lues au démarrage d'une analyse : l'arborescence déjà à l'écran n'est pas recalculée, l'effet apparaît à la prochaine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The actual list, rather than the five names the old caption had room
    /// for. "Is my framework in there" is the only question anyone asks of
    /// this setting, and it deserved an answer that is not a trip to the
    /// source.
    private var names: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 5,
                               alignment: .leading)],
            alignment: .leading,
            spacing: 5
        ) {
            ForEach(collapsed, id: \.self) { name in
                Text(name)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
            }
        }
        .foregroundStyle(.secondary)
        .opacity(preferences.collapseDependencies ? 1 : 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
