import SwiftUI

/// Last stop before anything moves.
///
/// It states the count, the space involved, and names the items rather than
/// asking "are you sure?" about an abstraction — the failure mode to design
/// against is someone confirming a selection they had misread.
struct DeletionSheet: View {
    let plan: ScanModel.DeletionPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let namesShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("\(Format.bytes(plan.totalBytes)) seront libérés")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !plan.names.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(plan.names.prefix(namesShown), id: \.self) { name in
                        Text("• \(name)").lineLimit(1).truncationMode(.middle)
                    }
                    if plan.names.count > namesShown {
                        Text("et \(plan.names.count - namesShown) autres")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            }

            if !plan.cautions.isEmpty {
                warning(
                    symbol: "exclamationmark.triangle", tint: .orange,
                    title: "À vérifier", lines: plan.cautions
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
                Button("Mettre à la corbeille", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.requests.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var title: String {
        plan.count == 1
            ? "Mettre cet élément à la corbeille ?"
            : "Mettre \(plan.count) éléments à la corbeille ?"
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
