import AppKit
import SwiftUI

/// A newer release, and the one gesture that installs it on this Mac.
///
/// Two gestures, because Silt arrives two ways. A cask install is upgraded by
/// Homebrew — downloading the DMG over it would leave `brew` believing in a
/// version that is no longer there. A DMG install goes back to the release
/// page. Both end with the same Gatekeeper detour, since the build is
/// unsigned: Homebrew quarantines what it downloads, and no longer has a
/// `--no-quarantine` to say otherwise (Homebrew 7 rejects the option).
struct UpdateSheet: View {
    let release: Release
    let onDismiss: () -> Void

    private let checker = UpdateChecker.shared
    private let viaHomebrew = UpdateChecker.installedWithHomebrew
    private let command = "brew upgrade --cask silt"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Silt \(release.displayVersion) est disponible")
                        .font(.title3.weight(.semibold))
                    Text("Publiée le \(release.publishedAt.formatted(date: .long, time: .omitted)) · vous utilisez la version \(checker.currentVersionText)")
                        .foregroundStyle(.secondary)
                }
            }

            Link("Notes de version", destination: release.page)

            if viaHomebrew { homebrew } else { download }

            Text("La build n'étant pas signée, macOS refusera le premier lancement : ouvrez alors Réglages Système › Confidentialité et sécurité, et cliquez sur « Ouvrir quand même ».")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("Après la mise à jour, macOS retire à Silt l'accès complet au disque. Silt vous guidera pour le lui rendre.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button("Ignorer cette version") {
                    checker.skip(release)
                    onDismiss()
                }
                Spacer()
                Button("Plus tard", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                if !viaHomebrew {
                    Button("Ouvrir la page de téléchargement") {
                        NSWorkspace.shared.open(release.page)
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var homebrew: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Silt a été installé avec Homebrew. Dans le Terminal :")
                .font(.callout)
            HStack {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: 6))
                Button(copied ? "Copié" : "Copier") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var download: some View {
        Text("Téléchargez le DMG et remplacez Silt dans Applications.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
