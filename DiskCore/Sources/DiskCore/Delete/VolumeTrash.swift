import Darwin
import Foundation

/// What was established about one volume's trash.
public struct VolumeTrash: Sendable, Equatable {

    /// Three verdicts, not two. "Read-only" is not a trash problem: nothing can
    /// be removed from such a volume at all, and offering an irreversible
    /// deletion there would ask the user to agree to something the kernel is
    /// going to refuse anyway.
    public enum Verdict: Sendable, Equatable {
        case usable
        case unusable
        case readOnly
    }

    public let mountPoint: String
    /// What a warning has to say out loud — "Backup", not "/Volumes/Backup".
    public let volumeName: String
    public let verdict: Verdict

    public init(mountPoint: String, volumeName: String, verdict: Verdict) {
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.verdict = verdict
    }
}

/// Whether a volume's trash actually works, established by trying it.
///
/// `FileManager.trashItem` reports success on a volume where it only made a
/// copy: the item lands in a trash and stays where it was, and nothing is
/// freed. Deleting on such a volume therefore has to become an outright
/// removal — but only once that has been *demonstrated*, never inferred.
///
/// The obvious inferences were measured and are all wrong:
///
/// - `access(W_OK)` on `<volume>/.Trashes` is refused by TCC even where the
///   trash works perfectly, exactly as reading `~/.Trash` is. It answers
///   "unusable" for a volume that is fine — the one false negative that would
///   turn a reversible deletion into an irreversible one.
/// - `f_fstypename` decides nothing. An exFAT stick can carry a working
///   `.Trashes`, and a volume the trash cannot serve can be any type at all.
/// - `MNT_ROOTFS` does not mean "the user's volume": `~` lives on
///   `/System/Volumes/Data`, and `/` itself is mounted read-only.
///
/// So the probe is a measurement: make an empty file on the volume, trash it,
/// and ask whether it left its place. That single gesture answers for TCC, the
/// filesystem driver, a full disk and the copy bug at once — before anything
/// the user named has moved. It writes that file in the folder the deletion is
/// about rather than at the volume root: which trash a file goes to is the
/// volume's business, but being allowed to create the file at all is the
/// folder's, and a volume root is routinely closed to us where its contents
/// are not — `/System/Volumes/Data` being the nearest example.
public enum VolumeTrashProbe {

    /// The `statfs` facts a verdict rests on, as a value rather than a call, so
    /// that every branch of `decide` can be exercised without a second disk to
    /// plug in.
    public struct Mount: Sendable, Equatable {
        public let point: String
        /// `f_fstypename`. Carried for diagnostics; it decides nothing.
        public let fileSystem: String
        public let isReadOnly: Bool
        public let isLocal: Bool

        public init(
            point: String, fileSystem: String,
            isReadOnly: Bool, isLocal: Bool
        ) {
            self.point = point
            self.fileSystem = fileSystem
            self.isReadOnly = isReadOnly
            self.isLocal = isLocal
        }
    }

    /// What a live probe of one volume found.
    public enum ProbeOutcome: Sendable, Equatable {
        /// A file we made went to the trash and left its place. It works.
        case trashed
        /// The trash did not take it — it was copied and the original stayed,
        /// or it was refused outright while the volume itself is writable.
        /// This is the failure the whole type exists to catch.
        case leftInPlace
        /// Nothing could be established, and so nothing may be concluded.
        case couldNotTest
    }

    /// Prefix of the file the probe writes. Hidden, and suffixed with a UUID so
    /// that two copies of the app cannot collide on the same volume.
    static let probePrefix = ".silt-trash-probe-"

    // MARK: - Facts

    /// The mount the path sits on, or nil when it cannot be read.
    public static func mount(of path: String) -> Mount? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Mount(
            point: string(from: info.f_mntonname),
            fileSystem: string(from: info.f_fstypename),
            isReadOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
            isLocal: info.f_flags & UInt32(MNT_LOCAL) != 0
        )
    }

    /// The mount holding the home folder — the volume whose trash is `~/.Trash`.
    public static func homeMountPoint() -> String? {
        mount(of: NSHomeDirectory())?.point
    }

    /// The name to show for a mount point: the volume's own, or its last path
    /// component when Foundation has nothing to say.
    public static func volumeName(of mountPoint: String) -> String {
        let url = URL(fileURLWithPath: mountPoint)
        if let name = try? url.resourceValues(forKeys: [.volumeNameKey])
            .volumeName, !name.isEmpty {
            return name
        }
        let last = (mountPoint as NSString).lastPathComponent
        return last.isEmpty ? mountPoint : last
    }

    // MARK: - Decision

    /// The verdict for one mount. Pure, and visible for testing.
    ///
    /// The order is the safety story. Only the third branch can reach
    /// `.unusable`, and only when the probe watched the original stay put:
    /// every other answer — including "could not tell" — keeps the deletion
    /// reversible. Not knowing authorises nothing.
    static func decide(
        mount: Mount,
        homeMountPoint: String?,
        probe: () -> ProbeOutcome
    ) -> VolumeTrash.Verdict {
        // The volume the home folder is on trashes into `~/.Trash`, one rename
        // away. No probe could tell us anything we do not already know, and
        // this is the branch that keeps us from ever writing a probe file onto
        // a system volume.
        if let homeMountPoint, mount.point == homeMountPoint { return .usable }
        if mount.isReadOnly { return .readOnly }

        switch probe() {
        case .trashed: return .usable
        case .leftInPlace: return .unusable
        case .couldNotTest: return .usable
        }
    }

    // MARK: - The live probe

    /// Trashes a file of our own from this folder and reports what happened.
    public static func probe(in directory: String) -> ProbeOutcome {
        let manager = FileManager()
        let probePath = (directory as NSString)
            .appendingPathComponent(probePrefix + UUID().uuidString.prefix(8))
        guard manager.createFile(atPath: probePath, contents: nil) else {
            return .couldNotTest
        }

        var landed: NSURL?
        do {
            try manager.trashItem(
                at: URL(fileURLWithPath: probePath), resultingItemURL: &landed
            )
        } catch {
            // Refused outright. That is only evidence about the *trash* if the
            // volume is otherwise writable by us — which removing the probe
            // answers. If even that fails, we know nothing, and leave behind a
            // hidden empty file rather than a wrong verdict.
            guard (try? manager.removeItem(atPath: probePath)) != nil else {
                return .couldNotTest
            }
            return .leftInPlace
        }

        // `lstat`, through the ledger's probe, rather than `fileExists`: its
        // third answer is the point. "Not allowed to look" must not read as
        // "still there", or a working volume would be condemned by TCC.
        switch TrashLedger.presence(of: probePath) {
        case .absent:
            discard(landed as URL?)
            return .trashed
        case .present:
            try? manager.removeItem(atPath: probePath)
            discard(landed as URL?)
            return .leftInPlace
        case .unknown:
            discard(landed as URL?)
            return .couldNotTest
        }
    }

    /// Clears the probe's own copy out of the trash. Best effort: TCC can deny
    /// it, and an empty hidden file left in the trash is a far smaller price
    /// than a verdict we did not measure.
    private static func discard(_ landed: URL?) {
        guard let landed,
              landed.lastPathComponent.hasPrefix(probePrefix)
        else { return }
        try? FileManager().removeItem(at: landed)
    }

    // MARK: - One answer per path, one probe per volume

    /// The verdict for each of these paths, probing each distinct volume once.
    ///
    /// `statfs` is a syscall with no I/O behind it, so asking it per path costs
    /// microseconds; the probe writes and reads, so it is memoised by mount
    /// point — the first path to reach a volume is the one whose folder gets
    /// the probe file. Blocking: call it off the main actor.
    public static func survey(paths: [String]) -> [String: VolumeTrash] {
        let home = homeMountPoint()
        var byMount: [String: VolumeTrash] = [:]
        var answers: [String: VolumeTrash] = [:]

        for path in paths {
            guard let mount = mount(of: path) else { continue }
            if let known = byMount[mount.point] {
                answers[path] = known
                continue
            }
            let folder = (path as NSString).deletingLastPathComponent
            let trash = VolumeTrash(
                mountPoint: mount.point,
                volumeName: volumeName(of: mount.point),
                verdict: decide(mount: mount, homeMountPoint: home) {
                    probe(in: folder)
                }
            )
            byMount[mount.point] = trash
            answers[path] = trash
        }
        return answers
    }

    // MARK: - Plumbing

    /// A C string field of `statfs`, which Swift imports as a tuple.
    private static func string<T>(from field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
