import Foundation

/// Removes local Time Machine snapshots, with the administrator password.
///
/// Nothing here goes through `SafeDeleter`: a snapshot is not a file and has no
/// trash to be moved to. `tmutil` is the only tool that removes one, it wants
/// root, and the whole operation is irreversible — which is why the caller must
/// confirm it with a sheet that says so, rather than the usual one.
///
/// The elevation is delegated to AppleScript's `do shell script … with
/// administrator privileges`, the same "let macOS ask" reflex as `FinderTrash`:
/// the system draws the password dialog, we never see the password, and one
/// script for the whole batch means one dialog rather than one per snapshot.
public enum SnapshotDeleter {

    public struct Outcome: Sendable {
        public enum Status: Sendable, Equatable {
            /// Everything asked for went through.
            case done
            /// Some snapshots resisted; `failed` names them.
            case partial
            /// Nothing was removed.
            case failed
            /// The password dialog was dismissed. Not an error to report.
            case cancelled
        }

        public var status: Status
        /// Stamps confirmed removed. Empty for the volume-wide operations,
        /// which report no per-snapshot result.
        public var deleted: [String]
        public var failed: [String]
        /// What the system said, when it said something worth passing on.
        public var message: String?

        public init(
            status: Status, deleted: [String] = [], failed: [String] = [],
            message: String? = nil
        ) {
            self.status = status
            self.deleted = deleted
            self.failed = failed
            self.message = message
        }
    }

    /// Deletes the snapshots taken at these `YYYY-MM-DD-HHMMSS` stamps.
    ///
    /// `tmutil deletelocalsnapshots <date>` works by date across every mounted
    /// disk — it takes no volume — so a stamp shared by two volumes clears both.
    /// In practice snapshots are taken per volume at distinct seconds, and the
    /// alternative, deleting by mount point, cannot be narrowed to a selection.
    public static func delete(stamps: [String]) -> Outcome {
        guard !stamps.isEmpty else { return Outcome(status: .done) }
        // The gate that lets the rest of this function build a shell command by
        // concatenation: a stamp is four groups of digits or it never gets here.
        let valid = stamps.filter(APFSSnapshots.isValidStamp)
        guard valid.count == stamps.count else {
            return Outcome(
                status: .failed, failed: stamps,
                message: "Date de snapshot invalide."
            )
        }

        // Each line reports its own verdict, so one snapshot that refuses to go
        // does not hide the ones that did — `;` rather than `&&` for the same
        // reason.
        let commands = valid.map { stamp in
            "/usr/bin/tmutil deletelocalsnapshots \(stamp) >/dev/null 2>&1"
                + " && echo 'OK \(stamp)' || echo 'KO \(stamp)'"
        }
        let shell = commands.joined(separator: "; ")

        switch runElevated(command: literal(shell)) {
        case .cancelled:
            return Outcome(status: .cancelled)
        case .launchFailed(let message):
            return Outcome(status: .failed, failed: valid, message: message)
        case .ran(let output):
            let (deleted, failed) = parse(output, expected: valid)
            let status: Outcome.Status =
                failed.isEmpty ? .done : (deleted.isEmpty ? .failed : .partial)
            return Outcome(status: status, deleted: deleted, failed: failed)
        }
    }

    /// Deletes every local Time Machine snapshot of one volume.
    public static func deleteAll(mountPoint: String) -> Outcome {
        elevated(command:
            literal("/usr/bin/tmutil deletelocalsnapshots ")
                + " & " + argument(mountPoint)
        )
    }

    /// The amounts worth offering for a thinning, largest last, at most three.
    ///
    /// Bounded by what the volume is actually holding back: offering to free
    /// 50 GB on a disk reserving 5 GB is a promise `tmutil` cannot keep, and
    /// the caller has no way to tell afterwards that it was never possible.
    /// Under a gigabyte held back, nothing is worth offering at all.
    public static func thinningTargets(upTo bytes: Int64) -> [Int64] {
        let steps: [Int64] = [1, 2, 5, 10, 20, 50, 100, 200, 500]
            .map { $0 * 1_000_000_000 }
        return Array(steps.filter { $0 <= bytes }.suffix(3))
    }

    /// Asks Time Machine to reclaim `bytes` by thinning its oldest snapshots —
    /// the same call macOS makes on itself when a disk fills up. Urgency 4 is
    /// the most insistent level, the one that actually frees space now.
    public static func thin(mountPoint: String, bytes: Int64) -> Outcome {
        guard bytes > 0 else { return Outcome(status: .done) }
        return elevated(command:
            literal("/usr/bin/tmutil thinlocalsnapshots ")
                + " & " + argument(mountPoint)
                + " & " + literal(" \(bytes) 4")
        )
    }

    // MARK: - Running

    private static func elevated(command: String) -> Outcome {
        switch runElevated(command: command) {
        case .cancelled:
            return Outcome(status: .cancelled)
        case .launchFailed(let message):
            return Outcome(status: .failed, message: message)
        case .ran:
            return Outcome(status: .done)
        }
    }

    private enum ElevatedResult {
        case ran(String)
        case cancelled
        case launchFailed(String?)
    }

    /// One `osascript` run, one password dialog, whatever the batch size.
    ///
    /// `command` is an AppleScript *expression* evaluating to the shell line —
    /// built from `literal` and `argument` so that the two levels of quoting,
    /// AppleScript's and the shell's, are each applied exactly once.
    private static func runElevated(command: String) -> ElevatedResult {
        let script = "do shell script \(command) with administrator privileges"
        guard let result = Subprocess.run(
            "/usr/bin/osascript", ["-e", script]
        ) else {
            return .launchFailed("Impossible de lancer osascript.")
        }
        if result.status != 0 {
            // -128 is AppleScript's "the user cancelled", which the password
            // dialog raises on Cancel. Reporting it as a failure would put an
            // alarming banner in front of someone who simply changed their mind.
            if isCancellation(result.errorOutput) { return .cancelled }
            return .launchFailed(reason(from: result.errorOutput))
        }
        return .ran(String(data: result.output, encoding: .utf8) ?? "")
    }

    // MARK: - Parsing

    /// Splits the per-stamp verdicts. Visible for testing.
    ///
    /// A stamp the script never reported on counts as failed: silence is not
    /// success, and the one thing this must never do is claim space was freed
    /// when it was not.
    static func parse(
        _ output: String, expected: [String]
    ) -> (deleted: [String], failed: [String]) {
        var succeeded: Set<String> = []
        for line in output.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("OK ") else { continue }
            succeeded.insert(String(line.dropFirst(3)))
        }
        return (
            expected.filter { succeeded.contains($0) },
            expected.filter { !succeeded.contains($0) }
        )
    }

    static func isCancellation(_ errorOutput: String) -> Bool {
        errorOutput.contains("-128") || errorOutput.contains("User canceled")
    }

    /// The last line of osascript's complaint, without its file:line prefix —
    /// enough to show, short enough for a banner.
    static func reason(from errorOutput: String) -> String? {
        let line = errorOutput
            .split(separator: "\n")
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line, !line.isEmpty else { return nil }
        // "/dev/fd/0:123:145: execution error: …" — keep what follows.
        if let range = line.range(of: "execution error: ") {
            return String(line[range.upperBound...])
        }
        return line
    }

    // MARK: - Building the script

    /// An AppleScript string literal. Same escaping as `FinderTrash.quoted`.
    /// Visible for testing.
    static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// A path, safe to hand to `/bin/sh`: escaped once for AppleScript, then
    /// quoted for the shell by AppleScript itself. Visible for testing.
    static func argument(_ path: String) -> String {
        "quoted form of \(literal(path))"
    }
}
