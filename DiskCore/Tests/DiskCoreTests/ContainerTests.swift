import Foundation
import Testing

@testable import DiskCore

@Suite("APFS containers")
struct ContainerTests {

    // MARK: - Fixtures

    private func volume(
        _ identifier: String, _ name: String, _ roles: String, _ bytes: Int64
    ) -> String {
        """
                <dict>
                    <key>CapacityInUse</key><integer>\(bytes)</integer>
                    <key>DeviceIdentifier</key><string>\(identifier)</string>
                    <key>Name</key><string>\(name)</string>
                    <key>Roles</key>\(roles)
                </dict>
        """
    }

    private func roles(_ value: String?) -> String {
        guard let value else { return "<array/>" }
        return "<array><string>\(value)</string></array>"
    }

    private func plist(
        reference: String = "disk3", ceiling: Int64 = 494_384_795_648,
        free: Int64 = 12_179_947_520, volumes: String
    ) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Containers</key>
            <array>
                <dict>
                    <key>ContainerReference</key><string>\(reference)</string>
                    <key>CapacityCeiling</key><integer>\(ceiling)</integer>
                    <key>CapacityFree</key><integer>\(free)</integer>
                    <key>Volumes</key>
                    <array>
        \(volumes)
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """.utf8)
    }

    /// The boot container of the machine this was written against, to the byte.
    private var bootDisk: Data {
        plist(volumes: [
            volume("disk3s1", "Macintosh HD", roles("System"), 18_021_040_128),
            volume("disk3s2", "Preboot", roles("Preboot"), 17_219_166_208),
            volume("disk3s3", "Recovery", roles("Recovery"), 2_626_883_584),
            volume("disk3s4", "Update", roles("Update"), 819_200_000),
            volume("disk3s5", "Macintosh HD - Data", roles("Data"), 426_146_037_760),
            volume("disk3s6", "VM", roles("VM"), 17_193_431_040),
        ].joined(separator: "\n"))
    }

    // MARK: - Parsing

    @Test("A boot container comes back whole, largest volume first")
    func bootContainer() throws {
        let container = try #require(APFSContainer.parse(plist: bootDisk).first)
        #expect(container.reference == "disk3")
        #expect(container.totalBytes == 494_384_795_648)
        #expect(container.freeBytes == 12_179_947_520)
        #expect(container.volumes.count == 6)
        #expect(container.volumes.first?.role == .data)
        #expect(container.volumes.map(\.bytes) == container.volumes
            .map(\.bytes).sorted(by: >))
    }

    @Test("The volumes and the free space account for the whole container")
    func figuresAddUp() throws {
        let container = try #require(APFSContainer.parse(plist: bootDisk).first)
        let accounted = container.usedBytes + container.freeBytes
        // APFS metadata is not attributed to any volume, so the sum lands just
        // under the ceiling — but within a fraction of a percent, or the
        // breakdown would visibly fail to reach its own total on screen.
        #expect(accounted <= container.totalBytes)
        #expect(Double(accounted) / Double(container.totalBytes) > 0.999)
    }

    @Test("What no scan can reach is everything but System and Data")
    func unreachable() throws {
        let container = try #require(APFSContainer.parse(plist: bootDisk).first)
        // Preboot + Recovery + Update + VM.
        #expect(container.unreachableBytes == 37_858_680_832)
        #expect(APFSContainer.Role.system.isReachableByScan)
        #expect(APFSContainer.Role.data.isReachableByScan)
        for role: APFSContainer.Role in [.preboot, .recovery, .vm, .update, .none] {
            #expect(!role.isReachableByScan, "\(role) should be out of reach")
        }
    }

    @Test("A volume with no role keeps its own name and is left alone")
    func rolelessVolume() throws {
        let data = plist(
            reference: "disk5", ceiling: 18_058_575_872, free: 465_244_160,
            volumes: volume(
                "disk5s1", "iOS 26.4.1 Simulator", roles(nil), 17_547_001_856
            )
        )
        let volume = try #require(APFSContainer.parse(plist: data).first?.volumes.first)
        #expect(volume.role == .none)
        #expect(volume.name == "iOS 26.4.1 Simulator")
        #expect(!volume.role.isReachableByScan)
    }

    @Test("A role a future macOS invents decodes rather than failing")
    func unknownRole() throws {
        let data = plist(volumes: volume("disk3s9", "Nouveau", roles("Cryptex"), 1))
        let volume = try #require(APFSContainer.parse(plist: data).first?.volumes.first)
        #expect(volume.role == .none)
        #expect(volume.name == "Nouveau")
    }

    @Test("An unnamed volume falls back to its device identifier")
    func unnamedVolume() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Containers</key><array><dict>
            <key>ContainerReference</key><string>disk9</string>
            <key>CapacityCeiling</key><integer>1000</integer>
            <key>Volumes</key><array><dict>
                <key>DeviceIdentifier</key><string>disk9s1</string>
            </dict></array>
        </dict></array></dict></plist>
        """.utf8)
        let volume = try #require(APFSContainer.parse(plist: data).first?.volumes.first)
        #expect(volume.name == "disk9s1")
        #expect(volume.bytes == 0)
    }

    @Test("Empty, malformed and unexpected plists yield nothing, never a crash")
    func brokenInput() {
        #expect(APFSContainer.parse(plist: Data()).isEmpty)
        #expect(APFSContainer.parse(plist: Data("not a plist".utf8)).isEmpty)
        let noKey = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict/></plist>
        """.utf8)
        #expect(APFSContainer.parse(plist: noKey).isEmpty)
        // A container with no ceiling says nothing about how full it is.
        let noCeiling = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Containers</key><array><dict>
            <key>ContainerReference</key><string>disk9</string>
        </dict></array></dict></plist>
        """.utf8)
        #expect(APFSContainer.parse(plist: noCeiling).isEmpty)
    }

    // MARK: - Matching a mount point to its container

    @Test("The sealed snapshot / is mounted from still matches its volume")
    func sealedSystemVolume() throws {
        let container = try #require(APFSContainer.parse(plist: bootDisk).first)
        // `/` is mounted from disk3s1s1 — a snapshot of disk3s1, one level down.
        #expect(container.contains(device: "disk3s1s1"))
        #expect(container.contains(device: "disk3s5"))
    }

    @Test("A device from another disk is not claimed on a prefix alone")
    func noPartialMatch() throws {
        let container = try #require(APFSContainer.parse(plist: bootDisk).first)
        // The trap: "disk3s1" is a string prefix of "disk30s1".
        #expect(!container.contains(device: "disk30s1"))
        #expect(!container.contains(device: "disk3s10"))
        #expect(!container.contains(device: "disk4s1"))
        #expect(!container.contains(device: ""))
    }

    // MARK: - Against the live system

    @Test("The boot volume resolves to a container whose figures match the APIs")
    func liveContainer() throws {
        let device = try #require(
            APFSContainer.deviceIdentifier(forMountPoint: "/")
        )
        #expect(device.hasPrefix("disk"))
        #expect(!device.hasPrefix("/dev/"))

        let container = try #require(APFSContainer.container(forMountPoint: "/"))
        #expect(container.volumes.contains { $0.role == .data })
        #expect(container.volumes.contains { $0.role == .system })

        // The container ceiling is what URLResourceKey calls the volume's total.
        let values = try URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeTotalCapacityKey])
        #expect(Int64(values.volumeTotalCapacity ?? 0) == container.totalBytes)
    }

    @Test("A path on no APFS container resolves to nothing")
    func nonAPFSMountPoint() {
        #expect(APFSContainer.container(forMountPoint: "/dev") == nil)
        #expect(APFSContainer.deviceIdentifier(forMountPoint: "/nonexistent") == nil)
    }

    // MARK: - Pending macOS update

    @Test("Only the products the index names are measured")
    func updateIndex() {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>ProductPaths</key>
            <dict><key>140-17812</key><string>140-17812</string></dict>
        </dict></plist>
        """.utf8)
        #expect(PendingUpdate.parseIndex(data) == ["140-17812"])
    }

    @Test("An index with no pending product reports none")
    func emptyUpdateIndex() {
        let empty = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>ProductPaths</key><dict/>
        </dict></plist>
        """.utf8)
        // Left to a plain directory size, /Library/Updates would report an
        // update on every Mac forever: it always holds its index, a metadata
        // catalogue and a Rosetta payload.
        #expect(PendingUpdate.parseIndex(empty).isEmpty)
        #expect(PendingUpdate.parseIndex(Data()).isEmpty)
        #expect(PendingUpdate.parseIndex(Data("nonsense".utf8)).isEmpty)
    }

    @Test("A product path that climbs out of the directory is refused")
    func hostileUpdateIndex() {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>ProductPaths</key>
            <dict>
                <key>a</key><string>../../../System</string>
                <key>b</key><string>..</string>
                <key>c</key><string></string>
                <key>d</key><string>140-17812</string>
            </dict>
        </dict></plist>
        """.utf8)
        #expect(PendingUpdate.parseIndex(data) == ["140-17812"])
    }

    @Test("Volumes other than the boot one are never probed for an update")
    func updateOnlyOnRoot() {
        #expect(PendingUpdate.current(mountPoint: "/Volumes/Sauvegarde") == nil)
    }
}
