import DiskCore
import SwiftUI

/// The "Snapshots" tool: the APFS copies each volume keeps of itself.
///
/// This is the view that answers the oldest complaint on the Mac — "I deleted
/// 50 GB and nothing came back". No walk of the filesystem can see a snapshot,
/// so nothing else in the app can show them; here they are, with the exact
/// figure the volume is holding back.
struct SnapshotsView: View {
    let model: ScanModel
    let snapshots: SnapshotsModel

    var body: some View {
        content
            .task { snapshots.loadIfNeeded() }
            // `onChange` rather than `.task(id:)`: the first appearance must
            // not fire a second, redundant listing.
            .onChange(of: model.deletionEpoch) { snapshots.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if snapshots.isReady {
            VStack(spacing: 0) {
                SnapshotsSummary(model: model, snapshots: snapshots)
                if snapshots.totalCount == 0 {
                    empty
                } else {
                    list
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Lecture des snapshots…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Aucun snapshot local", systemImage: "clock.badge.checkmark")
        } description: {
            // Two different pieces of news, and confusing them is exactly what
            // this tool exists to prevent.
            Text(snapshots.purgeableBytes >= 1_000_000_000
                 ? "Aucun snapshot ne retient d'espace. Les "
                   + "\(Format.bytes(snapshots.purgeableBytes)) réservés par macOS "
                   + "sur vos volumes viennent d'ailleurs : caches système, "
                   + "corbeille, index Spotlight."
                 : "Vos volumes ne gardent aucune copie d'eux-mêmes. Rien à "
                   + "récupérer de ce côté.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        // Scrolled to the volume the sidebar asked for, when it asked for one.
        ScrollViewReader { proxy in
            List {
                ForEach(snapshots.volumes) { volume in
                    Section {
                        if volume.snapshots.isEmpty {
                            Text("Aucun snapshot sur ce volume.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(volume.snapshots) { snapshot in
                                SnapshotRow(snapshots: snapshots, snapshot: snapshot)
                            }
                        }
                    } header: {
                        header(for: volume)
                    } footer: {
                        footer(for: volume)
                    }
                    .id(volume.mountPoint)
                }
            }
            .listStyle(.inset)
            .onChange(of: model.snapshotVolumeRequest) { _, requested in
                scroll(proxy, to: requested)
            }
            .task { scroll(proxy, to: model.snapshotVolumeRequest) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to mountPoint: String?) {
        guard let mountPoint,
              snapshots.volumes.contains(where: { $0.mountPoint == mountPoint })
        else { return }
        proxy.scrollTo(mountPoint, anchor: .top)
        // Honoured once: leaving it set would drag the list back here on every
        // later refresh.
        model.snapshotVolumeRequest = nil
    }

    private func header(for volume: SnapshotsModel.VolumeSnapshots) -> some View {
        HStack(spacing: 6) {
            Label(volume.name, systemImage: "internaldrive")
            // The volume's purgeable figure used to sit here, and read as a
            // caption to the snapshots underneath — "these hold 3,88 GB" — when
            // on most Macs not one of them holds a byte. It belongs in the
            // footer, next to the sentence that says where the space really is.
            if !volume.snapshots.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(volume.snapshots.count == 1
                     ? "1 snapshot" : "\(volume.snapshots.count) snapshots")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Age rather than weight. macOS publishes no size for a snapshot —
            // they share their blocks, so there is no size to publish — but how
            // far back the local history reaches is a real fact about them, and
            // it is not the volume's free space repeated from the sidebar.
            if let oldest = volume.oldestDate {
                Text("·").foregroundStyle(.tertiary)
                Text("le plus ancien \(Format.age(since: oldest))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Only the selection shortcut stays here. A section header is a
            // caption's worth of room, and a pull-down menu in it had nowhere
            // to open — the bulk actions moved to the summary bar, which has
            // the width for them.
            if !volume.deletable.isEmpty {
                Button("Tout") { snapshots.selectAll(in: volume) }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func footer(for volume: SnapshotsModel.VolumeSnapshots) -> some View {
        let text = footerText(for: volume)
        if !text.isEmpty {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                // A section footer is laid out at its ideal height, which for a
                // Text is one line — without this the sentence truncates rather
                // than wrapping.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One short sentence about the snapshots themselves, and nothing else.
    ///
    /// Where the purgeable space actually is belongs to the summary bar, which
    /// says it once for every volume; repeating it here made a paragraph out of
    /// a caption.
    private func footerText(for volume: SnapshotsModel.VolumeSnapshots) -> String {
        if volume.hasPurgeableSnapshots {
            return "Les snapshots partagent leurs blocs entre eux et avec le "
                + "disque : aucune taille individuelle n'existe."
        }
        if volume.hasSystemSnapshot {
            return "Un snapshot de mise à jour disparaît de lui-même une fois "
                + "la mise à jour confirmée."
        }
        return ""
    }
}

// MARK: - Summary

private struct SnapshotsSummary: View {
    let model: ScanModel
    let snapshots: SnapshotsModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.count(snapshots.totalCount))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text(snapshots.totalCount == 1 ? "snapshot local" : "snapshots locaux")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshots.purgeableBytes > 0 {
                Divider().frame(height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    // Green means "you can get this back, here". The figure is
                    // true either way, but when no listed snapshot is purgeable,
                    // acting on this screen will not move it — so it must not
                    // read as an invitation.
                    Text(Format.bytes(snapshots.purgeableBytes))
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            snapshots.snapshotsExplainPurgeable ? .green : .secondary
                        )
                    // Worded exactly as the sidebar words it: this is the same
                    // number, and reading it twice must not raise the question
                    // of whether it is the same thing.
                    Text(snapshots.snapshotsExplainPurgeable
                         ? "réservés par macOS, snapshots compris"
                         : "réservés par macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(purgeableExplanation)
            }

            if snapshots.isWorking {
                Divider().frame(height: 32)
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Suppression en cours…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                snapshots.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Relire les snapshots")
            .disabled(snapshots.isWorking)

            if !snapshots.thinnable.isEmpty {
                Menu("Libérer…") {
                    ForEach(snapshots.thinnable) { volume in
                        // Flat when there is one disk, which is the usual case;
                        // a section per volume only when the distinction exists.
                        if snapshots.thinnable.count > 1 {
                            Section(volume.name) { thinningItems(for: volume) }
                        } else {
                            thinningItems(for: volume)
                        }
                    }
                }
                .fixedSize()
                .disabled(snapshots.isWorking)
            }

            Button("Supprimer (\(snapshots.selection.count))", role: .destructive) {
                snapshots.requestSelectionDeletion()
            }
            .disabled(snapshots.selection.isEmpty || snapshots.isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }

    @ViewBuilder
    private func thinningItems(
        for volume: SnapshotsModel.VolumeSnapshots
    ) -> some View {
        ForEach(
            SnapshotDeleter.thinningTargets(upTo: volume.purgeableBytes), id: \.self
        ) { target in
            Button(Format.bytes(target)) {
                snapshots.requestThin(volume, bytes: target)
            }
        }
        Divider()
        Button(volume.deletable.count == 1
               ? "Le seul snapshot supprimable"
               : "Les \(volume.deletable.count) snapshots supprimables") {
            snapshots.requestWholeVolume(volume)
        }
    }

    /// The long version, on hover — the summary line has room for a verdict,
    /// not for the reasoning behind it.
    private var purgeableExplanation: String {
        let intro = "Espace que macOS s'est réservé et qu'il rendra de lui-même "
            + "si le disque se remplit. Il l'appelle « purgeable »."
        guard snapshots.snapshotsExplainPurgeable else {
            return intro + "\n\nAucun snapshot n'y contribue : APFS les marque "
                + "tous comme non récupérables. Il vient des caches système, de "
                + "la corbeille et de l'index Spotlight — les outils Caches et "
                + "résidus et Redémarrage en reprennent une partie tout de suite."
        }
        return intro + "\n\nLes snapshots ci-dessous y contribuent, mais pas "
            + "seuls : les caches système, la corbeille et l'index Spotlight en "
            + "font partie. Aucune part exacte ne peut être attribuée à chacun."
    }
}

// MARK: - Row

private struct SnapshotRow: View {
    let snapshots: SnapshotsModel
    let snapshot: APFSSnapshot

    var body: some View {
        HStack(spacing: 10) {
            // Only the removable ones get a box. A checkbox that refuses to be
            // ticked is a worse explanation than no checkbox at all — the badge
            // and the tooltip carry the reason.
            if snapshot.isDeletable {
                Toggle("", isOn: Binding(
                    get: { snapshots.selection.contains(snapshot.uuid) },
                    set: { _ in snapshots.toggle(snapshot) }
                ))
                .labelsHidden()
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(snapshot.isDeletable ? .primary : .secondary)
                if let date = snapshot.date {
                    Text(Format.age(since: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            KindBadge(kind: snapshot.kind)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { snapshots.toggle(snapshot) }
        .help(explanation)
        .listRowSeparator(.hidden)
    }

    /// The date when there is one. Failing that, anything but the raw name —
    /// an installer snapshot is called `com.apple.os.update-` followed by a
    /// sixty-character hash, which fills the row and says nothing.
    private var title: String {
        if let date = snapshot.date {
            return date.formatted(date: .long, time: .shortened)
        }
        return snapshot.kind == .system ? "Mise à jour du système" : snapshot.name
    }

    private var explanation: String {
        switch snapshot.kind {
        case .timeMachine where snapshot.isDeletable:
            return "Copie locale de Time Machine. La supprimer retire la "
                + "possibilité de restaurer des fichiers à cette date sans le "
                + "disque de sauvegarde."
        case .timeMachine:
            return "Snapshot Time Machine dont la date n'a pas pu être lue : "
                + "Silt ne le supprimera pas à l'aveugle.\n\(snapshot.name)"
        case .system:
            return "Créé par une mise à jour du système. macOS le supprime "
                + "lui-même une fois la mise à jour confirmée."
                + (snapshot.limitsContainerShrink
                   ? "\nC'est lui qui fixe la taille minimale du conteneur APFS."
                   : "")
                + "\n\(snapshot.name)"
        case .other:
            return "Snapshot créé par un autre outil. Seul cet outil sait le "
                + "retirer.\n\(snapshot.name)"
        }
    }
}

private struct KindBadge: View {
    let kind: APFSSnapshot.Kind

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }

    private var label: String {
        switch kind {
        case .timeMachine: "Time Machine"
        case .system: "Système"
        case .other: "Autre"
        }
    }
}
