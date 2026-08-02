import OSLog

/// Instrumentation for the work that happens between "the scan is done" and
/// "the picture is on screen".
///
/// There was none, which is how a full-tree rule scan ended up running on the
/// main actor at exactly the wrong moment without anyone noticing. Intervals
/// show up in Instruments under the "Silt" subsystem, and the signpost calls
/// compile down to nothing when no tool is attached.
enum Signposts {
    static let log = OSLog(subsystem: "app.silt.mac", category: .pointsOfInterest)

    /// Wraps a synchronous block in a signpost interval and returns its value.
    static func measure<T>(_ name: StaticString, _ body: () -> T) -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return body()
    }
}
