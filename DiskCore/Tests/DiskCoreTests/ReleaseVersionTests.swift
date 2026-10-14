import Testing

@testable import DiskCore

@Suite("Release versions")
struct ReleaseVersionTests {

    @Test("Compares numerically, not as text")
    func numeric() throws {
        let newer = try #require(ReleaseVersion("0.10.0"))
        let older = try #require(ReleaseVersion("0.9.2"))
        #expect(newer > older)
    }

    @Test("The same release is not newer than itself")
    func same() throws {
        let a = try #require(ReleaseVersion("v0.6.0"))
        let b = try #require(ReleaseVersion("0.6.0"))
        #expect(!(a > b))
        #expect(a == b)
    }

    @Test("Missing components count as zero")
    func missing() throws {
        let short = try #require(ReleaseVersion("1.2"))
        let full = try #require(ReleaseVersion("1.2.0"))
        let patch = try #require(ReleaseVersion("1.2.1"))
        #expect(short == full)
        #expect(short < patch)
        #expect(Set([short, full]).count == 1)
    }

    @Test("Keeps the spelling it was given, minus the v")
    func spelling() {
        #expect(ReleaseVersion("v0.6.0")?.description == "0.6.0")
        #expect(ReleaseVersion("1.2")?.description == "1.2")
    }

    @Test("Refuses what it cannot read",
          arguments: ["", "v", "abc", "1.2-beta", "1..2", "1.2.", "+1.2", "1.٢"])
    func refuses(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }
}
