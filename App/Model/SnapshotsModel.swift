import DiskCore
import Foundation
import Observation

/// The APFS snapshots each mounted volume carries, and what removing them
/// actually gives back.
///
/// Deliberately separate from `ScanModel`, like `RebootModel`: snapshots are
/// invisible to any walk of the directory tree — that is the whole point of
/// them — so the measurement owes nothing to the scan lifecycle.
@MainActor
@Observable
final class SnapshotsModel {

    struct VolumeSnapshots: Identifiable, Sendable {
        let mountPoint: String
        let name: String
        /// Newest first.
        let snapshots: [APFSSnapshot]
        /// The volume's purgeable gap when the list was taken. Exact, unlike
        /// any per-snapshot figure could be.
        let purgeableBytes: Int64

        var id: String { mountPoint }
        var deletable: [APFSSnapshot] { snapshots.filter(\.isDeletable) }

        /// Snapshots APFS says it could actually reclaim. An installer snapshot
        /// reports false, and that is the whole difference between "this volume
        /// holds purgeable space" and "these snapshots hold it" — conflating
        /// the two is the exact confusion this tool exists to end.
        var hasPurgeableSnapshots: Bool { snapshots.contains(where: \.isPurgeable) }

        var hasSystemSnapshot: Bool { snapshots.contains { $0.kind == .system } }

        /// How far back the local history goes — the one figure that is
        /// genuinely a property of the snapshots themselves, since their size
        /// is not one macOS publishes.
        var oldestDate: Date? { snapshots.compactMap(\.date).min() }

        /// Where Time Machine's snapshots actually sit on this disk — the Data
        /// volume, on any bootable one. The volume-wide `tmutil` verbs take a
        /// mount point and would find nothing at the one the sidebar shows.
        var timeMachineMountPoint: String {
            deletable.first?.mountPoint ?? mountPoint
        }

        /// A volume with nothing to show and nothing to explain. A mounted disk
        /// image would otherwise take a section to say it has no snapshots.
        var isWorthShowing: Bool {
            !snapshots.isEmpty || purgeableBytes >= 1_000_000_000
        }
    }

    /// A pending operation, waiting on the confirmation sheet.
    struct Request: Identifiable {
        enum Kind {
            /// The ticked snapshots.
            case selection
            /// Every Time Machine snapshot of the volume.
            case wholeVolume
            /// Let Time Machine choose, oldest first, until it has freed this
            /// many bytes.
            case thin(Int64)
        }

        let id = UUID()
        let kind: Kind
        let mountPoint: String
        let volumeName: String
        /// What will go. Empty for `.thin`, where Time Machine decides.
        let snapshots: [APFSSnapshot]
    }

    enum Phase { case idle, listing, ready }

    private(set) var phase: Phase = .idle
    private(set) var volumes: [VolumeSnapshots] = []
    /// Ticked snapshots, by UUID — a UUID survives a re-listing, an index
    /// would not.
    var selection: Set<String> = []
    /// Set while the password dialog is up and `tmutil` runs, so the view can
    /// stop offering the same button twice.
    private(set) var isWorking = false
    var request: Request?

    private var task: Task<Void, Never>?

    var isListing: Bool {
        if case .listing = phase { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var totalCount: Int { volumes.reduce(0) { $0 + $1.snapshots.count } }
    var deletableCount: Int { volumes.reduce(0) { $0 + $1.deletable.count } }
    var purgeableBytes: Int64 { volumes.reduce(0) { $0 + $1.purgeableBytes } }

    /// Whether any listed snapshot could account for the purgeable space. When
    /// this is false — a Mac carrying only an installer snapshot, which is the
    /// common case — the figure is real but belongs to caches, the trash or
    /// Spotlight, and this tool must say so rather than take the credit.
    var snapshotsExplainPurgeable: Bool {
        volumes.contains(where: \.hasPurgeableSnapshots)
    }

    var selectedSnapshots: [APFSSnapshot] {
        volumes.flatMap(\.snapshots).filter { selection.contains($0.uuid) }
    }

    /// Volumes on which there is something to thin.
    var thinnable: [VolumeSnapshots] { volumes.filter { !$0.deletable.isEmpty } }

    // MARK: - Listing

    /// First display: list once, silently.
    func loadIfNeeded() { if case .idle = phase { refresh() } }

    /// The refresh button, and every deletion.
    func refresh() {
        task?.cancel()
        // Keep the previous list on screen during a re-listing; only the very
        // first run has nothing better to show than a spinner.
        if volumes.isEmpty { phase = .listing }
        let mounted = Volumes.mounted()
        task = Task { [weak self] in
            let listed = await Task.detached { Self.list(mounted) }.value
            guard let self, !Task.isCancelled else { return }
            volumes = listed
            phase = .ready
            selection = selection.intersection(
                listed.flatMap(\.snapshots).map(\.uuid)
            )
        }
    }

    private nonisolated static func list(
        _ mounted: [VolumeInfo]
    ) -> [VolumeSnapshots] {
        mounted.compactMap { volume in
            let mountPoint = volume.url.path
            // Non-APFS volumes have no snapshots by construction, and listing
            // them would cost a subprocess to be told so.
            guard APFSSnapshots.isAPFS(mountPoint: mountPoint) else { return nil }
            return VolumeSnapshots(
                mountPoint: mountPoint,
                name: volume.name,
                snapshots: APFSSnapshots.list(mountPoint: mountPoint),
                purgeableBytes: volume.purgeableBytes
            )
        }
        .filter(\.isWorthShowing)
    }

    // MARK: - Selection

    func toggle(_ snapshot: APFSSnapshot) {
        guard snapshot.isDeletable else { return }
        if selection.contains(snapshot.uuid) {
            selection.remove(snapshot.uuid)
        } else {
            selection.insert(snapshot.uuid)
        }
    }

    func selectAll(in volume: VolumeSnapshots) {
        selection.formUnion(volume.deletable.map(\.uuid))
    }

    // MARK: - Asking

    /// Builds the request the confirmation sheet will show. Nothing is removed
    /// until `confirm` runs.
    func requestSelectionDeletion() {
        let snapshots = selectedSnapshots
        // `tmutil` deletes by date across every mounted disk, so a selection
        // spanning two volumes still goes through in one pass. Only the volume
        // named here is re-measured afterwards — the first one holding a ticked
        // snapshot — which is the common case of a single internal disk.
        guard let volume = volumes.first(where: { candidate in
            candidate.snapshots.contains { selection.contains($0.uuid) }
        }), !snapshots.isEmpty else { return }
        request = Request(
            kind: .selection, mountPoint: volume.mountPoint,
            volumeName: volume.name, snapshots: snapshots
        )
    }

    func requestWholeVolume(_ volume: VolumeSnapshots) {
        guard !volume.deletable.isEmpty else { return }
        request = Request(
            kind: .wholeVolume, mountPoint: volume.timeMachineMountPoint,
            volumeName: volume.name, snapshots: volume.deletable
        )
    }

    func requestThin(_ volume: VolumeSnapshots, bytes: Int64) {
        guard !volume.deletable.isEmpty else { return }
        request = Request(
            kind: .thin(bytes), mountPoint: volume.timeMachineMountPoint,
            volumeName: volume.name, snapshots: []
        )
    }

    // MARK: - Doing

    /// Runs the pending request, then reports what it really freed.
    ///
    /// `reporting` is the model that owns the banner: snapshot deletion has no
    /// undo to offer, so it goes through a path that never sets one.
    func confirm(reporting scan: ScanModel) async {
        guard let request, !isWorking else { return }
        self.request = nil
        isWorking = true
        defer { isWorking = false }

        let before = Volumes.info(at: request.mountPoint)?.availableBytes ?? 0
        let mountPoint = request.mountPoint
        let kind = request.kind
        let stamps = request.snapshots.compactMap(\.stamp)

        let outcome = await Task.detached {
            switch kind {
            case .selection, .wholeVolume:
                // Even "whole volume" goes stamp by stamp: it reports which
                // ones went, and `tmutil deletelocalsnapshots <mount point>`
                // reports nothing at all.
                return SnapshotDeleter.delete(stamps: stamps)
            case .thin(let bytes):
                return SnapshotDeleter.thin(mountPoint: mountPoint, bytes: bytes)
            }
        }.value

        guard outcome.status != .cancelled else { return }

        let freed = await measureFreed(at: mountPoint, before: before)
        scan.reportSnapshotOutcome(
            message(for: outcome, kind: kind, freed: freed)
        )
        selection.subtract(outcome.deleted.compactMap { stamp in
            volumes.flatMap(\.snapshots).first { $0.stamp == stamp }?.uuid
        })
        refresh()
    }

    /// What the volume actually gave back.
    ///
    /// Polled rather than read once: APFS releases a snapshot's blocks on its
    /// own schedule, and reading the capacity the instant `tmutil` returns
    /// reliably answers zero — which would look like a deletion that failed.
    private func measureFreed(at mountPoint: String, before: Int64) async -> Int64 {
        var best: Int64 = 0
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(700))
            guard let now = Volumes.info(at: mountPoint)?.availableBytes else { break }
            best = max(best, now - before)
        }
        return max(0, best)
    }

    private func message(
        for outcome: SnapshotDeleter.Outcome,
        kind: Request.Kind, freed: Int64
    ) -> String {
        // Only claim a figure when there is one to claim: "0 octet libéré"
        // after a deletion that worked is worse than saying nothing.
        let gained = freed > 0 ? " — \(Format.bytes(freed)) libérés." : "."

        if case .thin = kind {
            switch outcome.status {
            case .done:
                return "Time Machine a allégé ses snapshots\(gained)"
            case .cancelled:
                return ""
            case .partial, .failed:
                return "Time Machine n'a pas pu alléger ses snapshots."
                    + (outcome.message.map { " \($0)" } ?? "")
            }
        }

        switch outcome.status {
        case .done:
            let count = outcome.deleted.count
            return "\(count) snapshot(s) supprimé(s)\(gained)"
        case .partial:
            return "\(outcome.deleted.count) snapshot(s) supprimé(s)\(gained) "
                + "\(outcome.failed.count) ont résisté."
        case .failed:
            return "Aucun snapshot supprimé."
                + (outcome.message.map { " \($0)" } ?? "")
        case .cancelled:
            return ""
        }
    }
}
