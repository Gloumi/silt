import AppKit
import DiskCore
import SwiftUI

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Système"
        case .light: "Clair"
        case .dark: "Sombre"
        }
    }

    /// Nil means "follow the system", which is what an unset appearance does.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Persisted preferences. Kept deliberately short — every option here is one the
/// engine genuinely behaves differently for, not a knob for its own sake.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let logicalSize = "useLogicalSize"
        static let descendPackages = "descendIntoPackages"
        static let collapseDependencies = "collapseDependencies"
        static let seenWelcome = "hasSeenWelcome"
        static let appearance = "appearance"
        static let customLocations = "customLocations"
    }

    /// Folders the user pinned to the sidebar, in the order they added them.
    ///
    /// Plain paths rather than security-scoped bookmarks: the app is not
    /// sandboxed, so a path is all it takes to read one back.
    private(set) var customLocations: [String] {
        didSet {
            UserDefaults.standard.set(customLocations, forKey: Key.customLocations)
        }
    }

    func addLocation(_ path: String) {
        guard !customLocations.contains(path) else { return }
        customLocations.append(path)
    }

    func removeLocation(_ path: String) {
        customLocations.removeAll { $0 == path }
    }

    /// Applied to `NSApp` rather than through `preferredColorScheme`, which
    /// only reaches the view it is attached to — the Settings window, the menu
    /// bar and every sheet would keep following the system.
    var appearance: AppearanceSetting {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance)
            applyAppearance()
        }
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.appearance
    }

    var useLogicalSize: Bool {
        didSet { UserDefaults.standard.set(useLogicalSize, forKey: Key.logicalSize) }
    }
    var descendIntoPackages: Bool {
        didSet { UserDefaults.standard.set(descendIntoPackages, forKey: Key.descendPackages) }
    }
    var collapseDependencies: Bool {
        didSet { UserDefaults.standard.set(collapseDependencies, forKey: Key.collapseDependencies) }
    }
    var hasSeenWelcome: Bool {
        didSet { UserDefaults.standard.set(hasSeenWelcome, forKey: Key.seenWelcome) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.collapseDependencies: true])
        useLogicalSize = defaults.bool(forKey: Key.logicalSize)
        descendIntoPackages = defaults.bool(forKey: Key.descendPackages)
        collapseDependencies = defaults.bool(forKey: Key.collapseDependencies)
        hasSeenWelcome = defaults.bool(forKey: Key.seenWelcome)
        appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AppearanceSetting.init(rawValue:)) ?? .system
        customLocations = defaults.stringArray(forKey: Key.customLocations) ?? []
    }

    /// Scan options matching the current preferences.
    func scanOptions() -> ScanOptions {
        var options = ScanOptions()
        options.descendIntoPackages = descendIntoPackages
        if !collapseDependencies { options.collapsedDirectoryNames = [] }
        return options
    }
}

struct SettingsView: View {
    @Bindable private var preferences = Preferences.shared
    @State private var accessGranted = FullDiskAccess.isGranted

    var body: some View {
        Form {
            Section("Apparence") {
                Picker("Thème", selection: $preferences.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Les couleurs de la vue Anneaux ont deux jeux distincts, vérifiés séparément en clair et en sombre — ce n'est pas la même palette éclaircie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mesure") {
                Picker("Taille affichée", selection: $preferences.useLogicalSize) {
                    Text("Occupée sur le disque").tag(false)
                    Text("Taille logique").tag(true)
                }
                Text(preferences.useLogicalSize
                     ? "Somme du contenu des fichiers, sans tenir compte de la compression ni des blocs partiellement remplis."
                     : "Ce que le disque perd réellement — la mesure que donne « du » et que le Finder utilise pour l'espace libre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Analyse") {
                Toggle("Détailler le contenu des paquets", isOn: $preferences.descendIntoPackages)
                Text("Les applications et bibliothèques Photos sont traitées comme un seul élément, comme dans le Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Replier les dossiers de dépendances", isOn: $preferences.collapseDependencies)
                Text("node_modules, .git, vendor, .venv gardent leur taille exacte mais ne sont pas indexés fichier par fichier. Sur un dossier de développement, cela divise par deux le nombre d'éléments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Autorisations") {
                LabeledContent("Accès complet au disque") {
                    HStack(spacing: 7) {
                        Image(systemName: accessGranted
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(accessGranted ? .green : .orange)
                        Text(accessGranted ? "Accordé" : "Non accordé")
                        if !accessGranted {
                            Button("Réglages…") { FullDiskAccess.openSettings() }
                        }
                    }
                }
                if !accessGranted {
                    Text("Sans cette autorisation, Mail, Messages, Photos et les sauvegardes d'appareils restent invisibles et manquent aux totaux.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in accessGranted = FullDiskAccess.isGranted }
    }
}
