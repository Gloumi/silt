import DiskCore
import SwiftUI

/// The "Redémarrage" tool: how much space a reboot would free, split into
/// what can be recovered right now (the darwin user caches, purged at boot
/// anyway) and what only a restart releases (swap, behind SIP).
struct RebootView: View {
    let model: ScanModel
    let reboot: RebootModel

    var body: some View {
        content
            .task { reboot.measureIfNeeded() }
            // `onChange` rather than `.task(id:)`: the first appearance must
            // not fire a second, redundant measurement.
            .onChange(of: model.deletionEpoch) { reboot.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if let estimate = reboot.estimate {
            // The sleep image frees nothing, so it stays out of `totalBytes` —
            // but a 2 Go file on the disk is still worth showing rather than
            // answering "rien à libérer" and leaving it unexplained.
            if estimate.totalBytes == 0, estimate.sleepImageBytes == 0,
               !estimate.cacheUnreadable {
                ContentUnavailableView {
                    Label("Rien à libérer", systemImage: "sparkles")
                } description: {
                    Text(estimate.cacheDirectory == nil
                         ? "Impossible de localiser les caches système de votre session."
                         : "Ni fichiers d'échange ni caches système en ce moment.")
                }
            } else {
                loaded(estimate)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Mesure en cours…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loaded(_ estimate: RebootModel.Estimate) -> some View {
        VStack(spacing: 0) {
            RebootSummary(model: model, reboot: reboot, estimate: estimate)
            List {
                Section {
                    if estimate.cacheUnreadable {
                        Text("Dossier de caches illisible.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(estimate.cacheEntries) { entry in
                            CacheRow(reboot: reboot, entry: entry)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Label("Récupérable maintenant", systemImage: "trash")
                        Text("·").foregroundStyle(.tertiary)
                        Text(Format.bytes(estimate.cacheBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !estimate.cacheEntries.isEmpty {
                            Button("Tout") {
                                reboot.selection = Set(estimate.cacheEntries.map(\.path))
                            }
                            .buttonStyle(.link)
                        }
                    }
                } footer: {
                    Text("macOS régénère ces caches à la demande et les purge de toute façon au redémarrage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if estimate.swapFiles.isEmpty {
                        Text("Aucun fichier d'échange en ce moment.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(estimate.swapFiles) { file in
                            SwapRow(file: file)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Label("Seulement au redémarrage", systemImage: "restart")
                        Text("·").foregroundStyle(.tertiary)
                        Text(Format.bytes(estimate.swapBytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("macOS crée ces fichiers quand la mémoire vive ne "
                         + "suffit plus et ne les rend quasiment jamais en "
                         + "cours de session : ils s'empilent jusqu'au "
                         + "redémarrage, qui les efface tous.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Its own section, and not a row among the swapfiles: it sits
                // in the same place and looks like the same thing, but a
                // restart leaves it exactly where it is. Counting it in the
                // headline would promise back 2 Go that never come.
                if !estimate.sleepImages.isEmpty {
                    Section {
                        ForEach(estimate.sleepImages) { file in
                            SwapRow(file: file)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Label("Ni l'un ni l'autre", systemImage: "moon.zzz")
                            Text("·").foregroundStyle(.tertiary)
                            Text(Format.bytes(estimate.sleepImageBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("L'image de veille : macOS y recopie la mémoire "
                             + "avant de s'endormir, et la garde d'un "
                             + "démarrage à l'autre. Ni la corbeille ni un "
                             + "redémarrage ne la libèrent — sa taille dépend "
                             + "du réglage de veille du Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Summary

private struct RebootSummary: View {
    let model: ScanModel
    let reboot: RebootModel
    let estimate: RebootModel.Estimate

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text("≈ " + Format.bytes(estimate.totalBytes))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("libérés par un redémarrage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(estimate.cacheBytes))
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                Text("récupérable maintenant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !reboot.selection.isEmpty {
                Text(Format.bytes(reboot.selectedBytes))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            Button {
                reboot.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(reboot.isMeasuring)
            .help("Mesurer à nouveau")
            Button(role: .destructive) {
                model.requestDeletion(outOfTree: reboot.selectedEntries.map {
                    (name: displayName(of: $0), path: $0.path, bytes: $0.bytes)
                })
            } label: {
                Label("Mettre à la corbeille", systemImage: "trash")
            }
            .disabled(reboot.selection.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private func displayName(of entry: RebootModel.CacheEntry) -> String {
        AppNames.shared.friendlyName(for: entry.name, path: entry.path) ?? entry.name
    }
}

// MARK: - Rows

private struct CacheRow: View {
    let reboot: RebootModel
    let entry: RebootModel.CacheEntry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { reboot.selection.contains(entry.path) },
                set: { _ in reboot.toggle(entry) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if headline != entry.name {
                    Text(entry.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(entry.path)

            Spacer(minLength: 10)

            Button(action: revealInFinder) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Afficher dans le Finder")
            .accessibilityLabel("Afficher dans le Finder")

            Text(Format.bytes(entry.bytes))
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { reboot.toggle(entry) }
        .contextMenu {
            Button("Afficher dans le Finder", action: revealInFinder)
        }
    }

    /// "Safari" rather than `com.apple.Safari` when the system can say whose
    /// cache it is; the raw folder name is demoted to the subtitle.
    private var headline: String {
        AppNames.shared.friendlyName(for: entry.name, path: entry.path) ?? entry.name
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: entry.path)]
        )
    }
}

private struct SwapRow: View {
    let file: RebootModel.SwapFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(file.name == "sleepimage"
                 ? "Image de veille (sleepimage)"
                 : file.name)
                .help(file.path)
            Spacer(minLength: 10)
            Text(Format.bytes(file.bytes))
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
