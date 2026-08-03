import Foundation
import Testing

@testable import DiskCore

@Suite("Deny list")
struct DenyListTests {

    @Test("System locations are refused", arguments: [
        "/", "/System", "/System/Library/CoreServices", "/bin", "/bin/zsh",
        "/sbin", "/usr", "/usr/bin/swift", "/Library/Apple", "/dev",
        "/private/etc/hosts", "/private/var/db/anything", "/Volumes",
    ])
    func systemPathsRefused(path: String) {
        #expect(DenyList.verdict(for: path).isForbidden, "\(path) devrait être refusé")
    }

    @Test("Home and volume roots are refused")
    func rootsRefused() {
        #expect(DenyList.verdict(for: NSHomeDirectory()).isForbidden)
        #expect(DenyList.verdict(for: "/Users/someone").isForbidden)
        #expect(DenyList.verdict(for: "/Volumes/Backup").isForbidden)
        // One level down a volume is ordinary data again.
        #expect(DenyList.verdict(for: "/Volumes/Backup/old") == .allowed)
    }

    @Test("Keychains are refused")
    func keychainsRefused() {
        #expect(
            DenyList.verdict(for: NSHomeDirectory() + "/Library/Keychains")
                .isForbidden
        )
    }

    /// The single most likely way to lose real work with this app.
    @Test("/usr/local is carved out of the /usr ban")
    func usrLocalIsCaution() {
        #expect(DenyList.verdict(for: "/usr").isForbidden)
        #expect(DenyList.verdict(for: "/usr/bin").isForbidden)
        if case .caution = DenyList.verdict(for: "/usr/local/Cellar/node") {
        } else {
            Issue.record("/usr/local devrait être autorisé avec avertissement")
        }
    }

    @Test("Irreplaceable user data warns rather than deletes silently")
    func sensitiveUserDataWarns() {
        let home = NSHomeDirectory()
        for path in [
            home + "/Library/Application Support/MobileSync/Backup",
            home + "/Library/Mail/V10",
            home + "/Pictures/Photos Library.photoslibrary",
            "/Applications/Safari.app",
        ] {
            if case .caution = DenyList.verdict(for: path) {} else {
                Issue.record("\(path) devrait avertir")
            }
        }
    }

    @Test("/private/var/folders is protected except the user's own cache and temp")
    func varFoldersHardened() throws {
        for path in [
            "/private/var/folders", "/private/var/folders/ab",
            "/private/var/folders/ab/hash", "/var/folders/ab/hash/0",
        ] {
            #expect(DenyList.verdict(for: path).isForbidden, "\(path) devrait être refusé")
        }
        let cache = try #require(SystemPaths.darwinUserCache)
        #expect(DenyList.verdict(for: cache).isForbidden)
        #expect(DenyList.verdict(for: cache + "/com.apple.Safari") == .allowed)
        // The short /var spelling has to land on the same verdicts.
        let short = String(cache.dropFirst("/private".count))
        #expect(DenyList.verdict(for: short + "/com.apple.Safari") == .allowed)
        let temp = try #require(SystemPaths.darwinUserTemp)
        #expect(DenyList.verdict(for: temp).isForbidden)
        if case .caution = DenyList.verdict(for: temp + "/scratch") {} else {
            Issue.record("le dossier temporaire devrait avertir")
        }
        #expect(DenyList.verdict(for: "/private/var/vm/swapfile0").isForbidden)
    }

    @Test("Ordinary junk is allowed without ceremony")
    func ordinaryPathsAllowed() {
        let home = NSHomeDirectory()
        for path in [
            home + "/Downloads/big.dmg",
            home + "/projet/node_modules",
            home + "/Library/Developer/Xcode/DerivedData",
            "/tmp/scratch",
        ] {
            #expect(DenyList.verdict(for: path) == .allowed, "\(path)")
        }
    }

    /// A prefix test done with plain `hasPrefix` would refuse this, since it
    /// starts with the characters of "/usr".
    @Test("Prefix matching respects path boundaries")
    func prefixMatchingIsPathAware() {
        #expect(DenyList.verdict(for: NSHomeDirectory() + "/usrdata") == .allowed)
        #expect(DenyList.verdict(for: "/Systematic") == .allowed)
    }
}

@Suite("Safe deleter")
struct SafeDeleterTests {

    @Test("Trashes a file, then puts it back")
    func trashAndRestore() throws {
        let fixture = try Fixture()
        let file = try fixture.file("junk.bin", bytes: 4_096)

        let report = SafeDeleter.moveToTrash([
            .init(node: 1, path: file.path, bytes: 4_096)
        ])
        #expect(report.failures.isEmpty)
        #expect(report.refused.isEmpty)
        #expect(report.trashed.count == 1)
        #expect(report.reclaimedBytes == 4_096)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let failures = SafeDeleter.restore(report.trashed)
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Refuses a protected path even when asked directly")
    func refusesProtectedPath() {
        let report = SafeDeleter.moveToTrash([
            .init(node: 1, path: "/System/Library", bytes: 1)
        ])
        #expect(report.trashed.isEmpty)
        #expect(report.refused.count == 1)
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
    }

    @Test("Restoring never overwrites something new at the old path")
    func restoreDoesNotOverwrite() throws {
        let fixture = try Fixture()
        let file = try fixture.file("contested.bin", bytes: 1_024)

        let report = SafeDeleter.moveToTrash([
            .init(node: 1, path: file.path, bytes: 1_024)
        ])
        #expect(report.trashed.count == 1)

        // Something else takes the name before the user hits undo.
        try Data("replacement".utf8).write(to: file)
        let failures = SafeDeleter.restore(report.trashed)
        #expect(failures.count == 1)
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))

        // Clean up the copy left behind in the Trash.
        if let trashPath = report.trashed[0].trashPath {
            try? FileManager.default.removeItem(atPath: trashPath)
        }
    }
}

@Suite("Tree bookkeeping after deletion")
struct DeletionBookkeepingTests {

    @Test("Deleting credits the bytes back up the tree")
    func markDeletedRollsBack() async throws {
        let fixture = try Fixture()
        try fixture.file("keep/small.bin", bytes: 1_000)
        try fixture.file("drop/big.bin", bytes: 200_000)

        let result = await ScanEngine.scan(root: fixture.path)
        var store = result.store
        let before = store.totalAlloc[0]

        let drop = try #require(
            store.children(of: 0).first { store.name(of: $0) == "drop" }
        )
        let dropped = store.totalAlloc[Int(drop)]
        #expect(dropped > 0)

        store.markDeleted(drop)
        #expect(store.totalAlloc[0] == before - dropped)
        #expect(store.flags[Int(drop)].contains(.deleted))
        // And it stops showing up as a child.
        #expect(!store.childrenSortedBySize(of: 0).contains(drop))

        store.unmarkDeleted(drop, alloc: dropped, logical: dropped, files: 1)
        #expect(store.totalAlloc[0] == before)
        #expect(store.childrenSortedBySize(of: 0).contains(drop))
    }

    @Test("Deleting deep in the tree credits every ancestor")
    func deltaReachesTheRoot() async throws {
        let fixture = try Fixture()
        try fixture.file("a/b/c/deep.bin", bytes: 120_000)

        let result = await ScanEngine.scan(root: fixture.path)
        var store = result.store

        var node: Int32 = 0
        var chain: [Int32] = [0]
        for component in ["a", "b", "c", "deep.bin"] {
            node = try #require(
                store.children(of: node).first { store.name(of: $0) == component }
            )
            chain.append(node)
        }
        let sizesBefore = chain.map { store.totalAlloc[Int($0)] }
        let leafSize = store.totalAlloc[Int(node)]

        store.markDeleted(node)
        for (index, ancestor) in chain.dropLast().enumerated() {
            #expect(store.totalAlloc[Int(ancestor)] == sizesBefore[index] - leafSize)
        }
        #expect(store.totalAlloc[Int(node)] == 0)
    }
}
