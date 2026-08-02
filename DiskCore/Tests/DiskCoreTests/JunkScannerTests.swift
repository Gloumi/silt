import Foundation
import Testing

@testable import DiskCore

@Suite("Junk rules")
struct JunkScannerTests {

    private func report(for fixture: borrowing Fixture) async -> JunkReport {
        let result = await ScanEngine.scan(root: fixture.path)
        return JunkScanner.scan(store: result.store)
    }

    @Test("The shipped rule file loads")
    func rulesLoad() {
        let ruleSet = JunkRuleSet.bundled()
        #expect(!ruleSet.rules.isEmpty)
        #expect(!ruleSet.categories.isEmpty)
        // Every rule points at a category that exists.
        let categories = Set(ruleSet.categories.map(\.id))
        for rule in ruleSet.rules {
            #expect(categories.contains(rule.category), "\(rule.id) → \(rule.category)")
        }
        // Ids are unique, or findings would collide.
        #expect(Set(ruleSet.rules.map(\.id)).count == ruleSet.rules.count)
    }

    /// File order is precedence, and that is easy to get wrong when adding a
    /// rule: `generic-cache` swept every child of `~/.cache` from a position
    /// above `.cache/puppeteer` and `.cache/huggingface`, so neither of those
    /// could ever fire — Hugging Face's model cache was reported as a generic
    /// "safe" cache instead of the "caution" it is. This asserts the invariant
    /// rather than that one case, so the next such rule is caught too.
    @Test("A rule naming something specific is declared before any sweep above it")
    func specificPathRulesOutrankSweeps() {
        let rules = JunkRuleSet.bundled().rules

        for (index, sweep) in rules.enumerated() {
            guard let swept = sweep.match.childrenOfHomePath else { continue }
            for specific in rules[(index + 1)...] {
                guard let target = specific.match.homePath
                    ?? specific.match.childrenOfHomePath
                else { continue }
                #expect(
                    !target.hasPrefix(swept + "/"),
                    """
                    « \(specific.id) » (\(target)) est déclarée après \
                    « \(sweep.id) », qui balaye \(swept) : elle ne pourra \
                    jamais s'appliquer.
                    """
                )
            }
        }
    }

    @Test("Scoping to a folder reports that folder and nothing beside it")
    func scopedToSubtree() async throws {
        let fixture = try Fixture()
        try fixture.file("projet-a/node_modules/pkg/index.js", bytes: 40_000)
        try fixture.file("projet-a/src/main.js", bytes: 500)
        try fixture.file("projet-b/node_modules/pkg/index.js", bytes: 90_000)

        let store = await ScanEngine.scan(root: fixture.path).store
        let projectA = try #require(
            store.children(of: 0).first { store.name(of: $0) == "projet-a" }
        )

        let whole = JunkScanner.scan(store: store)
        #expect(whole.findings.count == 2)

        let scoped = JunkScanner.scan(store: store, root: projectA)
        #expect(scoped.findings.count == 1)
        let found = try #require(scoped.findings.first)
        #expect(found.path.hasSuffix("projet-a/node_modules"))
        // The sibling project's 90 kB must not leak into a scoped total.
        #expect(scoped.totalBytes < whole.totalBytes)
    }

    /// A folder that is itself junk is a scope, not a finding — otherwise
    /// "clean this folder" on a `node_modules` would offer to delete the very
    /// thing you are standing in.
    @Test("The scoped root is never reported as junk itself")
    func scopedRootIsNotItsOwnFinding() async throws {
        let fixture = try Fixture()
        try fixture.file("node_modules/pkg/index.js", bytes: 40_000)

        let store = await ScanEngine.scan(root: fixture.path).store
        let modules = try #require(
            store.children(of: 0).first { store.name(of: $0) == "node_modules" }
        )
        #expect(JunkScanner.scan(store: store).findings.count == 1)
        #expect(JunkScanner.scan(store: store, root: modules).findings.isEmpty)
    }

    /// The unambiguous-name rules: no sibling or marker file guards them, so
    /// the only thing that can go wrong is the name never being reached.
    @Test("Framework and tool caches are matched by name alone")
    func unambiguousNameRules() async throws {
        let names = [
            "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
            ".tox", ".sass-cache", ".turbo", ".nuxt", ".svelte-kit",
            ".astro", ".angular", ".nx", ".vite", ".parcel-cache",
            ".docusaurus", ".serverless", ".dart_tool",
        ]
        let fixture = try Fixture()
        for name in names {
            try fixture.file("projet/\(name)/blob.bin", bytes: 5_000)
        }

        let store = await ScanEngine.scan(root: fixture.path).store
        let report = JunkScanner.scan(store: store)

        let found = Set(report.findings.map { ($0.path as NSString).lastPathComponent })
        for name in names {
            #expect(found.contains(name), "« \(name) » n'a pas été détecté")
        }
    }

    @Test("node_modules is found")
    func findsNodeModules() async throws {
        let fixture = try Fixture()
        // Scan the contents rather than collapsing them, so the rule engine has
        // a real directory to match on.
        try fixture.file("app/node_modules/left-pad/index.js", bytes: 60_000)
        try fixture.file("app/src/main.js", bytes: 500)

        let result = await ScanEngine.scan(
            root: fixture.path, options: uncollapsed()
        )
        let junk = JunkScanner.scan(store: result.store)
        #expect(junk.findings.count == 1)
        #expect(junk.findings[0].ruleID == "node-modules")
        #expect(junk.findings[0].safety == .safe)
    }

    /// The failure this guards against is a `node_modules` containing four
    /// hundred nested `node_modules`, each reported as its own finding and each
    /// counted again in the total.
    @Test("Nested matches are reported once, not once per level")
    func nestedMatchesCollapse() async throws {
        let fixture = try Fixture()
        try fixture.file("app/node_modules/a/node_modules/b/index.js", bytes: 40_000)
        try fixture.file("app/node_modules/c/node_modules/d/index.js", bytes: 40_000)

        let result = await ScanEngine.scan(
            root: fixture.path, options: uncollapsed()
        )
        let junk = JunkScanner.scan(store: result.store)
        #expect(junk.findings.count == 1)
        // And the one finding carries the whole subtree's weight.
        #expect(junk.findings[0].bytes >= 80_000)
    }

    @Test("vendor only counts as Composer's when composer.json sits beside it")
    func vendorNeedsItsSibling() async throws {
        let withMarker = try Fixture("vendor-yes")
        try withMarker.file("site/composer.json", bytes: 200)
        try withMarker.file("site/vendor/pkg/file.php", bytes: 30_000)
        let found = await report(for: withMarker)
        #expect(found.findings.contains { $0.ruleID == "composer-vendor" })

        let withoutMarker = try Fixture("vendor-no")
        try withoutMarker.file("notes/vendor/pkg/file.php", bytes: 30_000)
        let notFound = await report(for: withoutMarker)
        #expect(notFound.findings.isEmpty)
    }

    @Test("A virtualenv is recognised by pyvenv.cfg, not by its name alone")
    func venvNeedsMarker() async throws {
        let real = try Fixture("venv-yes")
        try real.file(".venv/pyvenv.cfg", bytes: 100)
        try real.file(".venv/lib/python3.12/site.py", bytes: 50_000)
        let found = await report(for: real)
        #expect(found.findings.contains { $0.ruleID == "python-venv" })

        let impostor = try Fixture("venv-no")
        try impostor.file(".venv/notes.txt", bytes: 50_000)
        let notFound = await report(for: impostor)
        #expect(notFound.findings.isEmpty)
    }

    @Test("Rust targets need a Cargo.toml next door")
    func rustTargetNeedsManifest() async throws {
        let fixture = try Fixture()
        try fixture.file("crate/Cargo.toml", bytes: 100)
        try fixture.file("crate/target/debug/binary", bytes: 90_000)
        try fixture.file("photos/target/holiday.jpg", bytes: 90_000)

        let junk = await report(for: fixture)
        #expect(junk.findings.count == 1)
        #expect(junk.findings[0].path.hasSuffix("crate/target"))
    }

    @Test("Deleted items drop out of the report")
    func deletedItemsExcluded() async throws {
        let fixture = try Fixture()
        try fixture.file("app/node_modules/left-pad/index.js", bytes: 60_000)

        let result = await ScanEngine.scan(
            root: fixture.path, options: uncollapsed()
        )
        var store = result.store
        let before = JunkScanner.scan(store: store)
        #expect(before.findings.count == 1)

        store.markDeleted(before.findings[0].node)
        #expect(JunkScanner.scan(store: store).findings.isEmpty)
    }

    @Test("Totals add up and nothing is counted twice")
    func totalsAreConsistent() async throws {
        let fixture = try Fixture()
        try fixture.file("a/node_modules/x/f", bytes: 30_000)
        try fixture.file("b/Cargo.toml", bytes: 100)
        try fixture.file("b/target/f", bytes: 50_000)

        let result = await ScanEngine.scan(
            root: fixture.path, options: uncollapsed()
        )
        let junk = JunkScanner.scan(store: result.store)
        #expect(junk.findings.count == 2)
        #expect(junk.totalBytes == junk.findings.reduce(0) { $0 + $1.bytes })
        // No finding may sit inside another, or the total over-counts.
        let paths = junk.findings.map(\.path)
        for outer in paths {
            for inner in paths where inner != outer {
                #expect(!inner.hasPrefix(outer + "/"))
            }
        }
    }

    private func uncollapsed() -> ScanOptions {
        var options = ScanOptions()
        options.collapsedDirectoryNames = []
        return options
    }
}
