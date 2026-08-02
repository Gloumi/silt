import SwiftUI

/// Shown on first launch, and reachable afterwards from the warning in the
/// status bar.
///
/// Full Disk Access is the difference between a scan that sees everything and
/// one that quietly under-reports by tens of gigabytes. Since it cannot be
/// requested programmatically, the honest thing is to explain what it buys,
/// admit it needs a relaunch, and get out of the way.
struct WelcomeSheet: View {
    let unreadableCount: Int
    let onDismiss: () -> Void

    @State private var granted = FullDiskAccess.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 30))
                    .foregroundStyle(granted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "Accès complet accordé" : "Accès complet au disque")
                        .font(.title3.weight(.semibold))
                    Text(granted
                         ? "Strata peut analyser l'intégralité de votre disque."
                         : "Sans cette autorisation, certains dossiers restent invisibles.")
                        .foregroundStyle(.secondary)
                }
            }

            if !granted {
                VStack(alignment: .leading, spacing: 9) {
                    if unreadableCount > 0 {
                        Text("Au dernier scan, \(unreadableCount) dossiers n'ont pas pu être lus. Leur contenu manque aux totaux.")
                            .font(.callout)
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 7))
                    }

                    Text("macOS protège certains dossiers — Mail, Messages, Photos, les sauvegardes d'appareils. Aucune application ne peut y accéder sans votre accord explicite, et cet accord ne peut être demandé que depuis les Réglages Système.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    steps
                }
            }

            Divider()

            HStack {
                if !granted {
                    Button("Ouvrir les Réglages") { FullDiskAccess.openSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Révéler Strata") { FullDiskAccess.revealApplication() }
                        .help("Pour la faire glisser dans la liste des autorisations")
                }
                Spacer()
                Button(granted ? "Commencer" : "Plus tard", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Re-checked when the window comes back to the front, so returning from
        // System Settings updates it without a restart of this sheet.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in granted = FullDiskAccess.isGranted }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            step(1, "Ouvrez Réglages Système › Confidentialité et sécurité › Accès complet au disque.")
            step(2, "Activez Strata dans la liste, ou faites-la glisser depuis le Finder.")
            step(3, "Relancez Strata — macOS l'exige pour appliquer l'autorisation.")
        }
        .font(.callout)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .frame(width: 17, height: 17)
                .background(.quaternary, in: .circle)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
