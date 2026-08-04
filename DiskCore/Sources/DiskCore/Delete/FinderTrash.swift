import Foundation

/// Asks the Finder to trash what a plain rename could not.
///
/// Moving a directory needs write permission on the directory itself — its
/// `..` entry changes — so an application installed by another account fails
/// with EACCES however many rights *our* user has on `/Applications`. The
/// Finder handles that case by authenticating as an administrator, with the
/// same dialog a drag to the trash shows, and it also carries macOS's blessing
/// to touch other applications' bundles. Delegating to it turns "impossible"
/// into "asks for a password".
enum FinderTrash {

    /// Trashes each path, returning where it landed — index-aligned with the
    /// input, nil where the Finder failed or the user cancelled the dialog.
    static func delete(_ paths: [String]) -> [String?] {
        guard !paths.isEmpty else { return [] }

        let list = paths.map(quoted).joined(separator: ", ")
        // One script for the whole batch: the administrator dialog then shows
        // at most once, not once per item.
        let script = """
        set results to {}
        tell application "Finder"
            repeat with p in {\(list)}
                try
                    set end of results to POSIX path of ¬
                        ((delete (POSIX file (contents of p) as alias)) as alias)
                on error
                    set end of results to ""
                end try
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        results as text
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return paths.map { _ in nil }
        }
        // Read before waiting, or a chatty script deadlocks on a full pipe.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else { return paths.map { _ in nil } }
        return parse(output, count: paths.count)
    }

    /// One line per input path, empty meaning failure. Visible for testing.
    static func parse(_ output: String, count: Int) -> [String?] {
        var lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // osascript terminates its output with a newline of its own — always,
        // so it is dropped unconditionally, or a short batch whose last line
        // is a failure would be mistaken for a complete one.
        if lines.last == "" { lines.removeLast() }
        guard lines.count == count else { return Array(repeating: nil, count: count) }
        return lines.map { line in
            guard !line.isEmpty else { return nil }
            // `POSIX path of` a folder alias ends with a slash; our restore
            // compares and moves by plain paths.
            return line.hasSuffix("/") ? String(line.dropLast()) : line
        }
    }

    /// An AppleScript string literal for this path.
    private static func quoted(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
