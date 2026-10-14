import Foundation

/// A release number as the tags spell it: "v0.10.0", "0.10.0", "1.2".
///
/// Compared component by component, numerically. As strings, "0.10.0" sorts
/// before "0.9.2" — which is how an update checker ends up telling people to
/// downgrade. Anything with letters past the optional leading "v" is refused
/// rather than guessed at: a pre-release tag is not an update to offer.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {

    /// Trailing zeros dropped, so that 1.2 and 1.2.0 — the same release —
    /// compare and hash alike.
    private let components: [Int]
    public let description: String

    public init?(_ string: String) {
        var text = Substring(string)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: Int() would take "+1", and Character.isNumber
            // takes "٢".
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        guard !numbers.isEmpty else { return nil }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        components = numbers
        description = String(text)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
