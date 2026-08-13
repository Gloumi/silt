import AppKit

/// Adding and removing the folders pinned to the sidebar.
///
/// Both doors go through here: the `+` in the sidebar header and the
/// Emplacements settings pane. Two open panels with slightly different prompts,
/// or two different ideas of what to do when the folder being removed is the
/// one on screen, is the kind of drift nobody notices until it is a bug report.
@MainActor
enum PinnedLocations {

    /// Asks for a folder. Nil when the user cancelled.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ajouter"
        panel.message = "Choisissez un dossier à garder dans la liste."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Pins a folder and moves the window to it — adding one is always the
    /// prelude to looking at it.
    static func add(to model: ScanModel) {
        guard let url = choose() else { return }
        Preferences.shared.addLocation(url.path)
        model.select(path: url.path, name: QuickLocation.displayName(of: url.path))
    }

    /// Unpins a folder, and moves the window off it if that is where it was:
    /// a selection left on a row that no longer exists strands the window on
    /// it. The scan root is the closest thing to where the user already was;
    /// the boot volume, then the home folder, are what is left when there is
    /// no root — the settings pane has no volume list to offer.
    static func remove(_ path: String, from model: ScanModel,
                       fallback: VolumeInfo? = nil) {
        Preferences.shared.removeLocation(path)
        guard model.selectedRoot == path else { return }
        if let root = model.rootPath {
            model.select(path: root)
        } else if let fallback {
            model.select(path: fallback.url.path, name: fallback.name)
        } else {
            model.select(path: FileManager.default.homeDirectoryForCurrentUser.path)
        }
    }
}
