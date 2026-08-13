import AppKit
import SwiftUI

/// The one permission the app needs, and whether it has it.
struct PermissionsSettings: View {
    @State private var accessGranted = FullDiskAccess.isGranted

    var body: some View {
        Form {
            Section {
                LabeledContent("Accès complet au disque") {
                    HStack(spacing: 7) {
                        Image(systemName: accessGranted
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(accessGranted ? .green : .orange)
                        Text(accessGranted ? "Accordé" : "Non accordé")
                        if !accessGranted {
                            Button("Réglages…") { FullDiskAccess.openSettings() }
                        }
                    }
                }
                SettingHelp(accessGranted
                    ? "Mail, Messages, Photos et les sauvegardes d'appareils sont visibles et comptés dans les totaux."
                    : "Sans cette autorisation, Mail, Messages, Photos et les sauvegardes d'appareils restent invisibles et manquent aux totaux.")
            }
        }
        .formStyle(.grouped)
        // The grant happens in System Settings, in another app: coming back to
        // this window is the only moment worth re-reading it.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in accessGranted = FullDiskAccess.isGranted }
    }
}
