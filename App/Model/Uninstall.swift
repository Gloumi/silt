import AppKit
import DiskCore

/// Everything the uninstall sheet needs, gathered before it opens.
struct UninstallPlan: Identifiable {
    let id = UUID()
    let app: AppBundle
    /// Node the bundle occupies in the scanned tree, when it is in one.
    let node: Int32?
    let leftovers: [Leftover]
    /// The app was running when the plan was built. Trashing a running app
    /// leaves it half-alive: the process keeps its open files, and it may
    /// rewrite the preferences we just removed on quit.
    let isRunning: Bool

    var byLocation: [(location: String, items: [Leftover])] {
        var order: [String] = []
        var grouped: [String: [Leftover]] = [:]
        for item in leftovers {
            if grouped[item.location] == nil { order.append(item.location) }
            grouped[item.location, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

enum RunningApps {
    /// Whether an application with this bundle identifier is running now.
    static func isRunning(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleID }
    }

    /// Asks it to quit, the ordinary way. Returns false if it is not running.
    @discardableResult
    static func quit(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
        guard !running.isEmpty else { return false }
        for application in running { application.terminate() }
        return true
    }
}

extension LeftoverConfidence {
    var label: String {
        switch self {
        case .certain: "Certain"
        case .probable: "Probable"
        case .possible: "À vérifier"
        }
    }

    var explanation: String {
        switch self {
        case .certain:
            "Porte l'identifiant de l'application — aucun doute possible."
        case .probable:
            "Porte exactement le nom de l'application."
        case .possible:
            "Nom approchant ou même éditeur : peut appartenir à une autre application."
        }
    }
}
