import Foundation
import Synchronization
import Testing

@testable import DiskCore

@Suite("Installed applications")
struct InstalledAppsTests {

    @Test("Listing finds bundles at the top level and one folder down")
    func listsBundles() async throws {
        let fixture = try Fixture()
        try bundle(in: fixture, at: "Fictive.app", id: "com.example.fictive")
        try bundle(in: fixture, at: "Utilities/Petite.app", id: "com.example.petite")
        // A folder an installer made, the Adobe shape.
        try bundle(
            in: fixture, at: "Éditeur 2024/Éditeur 2024.app", id: "com.example.editeur"
        )
        // Not an application, and a bundle buried too deep to be an install.
        try fixture.file("lisezmoi.txt", bytes: 10)
        try bundle(in: fixture, at: "a/b/Trop Loin.app", id: "com.example.loin")

        let installed = await InstalledApps.list(in: [fixture.path])
        let identifiers = Set(installed.compactMap(\.app.bundleID))

        #expect(identifiers == [
            "com.example.fictive", "com.example.petite", "com.example.editeur",
        ])
        // Every bundle is measured, not merely named.
        #expect(installed.allSatisfy { $0.app.bytes > 0 })
    }

    /// The trap the confidence tiers exist for, applied to a *total*. Android
    /// Studio is `com.google.android.studio`, so the vendor prefix reaches
    /// Chrome's preferences. Showing them is the point; adding them to the
    /// figure on screen would promise space that removing the app never frees.
    @Test("A total counts only what carries the bundle identifier")
    func totalExcludesSiblings() throws {
        let fixture = try Fixture()
        let library = try fixture.directory("Library").path

        let own = try fixture.file(
            "Library/com.acme.fictive.plist", bytes: 40_000
        ).path
        let sibling = try fixture.file(
            "Library/com.acme.autre.plist", bytes: 900_000
        ).path
        let named = try fixture.file("Library/Fictive", bytes: 70_000).path

        let app = AppBundle(
            path: "/Applications/Fictive.app", name: "Fictive",
            bundleID: "com.acme.fictive", bytes: 0
        )
        let totals = InstalledApps.leftoverBytes(
            for: [app], in: [(label: "Test", path: library)]
        )

        #expect(totals[app.path] == PathSize.measure(own).allocated)
        // Both of these are found by the uninstaller and shown in its sheet.
        // Neither belongs in the number the list displays.
        #expect(totals[app.path] != PathSize.measure(sibling).allocated)
        #expect(
            totals[app.path]
                != PathSize.measure(own).allocated
                + PathSize.measure(named).allocated
        )
    }

    @Test("Raising the threshold is what widens the total, nothing else")
    func thresholdWidensTheTotal() throws {
        let fixture = try Fixture()
        let library = try fixture.directory("Library").path
        let own = try fixture.file(
            "Library/com.acme.fictive.plist", bytes: 40_000
        ).path
        let named = try fixture.file("Library/Fictive", bytes: 70_000).path
        let sibling = try fixture.file(
            "Library/com.acme.autre.plist", bytes: 900_000
        ).path

        let app = AppBundle(
            path: "/Applications/Fictive.app", name: "Fictive",
            bundleID: "com.acme.fictive", bytes: 0
        )
        let locations = [(label: "Test", path: library)]

        let probable = InstalledApps.leftoverBytes(
            for: [app], upTo: .probable, in: locations
        )
        #expect(
            probable[app.path]
                == PathSize.measure(own).allocated
                + PathSize.measure(named).allocated
        )

        let possible = InstalledApps.leftoverBytes(
            for: [app], upTo: .possible, in: locations
        )
        #expect(
            possible[app.path]
                == PathSize.measure(own).allocated
                + PathSize.measure(named).allocated
                + PathSize.measure(sibling).allocated
        )
    }

    /// A helper and the app it belongs to both claim the same file. Each total
    /// must carry it — the sweep measures it once and hands the size to both,
    /// which is the only reason listing every app at once is affordable.
    @Test("A path claimed by two applications counts for both")
    func sharedPathCountsTwice() throws {
        let fixture = try Fixture()
        let library = try fixture.directory("Library").path
        let shared = try fixture.file(
            "Library/com.acme.fictive.helper.plist", bytes: 40_000
        ).path

        let app = AppBundle(
            path: "/Applications/Fictive.app", name: "Fictive",
            bundleID: "com.acme.fictive", bytes: 0
        )
        let helper = AppBundle(
            path: "/Applications/Fictive Helper.app", name: "Fictive Helper",
            bundleID: "com.acme.fictive.helper", bytes: 0
        )

        let totals = InstalledApps.leftoverBytes(
            for: [app, helper], in: [(label: "Test", path: library)]
        )
        let size = PathSize.measure(shared).allocated
        #expect(totals[app.path] == size)
        #expect(totals[helper.path] == size)
    }

    @Test("Every application in the list gets a total, even an empty one")
    func everyAppIsReported() throws {
        let fixture = try Fixture()
        let library = try fixture.directory("Library").path
        let app = AppBundle(
            path: "/Applications/Seule.app", name: "Seule",
            bundleID: "com.acme.seule", bytes: 0
        )

        let reported = Mutex<[String]>([])
        let totals = InstalledApps.leftoverBytes(
            for: [app], in: [(label: "Test", path: library)],
            onProgress: { path, _ in reported.withLock { $0.append(path) } }
        )

        // Zero, not absent: the view tells "measured, nothing found" from
        // "still measuring" by exactly this difference.
        #expect(totals[app.path] == 0)
        #expect(reported.withLock { $0 } == [app.path])
    }

    /// Writes a minimal application bundle into the fixture.
    private func bundle(
        in fixture: borrowing Fixture, at relative: String, id: String
    ) throws {
        let name = ((relative as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        try fixture.file(relative + "/Contents/MacOS/\(name)", bytes: 20_000)
        let info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(
            to: fixture.root
                .appendingPathComponent(relative + "/Contents/Info.plist")
        )
    }
}
