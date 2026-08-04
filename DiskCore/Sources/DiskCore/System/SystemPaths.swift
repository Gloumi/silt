import Darwin
import Foundation

/// Per-user working directories macOS manages under /private/var/folders.
///
/// They sit behind two levels of per-user hash, so no static list can name
/// them — `confstr(3)` is the only way in. `static let` gives a thread-safe
/// one-time init, which matters because `DenyList` consults these off the
/// main actor, from inside `SafeDeleter`.
public enum SystemPaths {

    /// `/private/var/folders/xx/…/C` — caches macOS purges at boot; their
    /// contents are regenerable by contract. Nil only if confstr fails,
    /// which on a healthy system it does not.
    public static let darwinUserCache: String? = path(for: _CS_DARWIN_USER_CACHE_DIR)

    /// `/private/var/folders/xx/…/T` — temporary items, possibly in live
    /// use by running applications.
    public static let darwinUserTemp: String? = path(for: _CS_DARWIN_USER_TEMP_DIR)

    private static func path(for name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) == length else { return nil }
        let utf8 = buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:))
        return canonical(String(decoding: utf8, as: UTF8.self))
    }

    /// Strips the trailing slash confstr appends and rewrites `/var` to
    /// `/private/var` — the deny list and the scanned tree both use the
    /// `/private` spelling. Internal so tests can exercise it directly.
    static func canonical(_ raw: String) -> String {
        var path = raw
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        return path
    }
}
