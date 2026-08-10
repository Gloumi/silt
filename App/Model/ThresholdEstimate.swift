import DiskCore
import Foundation
import Observation

/// What a duplicates threshold would actually cost, measured on demand.
///
/// The Settings window is a Scene of its own with no access to whatever scan is
/// loaded, so this walks the home folder itself. It is far cheaper than a scan
/// — sizes and nothing else, no tree, no names, no paths kept — and the result
/// is a histogram rather than a count, so once it has run *every* position of
/// the slider is answered instantly instead of only the one it was measured at.
///
/// Nothing is persisted yet. When it is, the histogram is the thing to keep:
/// it is small, it survives a threshold change, and it is exactly what turns
/// this button into a figure that is simply there.
@MainActor
@Observable
final class ThresholdEstimate {
    static let shared = ThresholdEstimate()

    enum Phase: Equatable {
        case idle
        /// Files walked so far.
        case running(Int)
        case ready
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var census: SizeCensus.Result?
    private var task: Task<Void, Never>?

    private init() {}

    /// Where it measures, and what the label has to say out loud: an estimate
    /// of the whole home folder is not a promise about the folder the user will
    /// actually point the duplicates view at.
    var root: String { NSHomeDirectory() }

    func measure() {
        task?.cancel()
        phase = .running(0)
        let root = root
        let options = Preferences.shared.scanOptions()

        // Progress arrives from the walking thread; only the run still on
        // screen may move the counter.
        let onProgress: @Sendable (Int) -> Void = { [weak self] seen in
            Task { @MainActor in
                guard let self, case .running = self.phase else { return }
                self.phase = .running(seen)
            }
        }

        task = Task { [weak self] in
            let measured = await Task.detached(priority: .utility) {
                SizeCensus.measure(
                    root: root, options: options, onProgress: onProgress
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            census = measured
            phase = measured == nil ? .failed : .ready
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        // A cancelled walk saw only part of the disk, and half a census would
        // understate every threshold — which is the direction that misleads.
        phase = census == nil ? .idle : .ready
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Files that would be compared at this threshold, or nil before any walk.
    func candidates(above threshold: Int64) -> Int? {
        census?.candidates(above: threshold)
    }

    /// Bytes the first pass would read for them.
    func bytesToRead(above threshold: Int64) -> Int64? {
        census.map {
            $0.bytesToRead(
                above: threshold,
                prefixLength: DuplicateFinder.Options().prefixLength
            )
        }
    }
}
