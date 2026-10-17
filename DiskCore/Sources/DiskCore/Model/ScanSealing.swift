import Foundation
import CryptoKit
import Compression

/// Compression and optional encryption of a `SavedScan`'s bytes.
///
/// A scan lists every path on the disk, which is exactly what someone with
/// a copy of the file would want to read, so it can be locked with a key.
/// Compression comes first because ciphertext does not compress: LZFSE is
/// the one that keeps decode time well below the scan it replaces.
public enum ScanSealing {

    public enum SealingError: Error {
        case compressionFailed
        case encryptionFailed
    }

    /// LZFSE, then AES-GCM when `key` is not nil.
    public static func seal(_ plain: Data, key: SymmetricKey?) throws -> Data {
        let compressed: Data
        do {
            compressed = try (plain as NSData).compressed(using: .lzfse) as Data
        } catch {
            throw SealingError.compressionFailed
        }
        guard let key else { return compressed }
        guard let combined = try AES.GCM.seal(compressed, using: key).combined else {
            throw SealingError.encryptionFailed
        }
        return combined
    }

    /// Nil when the key does not match, the bytes were altered, or the
    /// decompression fails. GCM authenticates, so a flipped bit is caught
    /// before anything reaches the decompressor.
    public static func open(_ sealed: Data, key: SymmetricKey?) -> Data? {
        let compressed: Data
        if let key {
            guard let box = try? AES.GCM.SealedBox(combined: sealed),
                  let opened = try? AES.GCM.open(box, using: key)
            else { return nil }
            compressed = opened
        } else {
            compressed = sealed
        }
        return try? (compressed as NSData).decompressed(using: .lzfse) as Data
    }
}
