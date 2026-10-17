import CryptoKit
import DiskCore
import Foundation
import Security
import Synchronization

/// Reads and writes the saved scans. No main actor: everything here runs on
/// background tasks, so a big scan never freezes the window while it is saved
/// or restored.
///
/// The files live in Caches, not Application Support: a saved scan is only a
/// shortcut to a result that can be recomputed, and the system may reclaim the
/// space when the disk is full — which is the one moment this app is opened.
///
/// A scan lists every path under the root, so the files are sealed with a key
/// held in the keychain: a copy of the folder alone reveals nothing. Release
/// builds only. A Debug build is rebuilt all day and, being signed differently
/// each time, would lose the key each time; it stores its scans unsealed in a
/// folder of its own and never touches the keychain.
enum ScanVault {
    /// Writes the scan, replacing any earlier one of the same root. Atomic, so a
    /// crash mid-write leaves the old file rather than a truncated one.
    static func save(_ scan: SavedScan) {
        guard let key = sealingKey() else { return }
        guard let sealed = try? ScanSealing.seal(scan.encoded(), key: key.value) else { return }
        let url = fileURL(for: scan.rootPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: url, options: .atomic)
    }

    static func remove(rootPath: String) {
        try? FileManager.default.removeItem(at: fileURL(for: rootPath))
    }

    /// Every scan that can still be read. A file that cannot be opened or
    /// decoded — another format version, a damaged write, a lost key — is
    /// deleted on the spot: it will never be readable again, and keeping it
    /// would only cost space.
    static func loadAll() -> [SavedScan] {
        guard let key = sealingKey() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var scans: [SavedScan] = []
        for file in files where file.pathExtension == fileExtension {
            if let sealed = try? Data(contentsOf: file),
               let plain = ScanSealing.open(sealed, key: key.value),
               let scan = SavedScan(decoding: plain) {
                scans.append(scan)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return scans
    }

    // MARK: - Files

    private static let fileExtension = "siltscan"

    private static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if DEBUG
        return caches.appendingPathComponent("app.silt.mac/Scans-debug", isDirectory: true)
        #else
        return caches.appendingPathComponent("app.silt.mac/Scans", isDirectory: true)
        #endif
    }

    /// The root path is hashed so any path, however long or odd, gives a valid
    /// file name; 16 bytes keep collisions out of reach.
    private static func fileURL(for rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
    }

    private static func emptyDirectory() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Key

    /// The key to seal with. Wrapped so that "no key by design" (Debug: `value`
    /// is nil) is told apart from "no key available" (the function returns nil).
    private struct Sealing {
        let value: SymmetricKey?
    }

    #if !DEBUG
    private static let service = "app.silt.mac.scans"
    private static let accountDefaultsKey = "scanKeyAccount"

    /// Read once per launch. The lock also serialises the first read, so two
    /// background tasks cannot each create a key and wipe the other's files.
    private static let cachedKey = Mutex<SymmetricKey?>(nil)
    #endif

    private static func sealingKey() -> Sealing? {
        #if DEBUG
        return Sealing(value: nil)
        #else
        return cachedKey.withLock { cached in
            if let cached { return Sealing(value: cached) }
            let key = readKey() ?? createKey()
            cached = key
            return key.map { Sealing(value: $0) }
        }
        #endif
    }

    #if !DEBUG
    /// Never shows a keychain dialog: with `UIFail` a read that would need the
    /// user returns an error instead. An ad-hoc signed build cannot read the
    /// item its predecessor created, so that error is the normal case after an
    /// update, and the caller answers it with a new key.
    private static func readKey() -> SymmetricKey? {
        guard let account = UserDefaults.standard.string(forKey: accountDefaultsKey) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Replaces a key that cannot be read. The old item is left in the keychain:
    /// deleting it could raise the very dialog this avoids. A fresh account name
    /// sidesteps it, and the files sealed with the lost key are emptied since
    /// nothing can open them. If the new key cannot be stored the vault stays
    /// off: a key that would not survive the launch only produces files that
    /// the next launch deletes.
    private static func createKey() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let account = "scans-" + UUID().uuidString
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        UserDefaults.standard.set(account, forKey: accountDefaultsKey)
        emptyDirectory()
        return key
    }
    #endif
}
