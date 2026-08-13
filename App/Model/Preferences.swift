import AppKit
import DiskCore
import Observation

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

    /// Back to what a fresh install has. Assigning the properties rather than
    /// deleting the keys: every `didSet` above writes storage and, for the
    /// appearance, repaints the app — going behind them would leave the
    /// running window showing the old values until relaunch.
    ///
    /// Pinned locations and their per-folder views survive on purpose. Losing
    /// the folders you added to the sidebar to a button called "réinitialiser
    /// les réglages" is a surprise nobody asked for, and the Emplacements pane
    /// already has a way to remove them one at a time. `hasSeenWelcome` and
    /// `lastUsedPresentation` are app state rather than settings — clearing
    /// the first would replay the welcome sheet at the next launch.
    func resetToDefaults() {
        useLogicalSize = false
        descendIntoPackages = false
        collapseDependencies = true
        appearance = .system
        defaultView = .fixed(.sunburst)
        colorMode = .category
        largeFilesAgeFilter = .all
        duplicateThresholdBytes = Self.defaultDuplicateThreshold
        duplicateFolderThresholdBytes = Self.defaultDuplicateFolderThreshold
        recentSearches = []
    }

    /// Scan options matching the current preferences.
    func scanOptions() -> ScanOptions {
        var options = ScanOptions()
        options.descendIntoPackages = descendIntoPackages
        if !collapseDependencies { options.collapsedDirectoryNames = [] }
        return options
    }
}
