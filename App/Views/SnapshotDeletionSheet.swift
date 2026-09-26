import DiskCore
import SwiftUI

/// Last stop before a snapshot goes, and deliberately not `DeletionSheet`.
///
/// A snapshot has no trash: it is unlinked from the volume and gone. The other
/// sheet only reaches that ground after probing a volume and watching its trash
/// fail, and it says so item by item; here it is the whole point of the tool,
/// every time, with no half of the batch to put back. Reusing a sheet built
/// around a way back would be the one lie the app cannot afford.
struct SnapshotDeletionSheet: View {
    let request: SnapshotsModel.Request
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let namesShown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("Volume « \(request.volumeName) »")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if case .thin(let bytes) = request.kind {
                Text("Time Machine supprimera ses snapshots les plus anciens "
                     + "jusqu'à libérer \(Format.bytes(bytes)), ou jusqu'à ce "
                     + "qu'il n'en reste plus. Vous ne choisissez pas lesquels.")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            } else if !dates.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(dates.prefix(namesShown), id: \.self) { date in
                        Text("• \(date)").lineLimit(1).truncationMode(.middle)
                    }
                    if dates.count > namesShown {
                        Text("et \(dates.count - namesShown) autres")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
            }

            warning(
                symbol: "exclamationmark.triangle", tint: .red,
                title: "Définitif",
                lines: [
                    "Un snapshot supprimé ne va pas à la corbeille et ne peut "
                        + "pas être restauré.",
                    "Vous perdez la possibilité de récupérer des fichiers à ces "
                        + "dates sans brancher votre disque de sauvegarde.",
                ]
            )

            // Said before the dialog appears rather than left as a surprise:
            // a password prompt nobody expected reads like something went wrong.
            Label(
                "macOS vous demandera votre mot de passe administrateur.",
                systemImage: "lock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("L'espace récupéré ne peut pas être annoncé à l'avance : les "
                 + "snapshots partagent leurs blocs entre eux et avec le disque. "
                 + "Silt mesurera ce qui a réellement été libéré.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Supprimer définitivement", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var dates: [String] {
        request.snapshots.map { snapshot in
            snapshot.date.map { $0.formatted(date: .long, time: .shortened) }
                ?? snapshot.name
        }
    }

    private var title: String {
        switch request.kind {
        case .thin:
            return "Alléger les snapshots ?"
        case .wholeVolume:
            return "Supprimer les \(request.snapshots.count) snapshots de ce volume ?"
        case .selection:
            return request.snapshots.count == 1
                ? "Supprimer ce snapshot ?"
                : "Supprimer \(request.snapshots.count) snapshots ?"
        }
    }

    private func warning(
        symbol: String, tint: Color, title: String, lines: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 7))
    }
}
