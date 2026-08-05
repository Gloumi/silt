import AppKit
import DiskCore
import Foundation
import Observation
import SwiftUI

/// The inventory behind the "Applications" tool: everything installed, what it
/// weighs, and when it was last opened.
///
/// Deliberately separate from `ScanModel`, like `RebootModel`: none of this
/// comes from a scanned tree, and the list must survive every reset of the scan
/// lifecycle — the whole point is that it works before any volume is read.
@MainActor
@Observable
final class AppsModel {

    struct Item: Identifiable {
        let installed: InstalledApps.Installed
        /// Bytes held outside the bundle, counting only what carries the
        /// bundle identifier. Nil while the second pass is still running —
        /// which is not the same as zero, and the row says so.
        var leftoverBytes: Int64?
        var isRunning: Bool

        var app: AppBundle { installed.app }
        var total: Int64 { app.bytes + (leftoverBytes ?? 0) }
        var id: String { app.path }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size, name, lastUsed
        var id: String { rawValue }

        var label: String {
            switch self {
            case .size: "Taille"
            case .name: "Nom"
            case .lastUsed: "Utilisation"
            }
        }
    }

    enum Phase { case idle, listing, ready }

    private(set) var phase: Phase = .idle
    private(set) var items: [Item] = []
    /// The second pass is still filling in the leftovers column.
    private(set) var isMeasuringLeftovers = false

    var sort: Sort = .size {
        didSet { if sort != oldValue { applySort() } }
    }

    /// The inspected application, by path. A path rather than an index: the
    /// list is re-sorted under it, and re-listed after every deletion.
    var selection: String?

    var selectedItem: Item? {
        selection.flatMap { path in items.first { $0.id == path } }
    }

    private var task: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.total } }

    /// First display: take the inventory once, silently.
    func loadIfNeeded() {
        if case .idle = phase { refresh() }
    }

    /// The whole inventory: every bundle measured, every library folder swept.
    /// Seconds of work, so it stays behind an explicit gesture — first display,
    /// or the refresh button.
    func refresh() {
        task?.cancel()
        // Keep the previous list on screen during a refresh; only the very
        // first inventory has nothing better to show than a spinner.
        if items.isEmpty { phase = .listing }

        task = Task { [weak self] in
            guard let self else { return }
            let listed = await Task.detached { await InstalledApps.list() }.value
            guard !Task.isCancelled else { return }

            items = listed.map {
                Item(
                    installed: $0, leftoverBytes: nil,
                    isRunning: RunningApps.isRunning(bundleID: $0.app.bundleID)
                )
            }
            if let selection, !items.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
            applySort()
            phase = .ready

            await measureLeftovers(for: items.map(\.installed.app))
        }
    }

    /// After a deletion or an undo: notice which bundles came or went, and
    /// measure only those.
    ///
    /// Re-taking the inventory would be correct and wasteful — several seconds
    /// of walking, and a second sweep of every library folder, to learn that
    /// one application out of sixty is gone. Listing the directories costs
    /// three `readdir`s.
    func reconcile() {
        guard case .ready = phase else { return }
        task?.cancel()

        task = Task { [weak self] in
            guard let self else { return }
            let paths = await Task.detached {
                Set(InstalledApps.bundlePaths())
            }.value
            guard !Task.isCancelled else { return }

            items.removeAll { !paths.contains($0.id) }
            // The uninstalled application was very probably the inspected one.
            if let selection, !paths.contains(selection) { self.selection = nil }
            let fresh = paths.subtracting(items.map(\.id))
            guard !fresh.isEmpty else { applySort(); return }

            // An undo puts a bundle back, and someone may have installed
            // something while the view was open.
            let measured = await Task.detached {
                fresh.sorted().compactMap(InstalledApps.measure)
            }.value
            guard !Task.isCancelled else { return }
            items.append(contentsOf: measured.map {
                Item(
                    installed: $0, leftoverBytes: nil,
                    isRunning: RunningApps.isRunning(bundleID: $0.app.bundleID)
                )
            })
            applySort()

            await measureLeftovers(for: measured.map(\.app))
        }
    }

    /// The second pass. Long — it lists sixteen library folders and walks every
    /// match — so the list is already on screen and fills in underneath.
    private func measureLeftovers(for apps: [AppBundle]) async {
        guard !apps.isEmpty else { return }
        isMeasuringLeftovers = true
        defer { isMeasuringLeftovers = false }

        let stream = AsyncStream<(String, Int64)> { continuation in
            let work = Task.detached {
                _ = InstalledApps.leftoverBytes(for: apps) { path, bytes in
                    continuation.yield((path, bytes))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }

        // Looked up rather than indexed: sixty-odd rows make the search free,
        // and a cached position would be wrong the moment a row is dropped.
        for await (path, bytes) in stream {
            if Task.isCancelled { return }
            guard let position = items.firstIndex(where: { $0.id == path })
            else { continue }
            items[position].leftoverBytes = bytes
        }
        guard !Task.isCancelled else { return }
        // Sorted once, at the end. Re-sorting on every total that lands would
        // make the list dance under the pointer.
        withAnimation { applySort() }
    }

    private func applySort() {
        var index: [String: Int] = [:]
        for (position, item) in items.enumerated() { index[item.id] = position }
        switch sort {
        case .size:
            items.sort { $0.total > $1.total }
        case .name:
            items.sort {
                $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending
            }
        case .lastUsed:
            // Most recently used first, and everything Spotlight knows nothing
            // about grouped at the end rather than pretending to be ancient.
            items.sort {
                switch ($0.installed.lastUsed, $1.installed.lastUsed) {
                case let (a?, b?): a > b
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil):
                    $0.app.name.localizedStandardCompare($1.app.name)
                        == .orderedAscending
                }
            }
        }
    }

    /// The real application icon, cached by path. `IconCache` cannot serve
    /// here: it keys on the extension, so every `.app` would share one generic
    /// icon — which is precisely the thing this list is made of.
    func icon(for path: String) -> NSImage {
        if let known = icons[path] { return known }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }

    /// Silt cannot trash itself while it is running: the process would keep its
    /// own bundle open and come back half-alive.
    func isSelf(_ item: Item) -> Bool {
        item.app.path == Bundle.main.bundlePath
    }
}
