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

    /// Trashing one of these strands it: the Finder can then neither empty it
    /// nor put it back. Refused outright, where the enclosing folder only warns.
    @Test("macOS's own sandbox containers are refused")
    func systemContainersForbidden() {
        let home = NSHomeDirectory()
        for path in [
            home + "/Library/Containers/com.apple.WorkflowKit.BackgroundShortcutRunner",
            home + "/Library/Containers/com.apple.Safari/Data",
            home + "/Library/Group Containers/group.com.apple.CoreSpeech",
        ] {
            #expect(DenyList.verdict(for: path).isForbidden, "\(path) devrait être refusé")
        }
        // Third-party containers keep the milder verdict: they are the user's.
        if case .caution = DenyList.verdict(
            for: home + "/Library/Containers/com.docker.docker/Data"
        ) {} else {
            Issue.record("un conteneur tiers devrait avertir, pas refuser")
        }
        // The folder itself is not a container, and stays a warning.
        #expect(!DenyList.verdict(for: home + "/Library/Containers").isForbidden)
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

        // The `X` sibling of C and T, where macOS clones a running app's
        // bundle to check its signature. Those clones are byte-identical to
        // the app, so the duplicates view finds them and would offer them —
        // which is why it now asks this question before listing anything.
        let clone = "/private/var/folders/6_/abcdefg/X/"
            + "com.google.Chrome.code_sign_clone/code_sign_clone.gY0GQp"
        #expect(DenyList.verdict(for: clone).isForbidden)
        #expect(DenyList.verdict(for: clone + "/Google Chrome.app.bundle").isForbidden)
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

@Suite("Volume trash")
struct VolumeTrashTests {

    private func mount(
        _ point: String, fileSystem: String = "apfs",
        readOnly: Bool = false, local: Bool = true
    ) -> VolumeTrashProbe.Mount {
        .init(
            point: point, fileSystem: fileSystem,
            isReadOnly: readOnly, isLocal: local
        )
    }

    /// The branch that keeps a probe file from ever landing on a system volume
    /// — and the reason the counter, not just the verdict, is asserted.
    @Test("The home volume answers without being probed")
    func homeVolumeIsUsableUnprobed() {
        var probes = 0
        let verdict = VolumeTrashProbe.decide(
            mount: mount("/System/Volumes/Data"),
            homeMountPoint: "/System/Volumes/Data",
            probe: { probes += 1; return .leftInPlace }
        )
        #expect(verdict == .usable)
        #expect(probes == 0)
    }

    @Test("A read-only volume is neither trashable nor erasable")
    func readOnlyIsItsOwnVerdict() {
        // `/` itself is this case: apfs, local, and mounted read-only.
        #expect(
            VolumeTrashProbe.decide(
                mount: mount("/", readOnly: true),
                homeMountPoint: "/System/Volumes/Data",
                probe: { .trashed }
            ) == .readOnly
        )
    }

    @Test("Only a probe that watched the original stay put allows erasing")
    func leftInPlaceIsTheOnlyRouteToUnusable() {
        #expect(
            VolumeTrashProbe.decide(
                mount: mount("/Volumes/Stick", fileSystem: "exfat"),
                homeMountPoint: "/System/Volumes/Data",
                probe: { .leftInPlace }
            ) == .unusable
        )
    }

    /// The false negative that matters: an exFAT stick can carry a perfectly
    /// good `.Trashes`, and condemning it by filesystem type would turn a
    /// reversible deletion into an irreversible one.
    @Test("A foreign volume whose trash works keeps its trash")
    func workingTrashSurvivesItsFilesystemType() {
        for type in ["exfat", "msdos", "ntfs", "smbfs"] {
            #expect(
                VolumeTrashProbe.decide(
                    mount: mount("/Volumes/Stick", fileSystem: type, local: false),
                    homeMountPoint: "/System/Volumes/Data",
                    probe: { .trashed }
                ) == .usable,
                "\(type) devrait garder sa corbeille"
            )
        }
    }

    @Test("Knowing nothing authorises nothing")
    func couldNotTestFallsBackToTheTrash() {
        #expect(
            VolumeTrashProbe.decide(
                mount: mount("/Volumes/Share", fileSystem: "smbfs", local: false),
                homeMountPoint: "/System/Volumes/Data",
                probe: { .couldNotTest }
            ) == .usable
        )
    }

    /// The real thing, in a real folder on the volume the tests already run on.
    /// Slow-ish, and the only test that exercises the code that will run.
    @Test("The live probe finds a working trash and cleans up after itself")
    func liveProbeLeavesNothingBehind() throws {
        let fixture = try Fixture()
        #expect(VolumeTrashProbe.probe(in: fixture.path) == .trashed)

        let residue = try FileManager.default.contentsOfDirectory(
            atPath: fixture.path
        )
        #expect(!residue.contains { $0.hasPrefix(VolumeTrashProbe.probePrefix) })
    }
}

@Suite("Safe deleter")
struct SafeDeleterTests {

    @Test("Trashes a file, then puts it back")
    func trashAndRestore() throws {
        let fixture = try Fixture()
        let file = try fixture.file("junk.bin", bytes: 4_096)

        let report = SafeDeleter.delete([
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
        let report = SafeDeleter.delete([
            .init(node: 1, path: "/System/Library", bytes: 1)
        ])
        #expect(report.trashed.isEmpty)
        #expect(report.refused.count == 1)
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
    }

    /// The deny list sits ahead of the permanent flag, and this is the test
    /// that says so: a protected path is protected all the more when what is
    /// being asked for cannot be undone.
    @Test("The deny list outranks the permanent flag")
    func denyListOutranksPermanence() {
        let report = SafeDeleter.delete([
            .init(node: 1, path: "/System/Library", bytes: 1, permanent: true)
        ])
        #expect(report.trashed.isEmpty)
        #expect(report.refused.count == 1)
        #expect(FileManager.default.fileExists(atPath: "/System/Library"))
    }

    @Test("A permanent request goes nowhere it could be recovered from")
    func permanentLeavesNoTrace() throws {
        let fixture = try Fixture()
        let file = try fixture.file("gone.bin", bytes: 2_048)

        let report = SafeDeleter.delete([
            .init(node: 1, path: file.path, bytes: 2_048, permanent: true)
        ])
        #expect(report.failures.isEmpty)
        #expect(report.trashed.count == 1)
        #expect(report.trashed[0].trashPath == nil)
        #expect(report.erased.count == 1)
        #expect(report.restorable.isEmpty)
        #expect(report.reclaimedNowBytes == 2_048)
        #expect(report.reclaimedOnEmptyingBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Nothing downstream may offer it back.
        #expect(TrashLedger.record(report.trashed, at: Date(), into: []).isEmpty)
        #expect(SafeDeleter.restore(report.trashed).count == 1)
    }

    @Test("A permanent request takes a whole folder with it")
    func permanentRemovesSubtrees() throws {
        let fixture = try Fixture()
        try fixture.file("doomed/deep/inside.bin", bytes: 1_000)
        let folder = fixture.path + "/doomed"

        let report = SafeDeleter.delete([
            .init(node: 1, path: folder, bytes: 1_000, permanent: true)
        ])
        #expect(report.trashed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    /// The bug this whole route exists for, staged: the trash reports success
    /// and the original is still there.
    @Test("A trash that only copied is reported, not counted")
    func lyingTrashIsCaught() throws {
        let fixture = try Fixture()
        let file = try fixture.file("copied.bin", bytes: 1_024)

        var strays: [String] = []
        let report = SafeDeleter.delete(
            [.init(node: 1, path: file.path, bytes: 1_024)],
            presence: { path in
                strays.append(path)
                return path == file.path ? .present : .absent
            }
        )
        #expect(report.trashed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures[0].isTrashUnusable)
        #expect(report.strandedByTrash.count == 1)
        #expect(strays == [file.path])
        // The copy the trash made was cleared away rather than left to take up
        // the space twice.
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The guard on the one deletion the user never asked for by name.
    @Test("Stray copies are only ever removed from inside a trash")
    func strayCopiesStayInsideTheTrash() throws {
        let fixture = try Fixture()
        let outside = try fixture.file("elsewhere.bin", bytes: 16)
        #expect(!SafeDeleter.discardStrayCopy(at: outside.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))

        let inside = try fixture.file(".Trashes/501/decoy.bin", bytes: 16)
        #expect(SafeDeleter.discardStrayCopy(at: inside.path))
        #expect(!FileManager.default.fileExists(atPath: inside.path))
    }

    @Test("A mixed batch reports both halves apart")
    func mixedBatchSplitsItsReport() throws {
        let fixture = try Fixture()
        let kept = try fixture.file("trashed.bin", bytes: 100)
        let erased = try fixture.file("erased.bin", bytes: 200)

        let report = SafeDeleter.delete([
            .init(node: 1, path: kept.path, bytes: 100),
            .init(node: 2, path: erased.path, bytes: 200, permanent: true),
        ])
        #expect(report.failures.isEmpty)
        #expect(report.restorable.count == 1)
        #expect(report.erased.count == 1)
        #expect(report.reclaimedBytes == 300)
        #expect(report.reclaimedNowBytes == 200)
        #expect(report.reclaimedOnEmptyingBytes == 100)

        if let trashPath = report.restorable[0].trashPath {
            try? FileManager.default.removeItem(atPath: trashPath)
        }
    }

    /// No Finder fallback, no elevation: a permission error on the permanent
    /// route stays a failure the user is told about.
    @Test("A refused permanent deletion stays refused")
    func permanentDoesNotEscalate() throws {
        let fixture = try Fixture()
        let file = try fixture.file("locked/inside.bin", bytes: 32)
        let folder = fixture.path + "/locked"
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: folder
        )
        // Put the write bit back whatever happens, or the fixture cannot clean
        // itself up and leaves the directory behind in the temp folder.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: folder
            )
        }

        let report = SafeDeleter.delete([
            .init(node: 1, path: file.path, bytes: 32, permanent: true)
        ])
        #expect(report.trashed.isEmpty)
        #expect(report.failures.count == 1)
        #expect(report.failures[0].isPermissionDenied)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Restoring never overwrites something new at the old path")
    func restoreDoesNotOverwrite() throws {
        let fixture = try Fixture()
        let file = try fixture.file("contested.bin", bytes: 1_024)

        let report = SafeDeleter.delete([
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

    @Test("Everything under a trashed folder counts as trashed too")
    func deletionReachesDescendants() async throws {
        let fixture = try Fixture()
        try fixture.file("gone/deep/inside.bin", bytes: 1_000)
        try fixture.file("kept/elsewhere.bin", bytes: 1_000)

        let result = await ScanEngine.scan(root: fixture.path)
        var store = result.store
        let gone = try #require(store.child(of: 0, named: "gone"))
        let inside = try #require(
            store.descendant(of: 0, at: ["gone", "deep", "inside.bin"])
        )
        let elsewhere = try #require(
            store.descendant(of: 0, at: ["kept", "elsewhere.bin"])
        )

        store.markDeleted(gone)
        // The flag itself never travels — that is the whole reason the question
        // has to be asked of the ancestors.
        #expect(!store.flags[Int(inside)].contains(.deleted))
        #expect(store.isEffectivelyDeleted(inside))
        #expect(store.isEffectivelyDeleted(gone))
        #expect(!store.isEffectivelyDeleted(elsewhere))
        #expect(!store.isEffectivelyDeleted(0))
    }
}

@Suite("Finder trash fallback")
struct FinderTrashTests {

    @Test("Output lines map back to input paths, empties meaning failure")
    func parseAlignsWithInput() {
        let output = "/Users/x/.Trash/A.app/\n\n/Users/x/.Trash/b.plist\n"
        let landed = FinderTrash.parse(output, count: 3)
        #expect(landed == ["/Users/x/.Trash/A.app", nil, "/Users/x/.Trash/b.plist"])
    }

    @Test("A line count that does not match the batch fails every item")
    func parseRejectsMismatch() {
        #expect(FinderTrash.parse("/only/one\n", count: 2) == [nil, nil])
        #expect(FinderTrash.parse("", count: 1) == [nil])
    }
}
