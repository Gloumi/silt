import DiskCore
import SwiftUI

/// Last stop before anything moves.
///
/// It states the count, the space involved, and shows the items rather than
/// asking "are you sure?" about an abstraction — the failure mode to design
/// against is someone confirming a selection they had misread. To that end
/// the list is not just readable but *workable*: each row carries a thumbnail
/// and its folder, a click selects, space opens Quick Look, and the ⊖ pulls
/// an item back out of the batch — second thoughts belong here, not after.
struct DeletionSheet: View {
    let plan: ScanModel.DeletionPlan
    let onCancel: () -> Void
    /// Called with the indices of `plan.requests` the user pulled out.
    let onConfirm: (Set<Int>) -> Void

    /// Indices into `plan.requests` withdrawn from the batch. The plan itself
    /// stays untouched while the sheet is up — mutating it would re-present
    /// the sheet — so exclusion is applied by `confirmDeletion` at the end.
    @State private var excluded: Set<Int> = []
    @State private var selected: Int?
    @State private var previewURL: URL?

    /// Below this the list is exactly as tall as its rows; past it, it
    /// scrolls, so a fifty-item batch cannot push the buttons off screen.
    private let rowsBeforeScrolling = 6

    private var remaining: [(index: Int, request: SafeDeleter.Request)] {
        plan.requests.enumerated()
            .filter { !excluded.contains($0.offset) }
            .map { (index: $0.offset, request: $0.element) }
    }

    var body: some View {
        let remaining = remaining
        let bytes = remaining.reduce(Int64(0)) { $0 + $1.request.bytes }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(remaining.count)).font(.headline)
                    Text("\(Format.bytes(bytes)) seront libérés")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !remaining.isEmpty {
                List(selection: $selected) {
                    ForEach(remaining, id: \.index) { item in
                        row(item)
                    }
                }
                .listStyle(.inset)
                .frame(height: CGFloat(min(remaining.count, rowsBeforeScrolling)) * 44 + 12)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            }

            if !excluded.isEmpty {
                HStack(spacing: 8) {
                    Text(excluded.count == 1
                         ? "1 élément retiré de la liste"
                         : "\(excluded.count) éléments retirés de la liste")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Tout remettre") { excluded = [] }
                        .controlSize(.small)
                }
            }

            if !visibleCautions.isEmpty {
                warning(
                    symbol: "exclamationmark.triangle", tint: .orange,
                    title: "À vérifier", lines: visibleCautions
                )
            }
            if !plan.refused.isEmpty {
                warning(
                    symbol: "lock", tint: .red,
                    title: "Protégés — non supprimés", lines: plan.refused
                )
            }

            Text("Les éléments partent à la corbeille : rien n'est effacé définitivement.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Mettre à la corbeille") { onConfirm(excluded) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(remaining.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        // Space previews the selected row, the Finder gesture. A hidden
        // shortcut button rather than key handling: the global space monitor
        // deliberately leaves sheets alone, and this is the pattern the Quick
        // Look sheet itself already uses to close.
        .background {
            Button("") { previewSelected() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
        .sheet(item: $previewURL) { url in
            QuickLookSheet(url: url) { previewURL = nil }
        }
    }

    // MARK: - Rows

    private func row(_ item: (index: Int, request: SafeDeleter.Request)) -> some View {
        HStack(alignment: .center, spacing: 9) {
            FileThumbnail(path: item.request.path, isPackage: false, pixelSize: 64)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text((item.request.path as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((item.request.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.request.path)
            }

            Spacer(minLength: 12)

            Text(Format.bytes(item.request.bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                withdraw(item.index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Retirer de la liste — ne sera pas supprimé")
        }
        .padding(.vertical, 2)
        .tag(item.index)
        .contextMenu {
            Button("Aperçu rapide") {
                previewURL = URL(fileURLWithPath: item.request.path)
            }
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: item.request.path)]
                )
            }
            Divider()
            Button("Retirer de la liste") { withdraw(item.index) }
        }
    }

    private func withdraw(_ index: Int) {
        excluded.insert(index)
        if selected == index { selected = nil }
    }

    private func previewSelected() {
        guard let selected, !excluded.contains(selected),
              plan.requests.indices.contains(selected)
        else { return }
        previewURL = URL(fileURLWithPath: plan.requests[selected].path)
    }

    /// Cautions whose item has been withdrawn go with it — warning about
    /// something no longer in the batch would read as a bug. Names align with
    /// requests by construction in `requestDeletion`.
    private var visibleCautions: [String] {
        guard !excluded.isEmpty else { return plan.cautions }
        let kept = Set(remaining.compactMap {
            plan.names.indices.contains($0.index) ? plan.names[$0.index] : nil
        })
        let gone = excluded.compactMap {
            plan.names.indices.contains($0) ? plan.names[$0] : nil
        }
        return plan.cautions.filter { caution in
            !gone.contains { caution.hasPrefix("\($0) — ") && !kept.contains($0) }
        }
    }

    private func title(_ count: Int) -> String {
        count == 1
            ? "Mettre cet élément à la corbeille ?"
            : "Mettre \(count) éléments à la corbeille ?"
    }

    private func warning(
        symbol: String, tint: Color, title: String, lines: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(lines.prefix(4), id: \.self) { line in
                Text(line).font(.caption).lineLimit(2)
            }
            if lines.count > 4 {
                Text("et \(lines.count - 4) autres")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 7))
    }
}
