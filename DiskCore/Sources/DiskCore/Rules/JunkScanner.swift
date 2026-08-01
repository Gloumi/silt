import Foundation

/// Matches the rule set against a scanned tree.
///
/// Runs in two passes for a reason. Path rules (`~/Library/Caches`, Xcode's
/// DerivedData…) are resolved by walking down from the root — a handful of
/// steps each. Name rules (`node_modules`, `.venv`…) need every directory
/// examined, so they get one traversal, comparing raw bytes rather than
/// building a `String` per node. Testing every rule against every node instead
/// would be tens of millions of comparisons on a real home directory.
public enum JunkScanner {

    public static func scan(
        store: NodeStore, ruleSet: JunkRuleSet = .bundled()
    ) -> JunkReport {
        guard !store.isEmpty else {
            return JunkReport(findings: [], categories: ruleSet.categories)
        }

        var findings: [JunkFinding] = []
        var claimed: Set<Int32> = []

        resolvePathRules(store: store, ruleSet: ruleSet,
                         findings: &findings, claimed: &claimed)
        resolveNameRules(store: store, ruleSet: ruleSet,
                         findings: &findings, claimed: &claimed)

        findings.sort { $0.bytes > $1.bytes }
        return JunkReport(findings: findings, categories: ruleSet.categories)
    }

    // MARK: - Path rules

    private static func resolvePathRules(
        store: NodeStore,
        ruleSet: JunkRuleSet,
        findings: inout [JunkFinding],
        claimed: inout Set<Int32>
    ) {
        let rootPath = store.name(of: 0)
        let home = NSHomeDirectory()

        for rule in ruleSet.rules {
            let relative = rule.match.homePath ?? rule.match.childrenOfHomePath
            guard let relative else { continue }

            let absolute = home + "/" + relative
            // The rule only applies if its target lies inside what was scanned.
            guard let components = relativeComponents(of: absolute, under: rootPath),
                  let node = store.descendant(of: 0, at: components)
            else { continue }

            if rule.match.childrenOfHomePath != nil {
                for child in store.children(of: node)
                where !claimed.contains(child) {
                    append(store: store, node: child, rule: rule,
                           subjectIsFolderName: true,
                           findings: &findings, claimed: &claimed)
                }
            } else if !claimed.contains(node) {
                append(store: store, node: node, rule: rule,
                       findings: &findings, claimed: &claimed)
            }
        }
    }

    /// Path components of `path` relative to `root`, or nil if it is outside.
    private static func relativeComponents(
        of path: String, under root: String
    ) -> [String]? {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        if path == root { return [] }
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1)
            .split(separator: "/").map(String.init)
    }

    // MARK: - Name rules

    private static func resolveNameRules(
        store: NodeStore,
        ruleSet: JunkRuleSet,
        findings: inout [JunkFinding],
        claimed: inout Set<Int32>
    ) {
        // Pre-encode the names once, so the walk compares bytes only.
        struct Compiled {
            let rule: JunkRule
            let name: [UInt8]
            let siblingFile: [UInt8]?
            let childFile: [UInt8]?
        }
        let compiled: [Compiled] = ruleSet.rules.compactMap { rule in
            guard let name = rule.match.directoryName else { return nil }
            return Compiled(
                rule: rule,
                name: Array(name.utf8),
                siblingFile: rule.match.siblingFile.map { Array($0.utf8) },
                childFile: rule.match.childFile.map { Array($0.utf8) }
            )
        }
        guard !compiled.isEmpty else { return }

        var stack: [Int32] = [0]
        while let node = stack.popLast() {
            var matched = false

            if node != 0, store.isDirectory(node), !claimed.contains(node) {
                for candidate in compiled where store.hasName(node, candidate.name) {
                    if let sibling = candidate.siblingFile {
                        let parent = store.parent[Int(node)]
                        guard store.children(of: parent)
                            .contains(where: { store.hasName($0, sibling) })
                        else { continue }
                    }
                    if let child = candidate.childFile {
                        guard hasChildFile(
                            store: store, node: node, name: child,
                            ruleName: candidate.rule.match.childFile
                        ) else { continue }
                    }
                    append(store: store, node: node, rule: candidate.rule,
                           findings: &findings, claimed: &claimed)
                    matched = true
                    break
                }
            }

            // Never look for junk inside junk: a `node_modules` full of nested
            // `node_modules` should be one finding, not four hundred.
            guard !matched else { continue }
            for child in store.children(of: node) where store.isDirectory(child) {
                stack.append(child)
            }
        }
    }

    /// Looks for a marker file inside a candidate directory.
    ///
    /// The tree is usually enough. But the directories these rules care about
    /// are exactly the ones the scanner *collapses* — `.venv`, `node_modules` —
    /// so they have no child nodes to inspect and a tree-only check would never
    /// fire. For those, one `access(2)` on the real path settles it; it happens
    /// only for the handful of directories that already matched by name.
    private static func hasChildFile(
        store: NodeStore, node: Int32, name: [UInt8], ruleName: String?
    ) -> Bool {
        if !store.flags[Int(node)].contains(.notDescended) {
            return store.children(of: node).contains { store.hasName($0, name) }
        }
        guard let ruleName else { return false }
        let marker = store.path(of: node) + "/" + ruleName
        return access(marker, F_OK) == 0
    }

    // MARK: - Shared

    private static func append(
        store: NodeStore,
        node: Int32,
        rule: JunkRule,
        subjectIsFolderName: Bool = false,
        findings: inout [JunkFinding],
        claimed: inout Set<Int32>
    ) {
        let index = Int(node)
        guard !store.flags[index].contains(.deleted),
              store.totalAlloc[index] > 0
        else { return }

        claimed.insert(node)
        findings.append(JunkFinding(
            node: node,
            ruleID: rule.id,
            category: rule.category,
            title: rule.title,
            safety: rule.safety,
            recovery: rule.recovery,
            path: store.path(of: node),
            bytes: store.totalAlloc[index],
            fileCount: store.fileCount[index],
            subject: subjectIsFolderName ? store.name(of: node) : nil
        ))
    }
}
