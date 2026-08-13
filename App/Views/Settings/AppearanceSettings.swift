import SwiftUI

/// Light or dark, and what the two visualisations paint with.
struct AppearanceSettings: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Thème", selection: $preferences.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                SettingHelp("Les couleurs de la vue Anneaux ont deux jeux distincts, vérifiés séparément en clair et en sombre — ce n'est pas la même palette éclaircie.")
            }

            Section {
                Picker("Couleurs", selection: $preferences.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                SettingHelp("Dans les vues Anneaux et Blocs : une teinte par dossier de premier niveau, ou une échelle allant du récent à l'oublié. Se change aussi depuis le menu Présentation.")
            }
        }
        .formStyle(.grouped)
    }
}
