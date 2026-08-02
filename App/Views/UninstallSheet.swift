import DiskCore
import SwiftUI

/// Removing an application and the traces it leaves around the system.
///
/// The sheet *is* the confirmation — there is no second dialog. Everything that
/// will be trashed is listed here with a checkbox, so a separate "are you sure"
/// would only be asking about a list the user has just been editing.
///
/// Only `certain` matches start ticked. Sweeping widely is the point; ticking
/// widely is how an uninstaller eats a neighbour's data.
struct UninstallSheet: View {
    let model: ScanModel
    let plan: UninstallPlan
    let onDismiss: () -> Void

    @State private var selected: Set<String> = []
    @State private var quitRequested = false

    private var selectedBytes: Int64 {
        plan.app.bytes + plan.leftovers
            .filter { selected.contains($0.path) }
            .reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if plan.isRunning && !quitRequested { runningWarning }
            list
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onAppear {
            selected = Set(
                plan.leftovers.filter { $0.confidence == .certain }.map(\.path)
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("Désinstaller \(plan.app.name)")
                    .font(.title3.weight(.semibold))
                Text(plan.app.bundleID ?? "Sans identifiant de paquet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(selectedBytes))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("à libérer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var runningWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("\(plan.app.name) est en cours d'exécution. Une app active peut réécrire ses préférences en quittant, et ses fichiers ouverts ne seront pas libérés.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Quitter l'app") {
                RunningApps.quit(bundleID: plan.app.bundleID)
                quitRequested = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }

    private var list: some View {
        List {
            Section("L'application") {
                row(
                    name: (plan.app.path as NSString).lastPathComponent,
                    path: plan.app.path,
                    bytes: plan.app.bytes,
                    badge: nil,
                    checked: .constant(true),
                    locked: true
                )
            }

            ForEach(plan.byLocation, id: \.location) { group in
                Section(group.location) {
                    ForEach(group.items) { item in
                        row(
                            name: (item.path as NSString).lastPathComponent,
                            path: item.path,
                            bytes: item.bytes,
                            badge: item.confidence,
                            checked: Binding(
                                get: { selected.contains(item.path) },
                                set: { on in
                                    if on { selected.insert(item.path) }
                                    else { selected.remove(item.path) }
                                }
                            ),
                            locked: false
                        )
                    }
                }
            }

            if plan.leftovers.isEmpty {
                Text("Aucun fichier associé trouvé ailleurs sur le système.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    private func row(
        name: String, path: String, bytes: Int64,
        badge: LeftoverConfidence?, checked: Binding<Bool>, locked: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: checked)
                .labelsHidden()
                .disabled(locked)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if let badge {
                Text(badge.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint(badge).opacity(0.18), in: .capsule)
                    .foregroundStyle(tint(badge))
                    .help(badge.explanation)
            }

            Text(Format.bytes(bytes))
                .monospacedDigit()
                .frame(minWidth: 62, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func tint(_ confidence: LeftoverConfidence) -> Color {
        switch confidence {
        case .certain: .green
        case .probable: .blue
        case .possible: .orange
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selected.count + 1) élément(s) — tout passe par la corbeille")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Annuler", action: onDismiss)
                .keyboardShortcut(.cancelAction)
            Button(role: .destructive) {
                Task { await model.uninstall(plan, keeping: selected) }
            } label: {
                Label("Désinstaller", systemImage: "trash")
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}
