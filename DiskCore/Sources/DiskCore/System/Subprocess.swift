import Foundation

/// Runs a system binary and collects what it said.
///
/// Deliberately blocking and `nonisolated`, like `FinderTrash`: callers decide
/// where the wait happens, and every one of them is already inside a detached
/// task.
enum Subprocess {

    struct Result {
        var status: Int32
        var output: Data
        var errorOutput: String
    }

    /// Nil only when the binary could not be launched at all. A command that
    /// ran and failed comes back with its status, so callers can tell "absent"
    /// from "refused".
    static func run(_ executable: String, _ arguments: [String]) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting, or a chatty command deadlocks on a full pipe.
        // Both pipes, for the same reason: a command that says nothing on
        // stdout can still fill stderr and hang there.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: output,
            errorOutput: String(data: errorOutput, encoding: .utf8) ?? ""
        )
    }
}
