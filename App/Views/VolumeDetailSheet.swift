import DiskCore
import SwiftUI

/// What a disk is really made of.
///
/// A Mac's "Macintosh HD" is six APFS volumes sharing one pool: the sealed
/// System, the Data volume everything is written to, and four nobody ever sees
/// — Preboot, Recovery, VM, Update. Those four are hidden from every volume
/// enumeration and no firmlink leads to them, so no scan can account for a byte
/// of them. On a machine mid-update they came to 38 GB, which is a great deal
/// of disk to have no explanation for.
struct VolumeDetailSheet: View {
    let model: ScanModel
    let volume: VolumeInfo
    let onDismiss: () -> Void

    @State private var detail: Detail?
    @Environment(\.colorScheme) private var colorScheme

    struct Detail: Sendable {
        /// Nil when the volume is not APFS — a disk image, a network share.
        var container: APFSContainer?
        var update: PendingUpdate?
        var snapshotCount: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            footer
        }
        .padding(18)
        .frame(width: 420)
        .task(id: volume.url.path) { await load() }
    }

    private func load() async {
        let path = volume.url.path
        detail = await Task.detached {
            Detail(
                container: APFSContainer.container(forMountPoint: path),
                update: PendingUpdate.current(mountPoint: path),
                snapshotCount: APFSSnapshots.list(mountPoint: path).count
            )
        }.value
    }

    @ViewBuilder
    private var content: some View {
        if let detail {
            if let container = detail.container {
                breakdown(container)
                if let update = detail.update, update.isStaged || update.hasDownload {
                    Callout(text: updateText, tone: .neutral)
                }
                snapshotLink(count: detail.snapshotCount)
            } else {
                // Not APFS: no container to break down, and the two figures the
                // sidebar already shows are all there is to say.
                Text("\(Format.bytes(volume.availableBytes)) libres. Ce volume "
                     + "n'est pas en APFS : il ne partage son espace avec aucun "
                     + "autre.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Lecture du disque…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).font(.headline).lineLimit(1)
                Text("\(Format.bytes(volume.totalBytes)) au total")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Fermer", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - The container

    @ViewBuilder
    private func breakdown(_ container: APFSContainer) -> some View {
        let reachable = container.volumes.filter(\.role.isReachableByScan)
        let hidden = container.volumes.filter { !$0.role.isReachableByScan }

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(reachable.enumerated()), id: \.element.id) { index, volume in
                row(volume, slot: index, of: container.totalBytes)
            }

            // Grouped rather than badged one by one: the figure that answers
            // "where did my disk go" is their total, and four separate badges
            // would say the same thing four times without ever adding up.
            if !hidden.isEmpty {
                caption(
                    "Hors de portée d'un scan · "
                        + Format.bytes(container.unreachableBytes)
                )
                ForEach(Array(hidden.enumerated()), id: \.element.id) { index, volume in
                    row(volume, slot: reachable.count + index, of: container.totalBytes)
                }
            }

            Divider()
            free(container)
        }
    }

    private func row(
        _ volume: APFSContainer.Volume, slot: Int, of total: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(label(for: volume))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.bytes(volume.bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)

            bar(
                fraction: fraction(volume.bytes, of: total),
                // The same eight validated hues the treemap and the sunburst
                // use, so a volume keeps one identity wherever it is drawn.
                tint: Palette.color(
                    slot: slot % Palette.slotCount, ring: 1,
                    dark: colorScheme == .dark
                )
            )
        }
    }

    /// The pool's unallocated space, reconciled with what the sidebar claims.
    ///
    /// The two disagree by design and would otherwise look like a bug: this is
    /// what is free *now*, while the sidebar shows the Finder's figure, which
    /// counts what macOS would hand back by purging. Spelling out the addition
    /// is the only way both numbers can be read without one discrediting the
    /// other.
    @ViewBuilder
    private func free(_ container: APFSContainer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Non alloué")
                Spacer(minLength: 8)
                Text(Format.bytes(container.freeBytes))
                    .monospacedDigit()
            }
            .font(.callout)

            bar(fraction: fraction(container.freeBytes, of: container.totalBytes),
                tint: .secondary)

            if volume.purgeableBytes > 0 {
                Text("La barre latérale annonce "
                     + "\(Format.bytes(container.freeBytes + volume.purgeableBytes)) "
                     + "libres : elle y ajoute les "
                     + "\(Format.bytes(volume.purgeableBytes)) que macOS rendrait "
                     + "en purgeant.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func bar(fraction: Double, tint: some ShapeStyle) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
    }

    private func fraction(_ bytes: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(total)))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    /// Plain French for a role nobody has ever had to name. The volume's own
    /// name is right for a plain data volume — a disk image, a simulator
    /// runtime — and useless for the system ones, which are all called after
    /// the disk or after their role in English.
    private func label(for volume: APFSContainer.Volume) -> String {
        switch volume.role {
        case .data: "Vos données"
        case .system: "Système"
        case .preboot: "Démarrage (Preboot)"
        case .recovery: "Récupération"
        case .vm: "Mémoire virtuelle"
        case .update: "Mise à jour"
        case .hardware, .xart: "Réservé au matériel"
        case .none: volume.name
        }
    }

    // MARK: - Pending update

    /// No figure. The packages are measurable but tiny next to what an update
    /// really occupies, and the rest is not attributable at all — a number here
    /// would mislead in both directions at once.
    private var updateText: String {
        "Mise à jour macOS en attente. macOS reconstruit son volume de "
            + "démarrage : Démarrage et Système sont gonflés le temps de "
            + "l'installation, et une partie de cet espace sera rendue ensuite."
    }

    // MARK: - Snapshots

    private func snapshotLink(count: Int) -> some View {
        Button {
            onDismiss()
            model.showSnapshots(volume: volume.url.path)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                Text(count == 0
                     ? "Aucun snapshot APFS"
                     : (count == 1 ? "1 snapshot APFS" : "\(count) snapshots APFS"))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
