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

    /// - Parameter root: subtree to confine the search to. Defaults to the scan
    ///   root. Home-relative rules simply stop matching outside it, which is the
    ///   behaviour we want: asked about one project folder, nobody expects
    ///   `~/Library/Caches` in the answer.
    public static func scan(
        store: NodeStore, ruleSet: JunkRuleSet = .bundled(), root: Int32 = 0
    ) -> JunkReport {
        guard !store.isEmpty, root >= 0, Int(root) < store.count else {
            return JunkReport(findings: [], categories: ruleSet.categories)
        }

        var findings: [JunkFinding] = []
        var claimed: Set<Int32> = []

        resolvePathRules(store: store, root: root, ruleSet: ruleSet,
                         findings: &findings, claimed: &claimed)
        resolveNameRules(store: store, root: root, ruleSet: ruleSet,
                         findings: &findings, claimed: &claimed)

        findings.sort { $0.bytes > $1.bytes }
        return JunkReport(findings: findings, categories: ruleSet.categories)
    }

    // MARK: - Path rules

    private static func resolvePathRules(
        store: NodeStore,
        root: Int32,
        ruleSet: JunkRuleSet,
        findings: inout [JunkFinding],
        claimed: inout Set<Int32>
    ) {
        // The scan root's own name *is* its full path; anything deeper has to be
        // rebuilt from the tree.
        let rootPath = root == 0 ? store.name(of: 0) : store.path(of: root)
        let home = NSHomeDirectory()

        // File order is precedence: the first rule to claim a node keeps it.
        // A rule that sweeps the children of a directory therefore has to be
        // declared *after* any rule naming something specific inside it —
        // `generic-cache` sitting before `.cache/puppeteer` silently swallowed
        // it, and `.cache/huggingface` with it, reporting a "caution" model
        // cache as a "safe" generic one.
        for rule in ruleSet.rules {
            let relative = rule.match.homePath ?? rule.match.childrenOfHomePath
            guard let relative else { continue }

            let absolute = home + "/" + relative
            // The rule only applies if its target lies inside what was scanned.
            guard let components = relativeComponents(of: absolute, under: rootPath),
                  let node = store.descendant(of: root, at: components)
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
        root: Int32,
        ruleSet: JunkRuleSet,
        findings: inout [JunkFinding],
        claimed: inout Set<Int32>
    ) {
        // Pre-encode the names once, so the walk compares bytes only.
        struct Compiled {
            let rule: JunkRule
            let name: [UInt8]
            let siblingFiles: [[UInt8]]?
            let childFile: [UInt8]?
        }
        let compiled: [Compiled] = ruleSet.rules.compactMap { rule in
            guard let name = rule.match.directoryName else { return nil }
            return Compiled(
                rule: rule,
                name: Array(name.utf8),
                siblingFiles: rule.match.siblingFiles?.map { Array($0.utf8) },
                childFile: rule.match.childFile.map { Array($0.utf8) }
            )
        }
        guard !compiled.isEmpty else { return }

        var stack: [Int32] = [root]
        while let node = stack.popLast() {
            var matched = false
            var namedLikeJunk = false

            // The subtree we were asked about is never itself the answer.
            if node != root, store.isDirectory(node), !claimed.contains(node) {
                for candidate in compiled where store.hasName(node, candidate.name) {
                    namedLikeJunk = true
                    if let siblings = candidate.siblingFiles {
                        let parent = store.parent[Int(node)]
                        guard store.children(of: parent).contains(where: { child in
                            siblings.contains { store.hasName(child, $0) }
                        }) else { continue }
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
            //
            // Nor inside something that only *looks* like junk. A `node_modules`
            // that failed its lockfile check is installed software — npm's
            // global prefix, an editor extension — and the packages in it ship
            // their own lockfiles, so their nested `node_modules` would pass the
            // check and be offered, breaking the tool from the inside.
            guard !matched, !namedLikeJunk else { continue }
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
