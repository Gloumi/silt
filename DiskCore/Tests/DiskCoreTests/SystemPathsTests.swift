import Foundation
import Testing

@testable import DiskCore

@Suite("System paths")
struct SystemPathsTests {

    @Test("The darwin cache dir resolves, canonical and real")
    func cacheDir() throws {
        let cache = try #require(SystemPaths.darwinUserCache)
        #expect(cache.hasPrefix("/private/var/folders/"))
        #expect(!cache.hasSuffix("/"))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cache, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("The darwin temp dir resolves, canonical")
    func tempDir() throws {
        let temp = try #require(SystemPaths.darwinUserTemp)
        #expect(temp.hasPrefix("/private/var/folders/"))
        #expect(!temp.hasSuffix("/"))
    }

    @Test("Canonicalisation rewrites /var and strips trailing slashes")
    func canonicalisation() {
        #expect(SystemPaths.canonical("/var/folders/ab/cd/C/") == "/private/var/folders/ab/cd/C")
        #expect(SystemPaths.canonical("/private/var/folders/ab/cd/T") == "/private/var/folders/ab/cd/T")
        #expect(SystemPaths.canonical("/var") == "/private/var")
        #expect(SystemPaths.canonical("/variations") == "/variations")
    }
}
