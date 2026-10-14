import SwiftUI

/// What a selection lands in, what a size means, and the way back to defaults.
struct GeneralSettings: View {
    @Bindable private var preferences = Preferences.shared
    @State private var confirmingReset = false
    private let updates = UpdateChecker.shared
    /// Its own sheet rather than the main window's: the one asked for from
    /// here should open in front of here.
    @State private var shownRelease: Release?

    var body: some View {
        Form {
            Section {
                Picker("Vue par défaut", selection: $preferences.defaultView) {
                    ForEach(ScanModel.Presentation.browsing) {
                        Text($0.label).tag(DefaultViewSetting.fixed($0))
                    }
                    Divider()
                    Text("Dernière utilisée").tag(DefaultViewSetting.lastUsed)
                }
                SettingHelp("Vue appliquée à chaque sélection dans la barre latérale ; « Dernière utilisée » conserve la vue en cours d'un dossier à l'autre. Un clic droit sur un élément lui attribue sa propre vue, et les dossiers ajoutés se règlent aussi depuis Emplacements.")
            }

            Section {
                Picker("Taille affichée", selection: $preferences.useLogicalSize) {
                    Text("Occupée sur le disque").tag(false)
                    Text("Taille logique").tag(true)
                }
                SettingHelp(preferences.useLogicalSize
                    ? "Somme du contenu des fichiers, sans tenir compte de la compression ni des blocs partiellement remplis."
                    : "Ce que le disque perd réellement — la mesure que donne « du » et que le Finder utilise pour l'espace libre.")
            }

            Section {
                Toggle("Rechercher les mises à jour automatiquement",
                       isOn: $preferences.checksForUpdates)
                LabeledContent {
                    HStack {
                        if let release = updates.newerRelease {
                            Button("Voir…") { shownRelease = release }
                        }
                        Button("Rechercher maintenant") {
                            Task { await updates.check(manual: true) }
                        }
                        .disabled(updates.state == .checking)
                    }
                } label: {
                    Text("Version \(updates.currentVersionText)")
                    Text(updates.statusText)
                }
                SettingHelp("Une requête anonyme vers GitHub une fois par jour ; rien d'autre n'est envoyé. Silt ne télécharge rien lui-même.")
            }

            Section {
                LabeledContent("Réglages") {
                    Button("Réinitialiser…") { confirmingReset = true }
                }
                SettingHelp("Ramène le thème, les vues par défaut, les options d'analyse, les seuils de doublons et les recherches récentes à leur valeur d'origine. Les emplacements épinglés et leur vue ne sont pas touchés.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $shownRelease) { release in
            UpdateSheet(release: release) { shownRelease = nil }
        }
        .confirmationDialog(
            "Réinitialiser tous les réglages ?",
            isPresented: $confirmingReset
        ) {
            Button("Réinitialiser", role: .destructive) {
                preferences.resetToDefaults()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les emplacements épinglés sont conservés. Cette action ne peut pas être annulée.")
        }
    }
}
