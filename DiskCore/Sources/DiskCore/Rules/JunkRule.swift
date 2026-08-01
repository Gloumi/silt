import Foundation

public enum JunkSafety: String, Codable, Sendable {
    /// Regenerated automatically, or by one documented command.
    case safe
    /// Deletable, but it costs something to get back — time, bandwidth, or a
    /// setup step the user may not remember.
    case caution
}

/// How a rule recognises its target.
///
/// Kept to a few declarative shapes rather than arbitrary globs, so the whole
/// rule set stays data — `rules.json` — and contributors can add cases without
/// touching Swift. That is the point: this list is the part of the app most
/// likely to need community upkeep, since every toolchain invents new caches.
public struct JunkMatcher: Codable, Sendable {
    /// Any directory with this exact name, anywhere in the tree.
    public var directoryName: String?
    /// Additionally require a file with this name *beside* the directory —
    /// `vendor` only counts as Composer's if `composer.json` sits next to it.
    public var siblingFile: String?
    /// Additionally require this file *inside* the directory, which is how a
    /// Python virtualenv is identified regardless of what it is called.
    public var childFile: String?
    /// One specific directory, relative to the user's home.
    public var homePath: String?
    /// Every child of one directory, relative to home — lets each app's cache
    /// or each project's build folder be listed and chosen separately.
    public var childrenOfHomePath: String?
}

public struct JunkRule: Codable, Sendable, Identifiable {
    public var id: String
    public var category: String
    public var title: String
    public var safety: JunkSafety
    /// What it takes to get it back, shown to the user verbatim.
    public var recovery: String?
    public var match: JunkMatcher
}

public struct JunkCategory: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
}

public struct JunkRuleSet: Codable, Sendable {
    public var categories: [JunkCategory]
    public var rules: [JunkRule]

    /// The rule set shipped with the app.
    public static func bundled() -> JunkRuleSet {
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(JunkRuleSet.self, from: data)
        else {
            assertionFailure("rules.json manquant ou invalide")
            return JunkRuleSet(categories: [], rules: [])
        }
        return decoded
    }
}

public struct JunkFinding: Sendable, Identifiable {
    public var node: Int32
    public var ruleID: String
    public var category: String
    public var title: String
    public var safety: JunkSafety
    public var recovery: String?
    public var path: String
    public var bytes: Int64
    public var fileCount: Int32

    public var id: Int32 { node }
}

public struct JunkReport: Sendable {
    public var findings: [JunkFinding]
    public var categories: [JunkCategory]

    public var totalBytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }

    public func findings(in category: String) -> [JunkFinding] {
        findings.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
    }

    /// Categories that actually matched something, in the rule file's order.
    public var populatedCategories: [JunkCategory] {
        let present = Set(findings.map(\.category))
        return categories.filter { present.contains($0.id) }
    }
}
