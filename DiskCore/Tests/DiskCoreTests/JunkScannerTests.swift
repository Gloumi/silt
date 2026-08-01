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
