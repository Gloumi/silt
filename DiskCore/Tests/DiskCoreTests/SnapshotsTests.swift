import Foundation
import Testing

@testable import DiskCore

@Suite("APFS snapshots")
struct SnapshotsTests {

    // MARK: - Fixtures

    /// The shape `diskutil apfs listSnapshots -plist` really returns, taken
    /// from a machine carrying one installer snapshot.
    private func plist(_ entries: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Snapshots</key>
            <array>
        \(entries)
            </array>
        </dict>
        </plist>
        """.utf8)
    }

    private func entry(
        name: String, uuid: String, xid: Int, purgeable: Bool = true,
        limiting: Bool = false
    ) -> String {
        """
            <dict>
                <key>LimitingContainerShrink</key><\(limiting)/>
                <key>Purgeable</key><\(purgeable)/>
                <key>RevertTo</key><false/>
                <key>RootTo</key><false/>
                <key>SnapshotName</key><string>\(name)</string>
                <key>SnapshotUUID</key><string>\(uuid)</string>
                <key>SnapshotXID</key><integer>\(xid)</integer>
            </dict>
        """
    }

    // MARK: - Listing

    @Test("An installer snapshot is recognised, dateless and undeletable")
    func systemSnapshot() throws {
        let data = plist(entry(
            name: "com.apple.os.update-6089F13356F8D483C8F0189F0FF5A855",
            uuid: "784A53DB-AD55-43B6-921F-AA0F29F0F450",
            xid: 60_330_549, purgeable: false, limiting: true
        ))
        let snapshots = APFSSnapshots.parse(plist: data)
        let snapshot = try #require(snapshots.first)
        #expect(snapshots.count == 1)
        #expect(snapshot.kind == .system)
        #expect(snapshot.date == nil)
        #expect(snapshot.stamp == nil)
        #expect(!snapshot.isDeletable)
        #expect(!snapshot.isPurgeable)
        #expect(snapshot.limitsContainerShrink)
        #expect(snapshot.xid == 60_330_549)
        #expect(snapshot.id == "784A53DB-AD55-43B6-921F-AA0F29F0F450")
    }

    @Test("A Time Machine snapshot carries its date and can be deleted")
    func timeMachineSnapshot() throws {
        let data = plist(entry(
            name: "com.apple.TimeMachine.2026-08-05-141530.local",
            uuid: "11111111-2222-3333-4444-555555555555", xid: 42
        ))
        let snapshot = try #require(APFSSnapshots.parse(plist: data).first)
        #expect(snapshot.kind == .timeMachine)
        #expect(snapshot.stamp == "2026-08-05-141530")
        #expect(snapshot.isDeletable)

        let date = try #require(snapshot.date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        // Parsed in the machine's own zone, which is how Time Machine names them.
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 5)
        #expect(parts.hour == 14)
        #expect(parts.minute == 15)
        #expect(parts.second == 30)
    }

    @Test("Several snapshots come back newest first, undated ones last")
    func ordering() {
        let data = plist([
            entry(
                name: "com.apple.TimeMachine.2026-08-01-090000.local",
                uuid: "A", xid: 10
            ),
            entry(name: "com.apple.os.update-abc", uuid: "B", xid: 5),
            entry(
                name: "com.apple.TimeMachine.2026-08-05-141530.local",
                uuid: "C", xid: 20
            ),
        ].joined(separator: "\n"))
        let names = APFSSnapshots.parse(plist: data)
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .map(\.uuid)
        #expect(names == ["C", "A", "B"])
    }

    @Test("An unnamed snapshot is dropped rather than half-listed")
    func missingName() {
        let data = plist("""
            <dict>
                <key>SnapshotUUID</key><string>A</string>
            </dict>
        """)
        #expect(APFSSnapshots.parse(plist: data).isEmpty)
    }

    @Test("Empty, malformed and unexpected plists yield nothing, never a crash")
    func brokenInput() {
        #expect(APFSSnapshots.parse(plist: Data()).isEmpty)
        #expect(APFSSnapshots.parse(plist: Data("not a plist at all".utf8)).isEmpty)
        #expect(APFSSnapshots.parse(plist: plist("")).isEmpty)
        // A volume with no snapshots: diskutil omits the key entirely.
        let noKey = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict/></plist>
        """.utf8)
        #expect(APFSSnapshots.parse(plist: noKey).isEmpty)
    }

    @Test("An unfamiliar snapshot name is listed as other, and left alone")
    func foreignSnapshot() throws {
        let data = plist(entry(name: "com.acme.backup.7", uuid: "A", xid: 1))
        let snapshot = try #require(APFSSnapshots.parse(plist: data).first)
        #expect(snapshot.kind == .other)
        #expect(!snapshot.isDeletable)
    }

    // MARK: - tmutil cross-reference

    @Test("The tmutil heading is not mistaken for a snapshot")
    func tmutilHeading() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-08-05-141530.local
        com.apple.TimeMachine.2026-08-04-090000.local
        """
        #expect(APFSSnapshots.parseTimeMachine(output) == [
            "com.apple.TimeMachine.2026-08-05-141530.local",
            "com.apple.TimeMachine.2026-08-04-090000.local",
        ])
    }

    @Test("A volume with no local snapshots parses to an empty list")
    func tmutilEmpty() {
        #expect(APFSSnapshots.parseTimeMachine("Snapshots for disk /:\n").isEmpty)
        #expect(APFSSnapshots.parseTimeMachine("").isEmpty)
    }

    @Test("Indented tmutil output still parses")
    func tmutilIndented() {
        let output = "Snapshots for disk /:\n  com.apple.TimeMachine.2026-08-05-141530.local\n"
        #expect(APFSSnapshots.parseTimeMachine(output).count == 1)
    }

    // MARK: - Stamps

    @Test("A stamp is four groups of digits, or it is refused")
    func stampValidation() {
        #expect(APFSSnapshots.isValidStamp("2026-08-05-141530"))
        #expect(!APFSSnapshots.isValidStamp("2026-8-5-1415"))
        #expect(!APFSSnapshots.isValidStamp("2026-08-05-14153"))
        #expect(!APFSSnapshots.isValidStamp("2026-08-05-141530-1"))
        #expect(!APFSSnapshots.isValidStamp(""))
        #expect(!APFSSnapshots.isValidStamp("2026-08-05 141530"))
        #expect(!APFSSnapshots.isValidStamp("202X-08-05-141530"))
    }

    @Test("A stamp that would reach the shell is refused before it gets there")
    func stampInjection() {
        for hostile in [
            "2026-08-05-141530; rm -rf /",
            "2026-08-05-141530'",
            "$(whoami)",
            "`id`",
            "2026-08-05-141530\n2026-08-05-141531",
            "* ",
        ] {
            #expect(!APFSSnapshots.isValidStamp(hostile), "accepted \(hostile)")
        }
        let outcome = SnapshotDeleter.delete(stamps: ["2026-08-05-141530; rm -rf /"])
        #expect(outcome.status == .failed)
        #expect(outcome.deleted.isEmpty)
    }

    @Test("A hostile name yields no stamp, so it can never be deleted")
    func hostileSnapshotName() throws {
        let data = plist(entry(
            name: "com.apple.TimeMachine.2026-08-05-141530; rm -rf /.local",
            uuid: "A", xid: 1
        ))
        let snapshot = try #require(APFSSnapshots.parse(plist: data).first)
        #expect(snapshot.kind == .timeMachine)
        #expect(snapshot.stamp == nil)
        #expect(!snapshot.isDeletable)
    }

    // MARK: - Deletion plumbing

    @Test("Per-snapshot verdicts are split, and silence counts as failure")
    func deletionVerdicts() {
        let output = """
        OK 2026-08-05-141530
        KO 2026-08-04-090000
        """
        let expected = [
            "2026-08-05-141530", "2026-08-04-090000", "2026-08-03-080000",
        ]
        let (deleted, failed) = SnapshotDeleter.parse(output, expected: expected)
        #expect(deleted == ["2026-08-05-141530"])
        #expect(failed == ["2026-08-04-090000", "2026-08-03-080000"])
    }

    @Test("An empty selection is a no-op, not a run")
    func deletingNothing() {
        #expect(SnapshotDeleter.delete(stamps: []).status == .done)
        #expect(SnapshotDeleter.thin(mountPoint: "/", bytes: 0).status == .done)
    }

    @Test("A dismissed password dialog reads as cancelled, not as an error")
    func cancellation() {
        #expect(SnapshotDeleter.isCancellation(
            "/dev/fd/0:139:154: execution error: User canceled. (-128)"
        ))
        #expect(!SnapshotDeleter.isCancellation(
            "/dev/fd/0:139:154: execution error: tmutil: unrecognized (1)"
        ))
    }

    @Test("The reported reason drops osascript's file:line preamble")
    func errorReason() {
        #expect(SnapshotDeleter.reason(
            from: "/dev/fd/0:1:2: execution error: Something broke. (1)"
        ) == "Something broke. (1)")
        #expect(SnapshotDeleter.reason(from: "") == nil)
        #expect(SnapshotDeleter.reason(from: "   \n  ") == nil)
    }

    @Test("A volume path is quoted for AppleScript, then for the shell")
    func pathQuoting() {
        #expect(SnapshotDeleter.literal("/Volumes/Sauve") == "\"/Volumes/Sauve\"")
        #expect(
            SnapshotDeleter.literal("/Volumes/A\"B\\C")
                == "\"/Volumes/A\\\"B\\\\C\""
        )
        #expect(
            SnapshotDeleter.argument("/Volumes/Mon disque")
                == "quoted form of \"/Volumes/Mon disque\""
        )
    }

    // MARK: - Against the live system

    @Test("The boot volume is APFS and answers a listing without privileges")
    func liveVolume() {
        #expect(APFSSnapshots.isAPFS(mountPoint: "/"))
        #expect(!APFSSnapshots.isAPFS(mountPoint: "/dev"))
        // Whatever this machine carries, listing it must not throw or hang.
        for snapshot in APFSSnapshots.list(mountPoint: "/") {
            #expect(!snapshot.uuid.isEmpty)
            #expect(!snapshot.name.isEmpty)
        }
    }

    @Test("Asking about / reaches the Data volume, where the snapshots are")
    func bootDiskIncludesDataVolume() {
        // Time Machine snapshots the Data volume; the sealed System volume at /
        // never carries one, and the Data volume is hidden from every mounted
        // volume enumeration. Miss this and the tool finds nothing on a boot
        // disk while `tmutil listlocalsnapshots` lists plenty.
        let companions = APFSSnapshots.companions(of: "/")
        #expect(companions.first == "/")
        #expect(companions.contains("/System/Volumes/Data"))
    }

    @Test("Thinning amounts never exceed what the volume is holding back")
    func thinningTargets() {
        // 5,54 GB reserved: offering 50 GB would be a promise the system
        // cannot keep.
        #expect(SnapshotDeleter.thinningTargets(upTo: 5_540_000_000)
            == [1_000_000_000, 2_000_000_000, 5_000_000_000])
        #expect(SnapshotDeleter.thinningTargets(upTo: 900_000_000).isEmpty)
        #expect(SnapshotDeleter.thinningTargets(upTo: 0).isEmpty)
        // Never more than three, however much is held back.
        #expect(SnapshotDeleter.thinningTargets(upTo: 900_000_000_000).count == 3)
    }

    @Test("A volume with no Data companion is asked about on its own")
    func standaloneVolume() {
        #expect(APFSSnapshots.companions(of: "/nonexistent") == ["/nonexistent"])
    }

    @Test("Every listed snapshot says which volume it lives on")
    func snapshotsCarryTheirMountPoint() {
        for snapshot in APFSSnapshots.list(mountPoint: "/") {
            #expect(APFSSnapshots.companions(of: "/").contains(snapshot.mountPoint))
        }
    }
}
