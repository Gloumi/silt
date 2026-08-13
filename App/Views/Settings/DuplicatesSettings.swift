import SwiftUI

/// The two floors of the duplicates view, and what each one would cost.
struct DuplicatesSettings: View {
    @Bindable private var preferences = Preferences.shared
    private var estimator = ThresholdEstimate.shared

    var body: some View {
        Form {
            Section {
                threshold(
                    "Fichiers d'au moins",
                    bytes: $preferences.duplicateThresholdBytes,
                    ladder: SizeLadder.file,
                    help: "Seuls les fichiers d'au moins cette taille sont comparés. Descendre sous 1 Mo est ce qu'il faut faire pour retrouver des photos en double — la plupart pèsent entre 300 Ko et 3 Mo — mais le coût ne baisse pas proportionnellement : les petites tailles se répètent bien plus souvent, et sous 128 Ko chaque fichier est lu en entier au lieu d'être lu partiellement."
                )
            }

            Section {
                threshold(
                    "Dossiers d'au moins",
                    bytes: $preferences.duplicateFolderThresholdBytes,
                    ladder: SizeLadder.folder,
                    help: "Les dossiers entièrement identiques sont proposés en tête de la vue Doublons, et les fichiers qu'ils contiennent y sont regroupés. Confirmer un dossier oblige à lire chacun de ses fichiers, quelle que soit sa taille : un seuil bas coûte cher sur un disque de développement."
                )
            }

            Section {
                estimate
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - A threshold and what it costs

    /// The slider drives an *index* into the ladder, so every position is a
    /// value someone would actually write down.
    private func threshold(
        _ title: String, bytes: Binding<Int64>, ladder: [Int64], help: String
    ) -> some View {
        let index = Binding(
            get: { Double(SizeLadder.index(of: bytes.wrappedValue, in: ladder)) },
            set: { bytes.wrappedValue = SizeLadder.bytes(at: Int($0), in: ladder) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(Format.bytes(bytes.wrappedValue))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            // A bare `Slider`, with the bounds written beside it by hand. Given
            // a label — even an empty one — a Form reserves its label column
            // and the track ends up squeezed into the right half of the row.
            HStack(spacing: 8) {
                Text(Format.bytes(ladder.first ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: index, in: 0...Double(ladder.count - 1), step: 1)
                    // Without this a grouped Form still reserves its label
                    // column for the control, and the track ends up squeezed
                    // into the right half of the row with dead space beside it.
                    .labelsHidden()
                Text(Format.bytes(ladder.last ?? 0))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let count = estimator.candidates(above: bytes.wrappedValue),
               let toRead = estimator.bytesToRead(above: bytes.wrappedValue) {
                // One walk answered every rung, so this follows the thumb
                // instead of arriving after the pass has already cost the time.
                Text("≈ \(Format.count(count)) fichiers à comparer, \(Format.bytes(toRead)) à lire")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The census behind the figures above. Off by default and asked for
    /// explicitly: it walks the whole home folder, and taking minutes of disk
    /// the moment someone opens Settings would be a poor trade for a number
    /// they may not have come for.
    @ViewBuilder
    private var estimate: some View {
        switch estimator.phase {
        case .running(let seen):
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Estimation en cours — \(Format.count(seen)) fichiers parcourus")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Annuler") { estimator.cancel() }
                    .controlSize(.small)
            }
        case .ready:
            HStack(spacing: 9) {
                Text("Estimation faite sur \(estimator.root) — indicative : la vue Doublons ne compare que le dossier où vous vous trouvez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Recalculer") { estimator.measure() }
                    .controlSize(.small)
            }
        case .failed:
            HStack(spacing: 9) {
                Text("Le dossier personnel n'a pas pu être parcouru.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Réessayer") { estimator.measure() }
                    .controlSize(.small)
            }
        case .idle:
            HStack(spacing: 9) {
                Text("Une analyse préalable de votre dossier personnel dit combien de fichiers chaque seuil ferait comparer. Elle ne lit aucun contenu, seulement les tailles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Estimer") { estimator.measure() }
                    .controlSize(.small)
            }
        }
    }
}
