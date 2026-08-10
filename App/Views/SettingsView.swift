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

/// The ladder both duplicate thresholds move along: 1, 2, 5 per decade.
///
/// A slider rather than a menu because the interesting range is at the bottom.
/// Photos — the single most duplicated thing anyone owns — sit between about
/// 300 Ko and 3 Mo, and a floor of 1 Mo made the feature blind to half of
/// them; on a real home folder the 512 Ko–1 Mo band alone held as many files
/// as everything above 1 Mo put together.
///
/// Stepped rather than continuous, because "473 Ko" is a value nobody chose
/// and every label would read like a measurement error. Non-proportional,
/// because precision is worth something at 200 Ko and nothing whatsoever
/// between 400 and 500 Mo — which is exactly what a logarithmic ladder buys.
enum SizeLadder {

    /// Floor at 50 Ko on purpose: below it are thumbnails, icons and
    /// `.DS_Store`, duplicated everywhere and worth deleting nowhere.
    static let file: [Int64] = [
        50_000, 100_000, 200_000, 500_000,
        1_000_000, 2_000_000, 5_000_000,
        10_000_000, 20_000_000, 50_000_000,
        100_000_000, 200_000_000, 500_000_000, 1_000_000_000,
    ]

    /// Starts higher: confirming a folder means reading every file inside it,
    /// so the cheap end of this ladder is not cheap at all.
    static let folder: [Int64] = [
        1_000_000, 2_000_000, 5_000_000,
        10_000_000, 20_000_000, 50_000_000,
        100_000_000, 200_000_000, 500_000_000,
        1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000,
    ]

    /// Nearest rung, so a value stored by an older build — the three-way menu
    /// wrote plain byte counts, which is why no migration is needed — always
    /// lands somewhere sensible.
    static func index(of bytes: Int64, in ladder: [Int64]) -> Int {
        ladder.enumerated().min {
            abs($0.element - bytes) < abs($1.element - bytes)
        }?.offset ?? 0
    }

    static func bytes(at index: Int, in ladder: [Int64]) -> Int64 {
        ladder[min(max(index, 0), ladder.count - 1)]
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
        static let duplicateFolderThreshold = "duplicateFolderSizeThreshold"
    }

    /// Both thresholds are plain byte counts, which is what the three-way menus
    /// they replace already wrote — so an existing setting reads back as the
    /// rung nearest to itself and nobody's choice is lost.
    /// 500 Ko rather than the 1 Mo of the three-way menu this replaces.
    /// Measured on a real home folder, the move costs 1,7× the candidates and
    /// about 440 Mo to read, and it is the difference between seeing duplicate
    /// photos and not: most sit between 300 Ko and 3 Mo.
    static let defaultDuplicateThreshold: Int64 = 500_000
    static let defaultDuplicateFolderThreshold: Int64 = 100_000_000

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
    var duplicateThresholdBytes: Int64 {
        didSet {
            UserDefaults.standard.set(Int(duplicateThresholdBytes),
                                      forKey: Key.duplicateThreshold)
        }
    }

    /// Floor of the folder pass of the same view. Higher than the file floor
    /// by default: confirming a folder means reading every file in it.
    var duplicateFolderThresholdBytes: Int64 {
        didSet {
            UserDefaults.standard.set(Int(duplicateFolderThresholdBytes),
                                      forKey: Key.duplicateFolderThreshold)
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
        let storedFile = Int64(defaults.integer(forKey: Key.duplicateThreshold))
        duplicateThresholdBytes = storedFile > 0
            ? SizeLadder.bytes(
                at: SizeLadder.index(of: storedFile, in: SizeLadder.file),
                in: SizeLadder.file)
            : Self.defaultDuplicateThreshold
        let storedFolder = Int64(
            defaults.integer(forKey: Key.duplicateFolderThreshold)
        )
        duplicateFolderThresholdBytes = storedFolder > 0
            ? SizeLadder.bytes(
                at: SizeLadder.index(of: storedFolder, in: SizeLadder.folder),
                in: SizeLadder.folder)
            : Self.defaultDuplicateFolderThreshold
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
    private var estimator = ThresholdEstimate.shared
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

                threshold(
                    "Doublons — fichiers d'au moins",
                    bytes: $preferences.duplicateThresholdBytes,
                    ladder: SizeLadder.file,
                    help: "Seuls les fichiers d'au moins cette taille sont comparés. Descendre sous 1 Mo est ce qu'il faut faire pour retrouver des photos en double — la plupart pèsent entre 300 Ko et 3 Mo — mais le coût ne baisse pas proportionnellement : les petites tailles se répètent bien plus souvent, et sous 128 Ko chaque fichier est lu en entier au lieu d'être lu partiellement."
                )

                threshold(
                    "Doublons — dossiers d'au moins",
                    bytes: $preferences.duplicateFolderThresholdBytes,
                    ladder: SizeLadder.folder,
                    help: "Les dossiers entièrement identiques sont proposés en tête de la vue Doublons, et les fichiers qu'ils contiennent y sont regroupés. Confirmer un dossier oblige à lire chacun de ses fichiers, quelle que soit sa taille : un seuil bas coûte cher sur un disque de développement."
                )

                estimate
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
        // Sized rather than fitted. `fixedSize(vertical:)` made the window as
        // tall as its content, which was fine while the content was short and
        // ran off the bottom of the screen the moment the two sliders and their
        // explanations arrived. The grouped Form scrolls on its own; it just
        // needs to be told it has a bottom.
        .frame(width: 460, height: 620)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in accessGranted = FullDiskAccess.isGranted }
    }

    // MARK: - A threshold and what it costs

    /// The slider drives an *index* into the ladder, so every position is a
    /// value someone would actually write down.
    private func threshold(
        _ title: String, bytes: Binding<Int64>, ladder: [Int64], help: String
    ) -> some View {
        let index = Binding(
            get: { Double(SizeLadder.index(of: bytes.wrappedValue, in: ladder)) },
            set: { bytes.wrappedValue = SizeLadder.bytes(at: Int($0), in: ladder) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(Format.bytes(bytes.wrappedValue))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            // A bare `Slider`, with the bounds written beside it by hand. Given
            // a label — even an empty one — a Form reserves its label column
            // and the track ends up squeezed into the right half of the row.
            HStack(spacing: 8) {
                Text(Format.bytes(ladder.first ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: index, in: 0...Double(ladder.count - 1), step: 1)
                    // Without this a grouped Form still reserves its label
                    // column for the control, and the track ends up squeezed
                    // into the right half of the row with dead space beside it.
                    .labelsHidden()
                Text(Format.bytes(ladder.last ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let count = estimator.candidates(above: bytes.wrappedValue),
               let toRead = estimator.bytesToRead(above: bytes.wrappedValue) {
                // One walk answered every rung, so this follows the thumb
                // instead of arriving after the pass has already cost the time.
                Text("≈ \(Format.count(count)) fichiers à comparer, \(Format.bytes(toRead)) à lire")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The census behind the figures above. Off by default and asked for
    /// explicitly: it walks the whole home folder, and taking minutes of disk
    /// the moment someone opens Settings would be a poor trade for a number
    /// they may not have come for.
    @ViewBuilder
    private var estimate: some View {
        switch estimator.phase {
        case .running(let seen):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Estimation en cours — \(Format.count(seen)) fichiers parcourus")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { estimator.cancel() }
                    .controlSize(.small)
            }
        case .ready:
            HStack(spacing: 9) {
                Text("Estimation faite sur \(estimator.root) — indicative : la vue Doublons ne compare que le dossier où vous vous trouvez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Recalculer") { estimator.measure() }
                    .controlSize(.small)
            }
        case .failed:
            HStack(spacing: 9) {
                Text("Le dossier personnel n'a pas pu être parcouru.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Réessayer") { estimator.measure() }
                    .controlSize(.small)
            }
        case .idle:
            HStack(spacing: 9) {
                Text("Une analyse préalable de votre dossier personnel dit combien de fichiers chaque seuil ferait comparer. Elle ne lit aucun contenu, seulement les tailles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Estimer") { estimator.measure() }
                    .controlSize(.small)
            }
        }
    }
}
