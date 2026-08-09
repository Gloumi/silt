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

/// Below what size the duplicates view stops looking. The steps are coarse on
/// purpose: this decides how much of the disk gets read, not what counts as
/// "identical".
enum DuplicateThreshold: Int, CaseIterable, Identifiable {
    case oneMB = 1_000_000
    case tenMB = 10_000_000
    case hundredMB = 100_000_000

    var id: Int { rawValue }
    var bytes: Int64 { Int64(rawValue) }

    var label: String {
        switch self {
        case .oneMB: "1 Mo"
        case .tenMB: "10 Mo"
        case .hundredMB: "100 Mo"
        }
    }
}

/// The global "default view" choice: a fixed presentation, or whatever
/// browsing view was on screen last.
enum DefaultViewSetting: RawRepresentable, Hashable {
    case fixed(ScanModel.Presentation)
    case lastUsed

    init?(rawValue: String) {
        if rawValue == "lastUsed" {
            self = .lastUsed
        } else if let presentation = ScanModel.Presentation(rawValue: rawValue),
                  ScanModel.Presentation.browsing.contains(presentation) {
            self = .fixed(presentation)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .fixed(let presentation): presentation.rawValue
        case .lastUsed: "lastUsed"
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
        static let defaultPresentation = "defaultPresentation"
        static let lastPresentation = "lastUsedPresentation"
        static let folderPresentations = "folderPresentations"
        static let colorMode = "colorMode"
        static let largeFilesAge = "largeFilesAgeFilter"
        static let recentSearches = "recentSearches"
        static let duplicateThreshold = "duplicateSizeThreshold"
    }

    /// Queries the user has actually run, most recent first.
    ///
    /// Offered from the search field's magnifying glass, the way every macOS
    /// search field has since forever. Capped hard: this is a shortcut back to
    /// something you just looked for, not a history you are meant to browse.
    private(set) var recentSearches: [String] = [] {
        didSet {
            UserDefaults.standard.set(recentSearches, forKey: Key.recentSearches)
        }
    }

    static let recentSearchLimit = 8

    func rememberSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive de-dup so "DMG" does not sit under ".dmg" twice, and
        // re-running an old query moves it back to the top rather than adding
        // a second copy.
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        if recentSearches.count > Self.recentSearchLimit {
            recentSearches.removeLast(recentSearches.count - Self.recentSearchLimit)
        }
    }

    func clearRecentSearches() {
        recentSearches = []
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
        setPresentation(nil, for: path)
    }

    /// What a selection falls back to when the folder has no view of its own:
    /// a fixed view, or the one that was on screen last.
    var defaultView: DefaultViewSetting {
        didSet {
            UserDefaults.standard.set(defaultView.rawValue,
                                      forKey: Key.defaultPresentation)
        }
    }

    /// The last browsing view that held the window, persisted so "Dernière
    /// utilisée" survives a relaunch. ScanModel keeps it current.
    var lastUsedPresentation: ScanModel.Presentation {
        didSet {
            UserDefaults.standard.set(lastUsedPresentation.rawValue,
                                      forKey: Key.lastPresentation)
        }
    }

    /// The view a selection should land in when the folder has no override.
    var resolvedDefaultView: ScanModel.Presentation {
        switch defaultView {
        case .fixed(let presentation): presentation
        case .lastUsed: lastUsedPresentation
        }
    }

    /// Per-folder view overrides, keyed by path. Raw strings in storage; the
    /// typed accessors below are the only doors in and out.
    private var folderPresentations: [String: String] {
        didSet {
            UserDefaults.standard.set(folderPresentations,
                                      forKey: Key.folderPresentations)
        }
    }

    /// The view this folder asked for, or nil to follow the global default.
    func presentation(for path: String) -> ScanModel.Presentation? {
        folderPresentations[path]
            .flatMap(ScanModel.Presentation.init(rawValue:))
            .flatMap { ScanModel.Presentation.browsing.contains($0) ? $0 : nil }
    }

    /// Nil clears the override. Tool presentations are refused: cleanup and
    /// reboot are destinations, not ways of looking at a folder.
    func setPresentation(_ presentation: ScanModel.Presentation?, for path: String) {
        if let presentation, ScanModel.Presentation.browsing.contains(presentation) {
            folderPresentations[path] = presentation.rawValue
        } else {
            folderPresentations.removeValue(forKey: path)
        }
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

    /// What the treemap and the sunburst paint with: the branch a slice belongs
    /// to, or how long ago it was last touched.
    var colorMode: ColorMode {
        didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: Key.colorMode) }
    }

    /// The age filter of the large-files view. Persisted like the other view
    /// state: coming back to a list that forgot the filter you set is a small
    /// betrayal every single time.
    var largeFilesAgeFilter: AgeFilter {
        didSet {
            UserDefaults.standard.set(largeFilesAgeFilter.rawValue,
                                      forKey: Key.largeFilesAge)
        }
    }

    /// Floor of the duplicates view. Deciding how much disk the feature may
    /// read belongs with the other scan-cost options, not in the view itself.
    var duplicateThreshold: DuplicateThreshold {
        didSet {
            UserDefaults.standard.set(duplicateThreshold.rawValue,
                                      forKey: Key.duplicateThreshold)
        }
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
        defaultView = defaults.string(forKey: Key.defaultPresentation)
            .flatMap(DefaultViewSetting.init(rawValue:)) ?? .fixed(.sunburst)
        lastUsedPresentation = defaults.string(forKey: Key.lastPresentation)
            .flatMap(ScanModel.Presentation.init(rawValue:))
            .flatMap { ScanModel.Presentation.browsing.contains($0) ? $0 : nil }
            ?? .sunburst
        folderPresentations = defaults.dictionary(forKey: Key.folderPresentations)
            as? [String: String] ?? [:]
        colorMode = defaults.string(forKey: Key.colorMode)
            .flatMap(ColorMode.init(rawValue:)) ?? .category
        largeFilesAgeFilter = defaults.string(forKey: Key.largeFilesAge)
            .flatMap(AgeFilter.init(rawValue:)) ?? .all
        recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        duplicateThreshold = DuplicateThreshold(
            rawValue: defaults.integer(forKey: Key.duplicateThreshold)
        ) ?? .oneMB
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

                Picker("Vue par défaut", selection: $preferences.defaultView) {
                    ForEach(ScanModel.Presentation.browsing) {
                        Text($0.label).tag(DefaultViewSetting.fixed($0))
                    }
                    Divider()
                    Text("Dernière utilisée").tag(DefaultViewSetting.lastUsed)
                }
                Text("Vue appliquée à chaque sélection dans la barre latérale ; « Dernière utilisée » conserve la vue en cours d'un dossier à l'autre. Un clic droit sur un élément permet de lui attribuer sa propre vue par défaut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Couleurs", selection: $preferences.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                Text("Dans les vues Anneaux et Blocs : une teinte par dossier de premier niveau, ou une échelle allant du récent à l'oublié. Se change aussi depuis le menu Présentation.")
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
                Text("node_modules, .git, .next, vendor, .venv gardent leur taille exacte mais ne sont pas indexés fichier par fichier. Sur un dossier de développement, cela divise par deux le nombre d'éléments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Doublons — taille minimale", selection: $preferences.duplicateThreshold) {
                    ForEach(DuplicateThreshold.allCases) { Text($0.label).tag($0) }
                }
                Text("Seuls les fichiers d'au moins cette taille sont comparés dans la vue Doublons. Un seuil plus bas en trouve davantage, mais allonge la lecture du disque.")
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
