import AppKit
import DiskCore
import SwiftUI

/// The "Applications" tool: everything installed, what it really occupies, and
/// a way into the uninstaller that does not require scanning a volume first.
///
/// The uninstaller has always been here; it was reachable only by scanning,
/// walking to `/Applications` and selecting a bundle in the inspector. This is
/// the same machinery, entered the way people actually think about it.
struct AppsView: View {
    let model: ScanModel
    let apps: AppsModel

    var body: some View {
        content
            .task { apps.loadIfNeeded() }
            // `onChange` rather than `.task(id:)`: the first appearance must not
            // fire a second, redundant inventory. Reconciliation only — a
            // deletion drops a row, an undo brings it back, and nothing else is
            // measured again.
            .onChange(of: model.deletionEpoch) { apps.reconcile() }
    }

    @ViewBuilder
    private var content: some View {
        if apps.items.isEmpty {
            if case .ready = apps.phase {
                ContentUnavailableView {
                    Label("Aucune application", systemImage: "app.dashed")
                } description: {
                    Text("Rien de lisible dans /Applications ni dans votre dossier Applications personnel.")
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Inventaire des applications…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                AppsSummary(apps: apps)
                // A real list selection, not a tap gesture: selecting an
                // application shows it in the inspector exactly as selecting a
                // folder does, and uninstalling stays a deliberate second step.
                List(apps.items, selection: Bindable(apps).selection) { item in
                    AppRow(
                        apps: apps, item: item,
                        fraction: Double(item.total)
                            / Double(max(1, apps.items.map(\.total).max() ?? 1)),
                        onUninstall: { uninstall(item) }
                    )
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }
        }
    }

    private func uninstall(_ item: AppsModel.Item) {
        guard !apps.isSelf(item) else { return }
        apps.selection = item.id
        model.prepareUninstall(appPath: item.app.path)
    }
}

// MARK: - Summary

private struct AppsSummary: View {
    let apps: AppsModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(apps.totalBytes))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("\(Format.count(apps.items.count)) applications installées")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if apps.isMeasuringLeftovers {
                Divider().frame(height: 32)
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Recherche des fichiers liés…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 7) {
                Text("Tri :")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Tri", selection: Bindable(apps).sort) {
                    ForEach(AppsModel.Sort.allCases) { sort in
                        Text(sort.label).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Button {
                apps.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refaire l'inventaire")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

// MARK: - Row

private struct AppRow: View {
    let apps: AppsModel
    let item: AppsModel.Item
    let fraction: Double
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: apps.icon(for: item.app.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.app.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isRunning { RunningBadge() }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(item.app.path)

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.bytes(item.total))
                    .monospacedDigit()
                    .fontWeight(.medium)
                Text(leftoverCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 118, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.proportionBar)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Désinstaller…", action: onUninstall)
                .disabled(apps.isSelf(item))
            Button("Ouvrir", action: open)
            Button("Afficher dans le Finder", action: revealInFinder)
        }
    }

    /// The identifier is what the uninstaller matches on, so showing it is
    /// showing why a given pile of leftovers was attributed here.
    ///
    /// macOS keeps no launch record for a good half of what is installed —
    /// `mdls` says the same — so "inconnue" is said plainly rather than
    /// dressed up as a date taken from something else.
    private var subtitle: String {
        let identifier = item.app.bundleID ?? "sans identifiant"
        guard let used = item.installed.lastUsed,
              let age = Format.age(unixSeconds: used)
        else { return identifier + " · utilisation inconnue" }
        return identifier + " · ouverte " + age
    }

    /// Three states, and the distinction matters: still counting, counted and
    /// found nothing, counted and found something.
    private var leftoverCaption: String {
        guard let leftovers = item.leftoverBytes else { return "…" }
        guard leftovers > 0 else { return "rien de lié" }
        return "dont " + Format.bytes(leftovers) + " liés"
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: item.app.path)]
        )
    }

    private func open() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: item.app.path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private struct RunningBadge: View {
    var body: some View {
        Text("en cours d'exécution")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.green.opacity(0.18), in: Capsule())
            .foregroundStyle(.green)
    }
}
