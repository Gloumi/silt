import DiskCore
import Darwin
import Foundation

// Debug harness for the scan engine. Exists so the engine can be validated and
// benchmarked long before any UI exists — if the numbers here are wrong or slow,
// nothing built on top can save it.

struct Arguments {
    var path = "."
    var depth = 2
    var logical = false
    var noCollapse = false
    var quiet = false
    var workers: Int?
    var junk = false
    /// Dry run of the uninstaller for one `.app`. Never deletes anything.
    var uninstall: String?
}

func parseArguments() -> Arguments {
    var args = Arguments()
    var positional: [String] = []
    var i = 1
    let raw = CommandLine.arguments
    while i < raw.count {
        switch raw[i] {
        case "--depth", "-d":
            i += 1
            args.depth = i < raw.count ? Int(raw[i]) ?? 2 : 2
        case "--logical":
            args.logical = true
        case "--no-collapse":
            args.noCollapse = true
        case "--workers", "-w":
            i += 1
            args.workers = i < raw.count ? Int(raw[i]) : nil
        case "--junk":
            args.junk = true
        case "--uninstall":
            i += 1
            args.uninstall = i < raw.count ? raw[i] : nil
        case "--quiet", "-q":
            args.quiet = true
        case "--help", "-h":
            print("""
            usage: diskscan [path] [options]

              -d, --depth N   tree depth to print (default 2)
                  --logical   report logical sizes instead of on-disk
                  --no-collapse
                              give node_modules/.git/bundles individual nodes
              -q, --quiet     totals only
                  --junk      list recoverable space
                  --uninstall PATH.app
                              dry run: what removing that app would take with
                              it. Prints only, never deletes.
            """)
            exit(0)
        default:
            positional.append(raw[i])
        }
        i += 1
    }
    if let first = positional.first { args.path = first }
    return args
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit == 0
        ? "\(bytes) B"
        : String(format: "%.1f %@", value, units[unit])
}

let arguments = parseArguments()

// Dry run, before any scanning: the uninstaller works off the filesystem by
// name, not off a scanned tree.
if let target = arguments.uninstall {
    guard let app = AppUninstaller.inspect(appPath: target) else {
        print("« \(target) » n'est pas une application lisible.")
        exit(1)
    }
    print("\(app.name) — \(app.bundleID ?? "sans identifiant")")
    print("  \(formatBytes(app.bytes).padding(toLength: 10, withPad: " ", startingAt: 0))\(app.path)")

    let leftovers = AppUninstaller.leftovers(for: app)
    var total = app.bytes
    for confidence in LeftoverConfidence.allCases {
        let group = leftovers.filter { $0.confidence == confidence }
        guard !group.isEmpty else { continue }
        let sum = group.reduce(Int64(0)) { $0 + $1.bytes }
        print("\n\(confidence.cliLabel) — \(formatBytes(sum)) sur \(group.count) élément(s)")
        for item in group {
            let size = formatBytes(item.bytes)
                .padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(size)\(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        }
        // Only the first tier is ticked by default in the app.
        if confidence == .certain { total += sum }
    }
    print("\nCoché par défaut : \(formatBytes(total)). Rien n'a été supprimé.")
    exit(0)
}

extension LeftoverConfidence {
    var cliLabel: String {
        switch self {
        case .certain: "CERTAIN (coché par défaut)"
        case .probable: "PROBABLE (décoché)"
        case .possible: "À VÉRIFIER (décoché)"
        }
    }
}

var options = ScanOptions()
if let workers = arguments.workers { options.workerCount = max(1, workers) }
if arguments.noCollapse {
    options.collapsedDirectoryNames = []
    options.descendIntoPackages = true
}

let startedAt = Date()
let result = await ScanEngine.scan(root: arguments.path, options: options) { progress in
    guard !arguments.quiet, !progress.isFinished else { return }
    let line = "  \(progress.filesSeen) files, \(formatBytes(progress.bytesSeen))"
    FileHandle.standardError.write(Data("\r\(line)\u{1B}[K".utf8))
}
if !arguments.quiet { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

guard !result.store.isEmpty else {
    print("could not scan \(arguments.path)")
    exit(1)
}

let store = result.store
let sizes = arguments.logical ? store.totalLogical : store.totalAlloc

func printTree(_ node: Int32, depth: Int, prefix: String) {
    guard depth <= arguments.depth else { return }
    let children = store.childrenSortedBySize(of: node, useLogical: arguments.logical)
    for (offset, child) in children.enumerated() {
        let isLast = offset == children.count - 1
        let size = sizes[Int(child)]
        if size == 0 && depth > 0 { continue }
        let marker = isLast ? "└─ " : "├─ "
        let flags = store.flags[Int(child)]
        var tags: [String] = []
        if flags.contains(.notDescended) { tags.append("collapsed") }
        if flags.contains(.unreadable) { tags.append("unreadable") }
        if flags.contains(.hardlinkDuplicate) { tags.append("hardlink") }
        let suffix = tags.isEmpty ? "" : "  (\(tags.joined(separator: ", ")))"
        let name = store.name(of: child)
            + (store.isDirectory(child) ? "/" : "")
        print("\(prefix)\(marker)\(formatBytes(size).padded(to: 10))  \(name)\(suffix)")
        if store.isDirectory(child) {
            printTree(child, depth: depth + 1, prefix: prefix + (isLast ? "   " : "│  "))
        }
    }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

print("\(formatBytes(sizes[0]))  \(store.name(of: 0))")
if !arguments.quiet { printTree(0, depth: 1, prefix: "") }

if arguments.junk {
    let t0 = Date()
    let report = JunkScanner.scan(store: store)
    let ms = Date().timeIntervalSince(t0) * 1000
    print("")
    for category in report.populatedCategories {
        let items = report.findings(in: category.id)
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        print("\(category.title) — \(formatBytes(total))")
        for item in items.prefix(6) {
            let mark = item.safety == .safe ? " " : "!"
            let short = item.path.replacingOccurrences(
                of: NSHomeDirectory(), with: "~"
            )
            print("  \(mark) \(formatBytes(item.bytes).padded(to: 9))  \(short)")
        }
        if items.count > 6 { print("    … et \(items.count - 6) autres") }
    }
    print("")
    print("TOTAL récupérable : \(formatBytes(report.totalBytes)) " +
          "sur \(report.findings.count) éléments " +
          "(analyse des règles : \(String(format: "%.0f", ms)) ms)")
    exit(0)
}

// Layout cost, measured separately from the scan: the UI rebuilds this every
// time you drill into a folder, so it has to stay in the low milliseconds.
do {
    var samples: [Double] = []
    var arcCount = 0
    for _ in 0..<5 {
        let t0 = Date()
        let arcs = SunburstLayout.build(
            store: store, root: 0, useLogicalSize: arguments.logical
        )
        samples.append(Date().timeIntervalSince(t0) * 1000)
        arcCount = arcs.count
    }
    let best = samples.min() ?? 0
    print(String(format: "sunburst layout: %d arcs, %.1f ms (best of 5)", arcCount, best))
}

let elapsed = Date().timeIntervalSince(startedAt)
let rate = elapsed > 0 ? Double(result.filesSeen) / elapsed : 0
print("""

\(result.filesSeen) files, \(result.directoriesSeen) directories, \
\(store.count) nodes in \(String(format: "%.2f", elapsed))s \
(\(String(format: "%.0f", rate))/s, \(String(format: "%.0f", rate * 60 / 1_000_000))M/min)
""")
if !result.unreadablePaths.isEmpty {
    let first = result.unreadablePaths[0]
    print("\(result.unreadablePaths.count) unreadable directories (first: \(first))")
}
