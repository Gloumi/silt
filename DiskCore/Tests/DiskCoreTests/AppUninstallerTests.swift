import Foundation
import Testing

@testable import DiskCore

@Suite("App uninstaller")
struct AppUninstallerTests {

    private let spotify = AppBundle(
        path: "/Applications/Spotify.app",
        name: "Spotify",
        bundleID: "com.spotify.client",
        bytes: 0
    )

    @Test("The bundle identifier is the only thing that makes a match certain")
    func certainMatches() {
        for entry in [
            "com.spotify.client",
            "com.spotify.client.plist",
            "com.spotify.client.savedState",
            "com.spotify.client.helper",
            "group.com.spotify.client",
        ] {
            #expect(
                AppUninstaller.classify(entry: entry, app: spotify) == .certain,
                "« \(entry) » devrait être certain"
            )
        }
    }

    @Test("A folder named exactly like the app is only probable")
    func probableMatches() {
        #expect(AppUninstaller.classify(entry: "Spotify", app: spotify) == .probable)
        #expect(AppUninstaller.classify(entry: "spotify", app: spotify) == .probable)
    }

    /// The trap the whole confidence system exists for. Uninstalling one product
    /// must not quietly tick a sibling's data — this has to be found, so the
    /// user can see it, and must never be pre-selected.
    @Test("A same-publisher sibling is found but only ever possible")
    func siblingIsNeverCertain() {
        let verdict = AppUninstaller.classify(
            entry: "com.spotify.podcasts", app: spotify
        )
        #expect(verdict == .possible)
        #expect(verdict != .certain)
    }

    @Test("Unrelated files are not matched at all")
    func unrelatedIsIgnored() {
        for entry in ["com.apple.finder.plist", "Slack", "Xcode", "logs"] {
            #expect(
                AppUninstaller.classify(entry: entry, app: spotify) == nil,
                "« \(entry) » ne devrait rien déclencher"
            )
        }
    }

    /// A two-letter app name as a substring would match a large part of the
    /// library, so short names only ever match their bundle identifier.
    @Test("Short application names never match by name")
    func shortNamesAreNotUsed() {
        let go = AppBundle(
            path: "/Applications/Go.app", name: "Go",
            bundleID: "org.golang.go", bytes: 0
        )
        #expect(AppUninstaller.classify(entry: "Google", app: go) == nil)
        #expect(AppUninstaller.classify(entry: "go", app: go) == nil)
        #expect(
            AppUninstaller.classify(entry: "org.golang.go.plist", app: go)
                == .certain
        )
    }

    @Test("An app with no bundle identifier still matches on its name")
    func noBundleIdentifier() {
        let app = AppBundle(
            path: "/Applications/Handbrake.app", name: "Handbrake",
            bundleID: nil, bytes: 0
        )
        #expect(AppUninstaller.classify(entry: "Handbrake", app: app) == .probable)
        #expect(AppUninstaller.classify(entry: "com.apple.dock", app: app) == nil)
    }

    @Test("Reading a bundle picks up its identifier and display name")
    func inspectsRealBundle() throws {
        let fixture = try Fixture()
        let app = fixture.root.appendingPathComponent("Fictive.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents, withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fictive",
            "CFBundleName": "Fictive",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let bundle = try #require(AppUninstaller.inspect(appPath: app.path))
        #expect(bundle.bundleID == "com.example.fictive")
        #expect(bundle.name == "Fictive")

        // Anything that is not an app bundle is refused outright.
        #expect(AppUninstaller.inspect(appPath: fixture.path) == nil)
    }

    @Test("Measuring a path agrees with du")
    func measuresPaths() throws {
        let fixture = try Fixture()
        try fixture.file("a/one.bin", bytes: 40_000)
        try fixture.file("a/two.bin", bytes: 10_000)

        let measured = PathSize.measure(fixture.path)
        #expect(measured.files == 2)
        #expect(measured.allocated == (try fixture.duBytes()))
    }
}
