import Foundation

/// A search needle, compiled once into the bytes a whole-tree sweep compares
/// against.
///
/// Two shapes and deliberately no more: `dmg` is a substring of the name,
/// `.dmg` or `*.dmg` is an extension. Anything richer is a query language, and a
/// query language is a feature nobody types twice.
public struct SearchQuery: Sendable, Hashable {

    public enum Kind: Sendable, Hashable {
        case substring
        case fileExtension
    }

    public let kind: Kind
    /// What the user typed, trimmed. Kept so the views can quote it back.
    public let text: String

    /// Lowercased UTF-8 needles. There is more than one only when the text
    /// carries accents: the same "é" is two different byte sequences depending
    /// on which normalisation created the file, and carrying both needles is far
    /// cheaper than normalising a million names to compare them.
    let needles: [[UInt8]]

    /// Returns nil for anything that would not narrow the tree — an empty
    /// string, whitespace, a bare `*.`. Callers read that as "no filter".
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var body = trimmed
        var kind = Kind.substring
        if body.hasPrefix("*.") {
            body = String(body.dropFirst(2))
            kind = .fileExtension
        } else if body.hasPrefix("."), body.count > 1 {
            body = String(body.dropFirst())
            kind = .fileExtension
        }
        guard !body.isEmpty else { return nil }

        self.kind = kind
        self.text = trimmed

        let lowered = body.lowercased()
        let composed = Array(lowered.precomposedStringWithCanonicalMapping.utf8)
        let decomposed = Array(lowered.decomposedStringWithCanonicalMapping.utf8)
        self.needles = composed == decomposed ? [composed] : [composed, decomposed]
    }

    // MARK: - Matching

    /// Case folding restricted to ASCII, on purpose.
    ///
    /// Names are UTF-8, and no byte of a multi-byte sequence can be mistaken for
    /// an ASCII letter, so folding A–Z byte by byte is safe on any name whatever
    /// it spells. It is also as far as we go: folding "É" onto "é" means
    /// decoding, and decoding means building a String per node — a million
    /// allocations to make a rare query slightly more forgiving. Accented
    /// queries still work, because the needle carries both normalisations; only
    /// an accented query typed in the wrong case misses.
    @inline(__always)
    static func folded(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte &+ 32 : byte
    }

    @inline(__always)
    func matches(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        switch kind {
        case .substring:
            for needle in needles where Self.contains(name, needle) { return true }
        case .fileExtension:
            for needle in needles where Self.hasExtension(name, needle) { return true }
        }
        return false
    }

    /// Naive search, and it stays naive: names average twenty bytes and needles
    /// three or four, well under the length where a skip table earns back the
    /// setup it costs.
    private static func contains(
        _ name: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]
    ) -> Bool {
        let n = name.count, m = needle.count
        guard m > 0, n >= m else { return false }
        let first = needle[0]
        var i = 0
        while i <= n - m {
            if folded(name[i]) == first {
                var j = 1
                while j < m, folded(name[i + j]) == needle[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }

    /// True when the name ends in `.needle`.
    ///
    /// The dot has to be *inside* the name rather than starting it: `.dmg` is a
    /// hidden file called dmg, and `NSString.pathExtension` — the only other
    /// place in the app that derives an extension — agrees it has none.
    private static func hasExtension(
        _ name: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]
    ) -> Bool {
        let dot = name.count - needle.count - 1
        guard dot > 0, name[dot] == UInt8(ascii: ".") else { return false }
        var j = 0
        while j < needle.count, folded(name[dot + 1 + j]) == needle[j] { j += 1 }
        return j == needle.count
    }
}
