import Foundation

public enum DeletionVerdict: Sendable, Equatable {
    /// Ordinary user data.
    case allowed
    /// Deletable, but the consequence is worth stating out loud first.
    case caution(String)
    /// Refused outright, whatever the user clicks.
    case forbidden(String)

    public var isForbidden: Bool {
        if case .forbidden = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .allowed: nil
        case .caution(let text), .forbidden(let text): text
        }
    }
}

/// Decides what may be deleted.
///
/// This is the one piece of the app that can destroy something irreplaceable,
/// so it is deliberately conservative and deliberately dumb: a fixed list, no
/// heuristics, no learning, refusing anything it does not recognise as ordinary
/// user data. Being occasionally over-protective costs an inconvenience; being
/// occasionally wrong the other way costs someone their system or their photos.
public enum DenyList {

    /// Never deletable — removing these breaks the system or destroys secrets
    /// that cannot be regenerated.
    private static let forbiddenRoots: [(path: String, reason: String)] = [
        ("/System", "Volume système, en lecture seule."),
        ("/bin", "Binaires système essentiels."),
        ("/sbin", "Binaires système essentiels."),
        ("/usr", "Fichiers système."), // /usr/local is carved out below
        ("/Library/Apple", "Composants système Apple."),
        ("/private/var/db", "Bases de données système."),
        ("/private/var/vm", "Fichiers d'échange mémoire."),
        ("/private/var/root", "Dossier de départ du superutilisateur."),
        ("/private/etc", "Configuration système."),
        ("/dev", "Périphériques."),
        ("/cores", "Vidages mémoire système."),
    ]

    /// Deletable, but only after the user has been told what it is.
    private static let cautionRoots: [(path: String, reason: String)] = [
        ("/Applications", "Application installée — elle devra être réinstallée."),
        ("/usr/local", "Outils installés manuellement (Homebrew, etc.)."),
        ("/opt", "Outils installés manuellement (Homebrew, etc.)."),
    ]

    private static func homeRelative(
        _ suffix: String
    ) -> String { NSHomeDirectory() + "/" + suffix }

    /// `path` is `prefix` itself, or lives inside it.
    private static func isUnder(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    /// Rewrites the short forms of the `/private` symlinks to their real
    /// targets, so a single spelling has to be listed above.
    ///
    /// This matters more than it looks: `standardizingPath` *removes* the
    /// `/private` prefix, turning `/private/etc/hosts` into `/etc/hosts`. A list
    /// written in the `/private` spelling would then match nothing, and the
    /// entire protection would quietly fail open. The tests caught exactly that.
    private static func canonical(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        for short in ["/etc", "/var", "/tmp"] where isUnder(standardized, short) {
            return "/private" + standardized
        }
        return standardized
    }

    public static func verdict(for path: String) -> DeletionVerdict {
        let path = canonical(path)
        let home = NSHomeDirectory()

        // Roots of any kind: deleting one is never what someone meant.
        if path == "/" || path.isEmpty {
            return .forbidden("Racine du disque.")
        }
        if path == "/Volumes" {
            return .forbidden("Dossier des points de montage.")
        }
        if path == home {
            return .forbidden("Votre dossier de départ.")
        }
        if path.hasPrefix("/Volumes/"),
           path.dropFirst("/Volumes/".count).firstIndex(of: "/") == nil {
            return .forbidden("Racine d'un volume monté.")
        }
        if isUnder(path, "/Users"), path.split(separator: "/").count == 2 {
            return .forbidden("Dossier de départ d'un utilisateur.")
        }

        // Secrets and identity: no undo exists for these in any real sense.
        for suffix in ["Library/Keychains", "Library/Group Containers/group.com.apple.notes"] {
            if isUnder(path, homeRelative(suffix)) {
                return .forbidden("Trousseau et données d'identité.")
            }
        }

        // /usr/local is the exception inside /usr — it is where Homebrew and
        // hand-installed tools live, and is legitimately user-managed.
        if isUnder(path, "/usr/local") {
            return .caution("Outils installés manuellement (Homebrew, etc.).")
        }
        for rule in forbiddenRoots where isUnder(path, rule.path) {
            return .forbidden(rule.reason)
        }

        for suffix in [
            ("Library/Application Support/MobileSync", "Sauvegardes d'appareils iOS."),
            ("Library/Mail", "Boîtes aux lettres locales."),
            ("Library/Messages", "Historique des messages."),
            ("Library/Photos", "Bibliothèque Photos."),
            ("Pictures/Photos Library.photoslibrary", "Bibliothèque Photos."),
            ("Library/Containers", "Données d'applications sandboxées."),
            ("Library/Preferences", "Réglages des applications."),
        ] where isUnder(path, homeRelative(suffix.0)) {
            return .caution(suffix.1)
        }

        for rule in cautionRoots where isUnder(path, rule.path) {
            return .caution(rule.reason)
        }

        return .allowed
    }
}
