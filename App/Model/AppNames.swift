import AppKit
import Foundation

/// Turns machine-readable folder names into the names people actually use.
///
/// A cleanup list full of `com.spotify.client` and
/// `D8CBBFE5-982B-4C09-85FC-8550CAA570BA` asks the user to decide about things
/// it has not bothered to identify. Both are resolvable, so both should be.
@MainActor
final class AppNames {
    static let shared = AppNames()

    /// Nil means "looked it up, there is no answer" — worth caching too, since
    /// most misses are folders that will never resolve.
    private var cache: [String: String?] = [:]

    /// Human name for a folder, or nil if it is already plain enough.
    func friendlyName(for folderName: String, path: String) -> String? {
        if let cached = cache[path] { return cached }
        let resolved = resolve(folderName: folderName, path: path)
        cache[path] = resolved
        return resolved
    }

    private func resolve(folderName: String, path: String) -> String? {
        if looksLikeBundleIdentifier(folderName),
           let name = applicationName(bundleID: folderName) {
            return name
        }
        if looksLikeUUID(folderName), let name = simulatorName(atPath: path) {
            return name
        }
        return nil
    }

    // MARK: - Applications

    /// Reverse-DNS shaped: at least two dots, no spaces, nothing exotic.
    private func looksLikeBundleIdentifier(_ name: String) -> Bool {
        guard name.contains("."), !name.hasPrefix("."), !name.contains(" ") else {
            return false
        }
        let parts = name.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private func applicationName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? nil : (name as NSString).deletingPathExtension
    }

    // MARK: - Simulators

    private func looksLikeUUID(_ name: String) -> Bool {
        name.count == 36 && UUID(uuidString: name) != nil
    }

    /// A simulator folder carries its own description in `device.plist`, which
    /// is what turns 4 GB of unnamed UUID into "iPhone 17 Pro · iOS 26.1".
    private func simulatorName(atPath path: String) -> String? {
        let plist = path + "/device.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let parsed = try? PropertyListSerialization.propertyList(
                from: data, format: nil
              ) as? [String: Any],
              let name = parsed["name"] as? String
        else { return nil }

        if let runtime = parsed["runtime"] as? String,
           let short = runtime.split(separator: ".").last {
            return "\(name) · \(short.replacingOccurrences(of: "-", with: " "))"
        }
        return name
    }
}
