import AppKit
import Foundation

/// Whether macOS is letting us read everything, and how to ask if not.
///
/// There is no API for this. Apple exposes no way to query a TCC permission,
/// and no way to request Full Disk Access programmatically — the user has to
/// grant it in System Settings and the app has to be relaunched. So the check
/// is empirical: try to read a file that only an app with Full Disk Access can
/// read, and see what happens.
enum FullDiskAccess {

    /// TCC's own database. Readable only with Full Disk Access, and present on
    /// every Mac — the usual probe for this.
    private static var probePaths: [String] {
        [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    static var isGranted: Bool {
        probePaths.contains { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? handle.close() }
            // Opening can succeed where reading fails, so actually read a byte.
            return (try? handle.read(upToCount: 1)) != nil
        }
    }

    /// Opens the exact pane, since telling someone to "go to Privacy settings"
    /// and leaving them to find it is most of the friction.
    static func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!
        NSWorkspace.shared.open(url)
    }

    /// Reveals the app in the Finder, so it can be dragged into the permission
    /// list — the step people get stuck on when the app is not already listed.
    static func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// « Gestion des apps » — the permission that, since macOS 13, gates deleting
/// or modifying *another* application's bundle. Full Disk Access does not
/// stand in for it, and there is no way to probe it short of actually trying
/// a deletion, so unlike Full Disk Access there is no `isGranted` here: the
/// deletion report's permission failures are the detection.
enum AppManagement {
    static func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
        )!
        NSWorkspace.shared.open(url)
    }
}
