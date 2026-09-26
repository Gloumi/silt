import DiskCore
import SwiftUI

/// Last stop before anything moves — or the last but one, when part of the
/// batch cannot be undone.
///
/// It states the count, the space involved, and shows the items rather than
/// asking "are you sure?" about an abstraction — the failure mode to design
/// against is someone confirming a selection they had misread. To that end
/// the list is not just readable but *workable*: each row carries a thumbnail
/// and its folder, a click selects, space opens Quick Look, and the ⊖ pulls
/// an item back out of the batch — second thoughts belong here, not after.
///
/// Items on a volume whose trash was probed and found not to move anything are
/// marked as such and raise a second confirmation, since for those there is no
/// banner to undo from afterwards.
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
    /// The second confirmation, raised over the sheet rather than after it: the
    /// model clears the plan as its first act, so a sheet dismissal and an
    /// alert presentation would be racing. Nothing is dismissed until the alert
    /// has been answered.
    @State private var confirmingPermanent = false

    /// Below this the list is exactly as tall as its rows; past it, it
    /// scrolls, so a fifty-item batch cannot push the buttons off screen.
    private let rowsBeforeScrolling = 6

    private var remaining: [(index: Int, request: SafeDeleter.Request)] {
        plan.requests.enumerated()
            .filter { !excluded.contains($0.offset) }
            .map { (index: $0.offset, request: $0.element) }
    }

    /// What is left in the batch that cannot be undone. Pull every one of them
    /// out with ⊖ and this becomes an ordinary deletion again, with nothing
    /// extra to agree to — which is why it is derived, not remembered.
    private var permanent: [(index: Int, request: SafeDeleter.Request)] {
        remaining.filter(\.request.permanent)
    }

    var body: some View {
        let remaining = remaining
        let permanent = permanent
        let bytes = remaining.reduce(Int64(0)) { $0 + $1.request.bytes }
        let allPermanent = !permanent.isEmpty && permanent.count == remaining.count

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: allPermanent ? "trash.slash" : "trash")
                    .font(.title2)
                    .foregroundStyle(allPermanent ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(remaining.count, permanent: allPermanent))
                        .font(.headline)
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
            if !permanent.isEmpty {
                warning(
                    symbol: "trash.slash", tint: .red, title: "Définitif",
                    lines: permanent.map { item in
                        let name = (item.request.path as NSString).lastPathComponent
                        let volume = plan.trashlessVolume(at: item.index) ?? ""
                        return "\(name) — sur « \(volume) »"
                    }
                )
            }
            if !plan.refused.isEmpty {
                warning(
                    symbol: "lock", tint: .red,
                    title: "Protégés — non supprimés", lines: plan.refused
                )
            }

            Text(footnote(remaining: remaining.count, permanent: permanent.count))
                .font(.caption)
                .foregroundStyle(permanent.isEmpty ? .secondary : .primary)

            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle(permanent: permanent.count, of: remaining.count)) {
                    if permanent.isEmpty { onConfirm(excluded) }
                    else { confirmingPermanent = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(remaining.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .alert("Suppression définitive", isPresented: $confirmingPermanent) {
            // Cancel carries the default button on purpose. This sheet's own
            // confirmation already sits on Return, and a second press — a
            // repeat, an impatient double tap — would otherwise go straight
            // through an irreversible deletion.
            Button("Annuler", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Supprimer", role: .destructive) { onConfirm(excluded) }
        } message: {
            Text(permanentAlertMessage)
        }
        .dialogSeverity(.critical)
        // Space previews the selected row, the Finder gesture. A hidden
        // shortcut button rather than key handling: the global space monitor
        // deliberately leaves sheets alone. Closing again is its business
        // though — by then the panel, not the sheet, holds the keyboard.
        .background {
            Button("") { previewSelected() }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
        // An open panel follows the row the arrow keys land on, since those keys
        // reach the list from the panel too.
        .onChange(of: selected) {
            guard QuickLookPanel.shared.isOpen else { return }
            previewSelected()
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

            // Marked per row, not just summarised below: the ⊖ is right there,
            // and knowing *which* items cannot come back is what makes pulling
            // exactly those out of the batch possible.
            if item.request.permanent {
                Image(systemName: "trash.slash")
                    .foregroundStyle(.red)
                    .help(
                        "Sur « \(plan.trashlessVolume(at: item.index) ?? "") » : sera effacé immédiatement"
                    )
            }

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
            Button("Aperçu rapide") { preview(item.index) }
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
        guard let selected else { return }
        preview(selected)
    }

    /// The whole batch goes to the panel, not just the row that asked for it, so
    /// the arrow keys walk the list the way they walk a selection in the Finder.
    private func preview(_ index: Int) {
        let items = remaining
        guard let start = items.firstIndex(where: { $0.index == index })
        else { return }
        QuickLookPanel.shared.show(
            items.map { URL(fileURLWithPath: $0.request.path) }, startingAt: start
        )
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

    // MARK: - What the sheet can honestly say

    private func title(_ count: Int, permanent: Bool) -> String {
        if permanent {
            return count == 1
                ? "Supprimer définitivement cet élément ?"
                : "Supprimer définitivement \(count) éléments ?"
        }
        return count == 1
            ? "Mettre cet élément à la corbeille ?"
            : "Mettre \(count) éléments à la corbeille ?"
    }

    private func confirmTitle(permanent: Int, of total: Int) -> String {
        if permanent == 0 { return "Mettre à la corbeille" }
        // "Mettre à la corbeille" would be a lie for a mixed batch, and naming
        // only the irreversible half would be one for the rest of it.
        return permanent == total ? "Supprimer définitivement" : "Supprimer"
    }

    private func footnote(remaining: Int, permanent: Int) -> String {
        guard permanent > 0 else {
            return "Les éléments partent à la corbeille : rien n'est effacé définitivement."
        }
        if permanent == remaining {
            return "\(volumeClause) : ces éléments seront effacés immédiatement, sans retour possible."
        }
        let trashed = remaining - permanent
        return "\(trashed) élément(s) partent à la corbeille. \(permanent) sont sur \(volumeList), qui n'a pas de corbeille utilisable : ceux-là seront effacés immédiatement."
    }

    private var permanentAlertMessage: String {
        let count = permanent.count
        let subject = count == 1
            ? "Cet élément sera effacé immédiatement."
            : "\(count) éléments seront effacés immédiatement."
        let others = remaining.count - count
        guard others > 0 else {
            return "\(volumeClause). \(subject) Cette action est irréversible."
        }
        let plural = count == 1 ? "y sera effacé" : "y seront effacés"
        return "\(volumeClause). \(count) élément(s) \(plural) immédiatement ; \(others) autre(s) partiront à la corbeille. L'effacement est irréversible."
    }

    /// « La corbeille n'est pas disponible sur « Backup » [ni sur « Photos »] ».
    private var volumeClause: String {
        "La corbeille n'est pas disponible sur \(volumeList)"
    }

    private var volumeList: String {
        let names = plan.trashlessVolumeNames(excluding: excluded)
            .map { "« \($0) »" }
        guard let first = names.first else { return "ce volume" }
        return names.dropFirst().reduce(first) { $0 + " ni sur " + $1 }
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
