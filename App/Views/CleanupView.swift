import DiskCore
import SwiftUI

/// The list of things worth deleting, grouped by what they are.
///
/// Sorted by category rather than purely by size, because the decision the user
/// is making is not "what is biggest" — the rings already answer that — but
/// "what can I afford to lose". A 6 GB build folder and a 6 GB photo library
/// are the same bar on a chart and completely different choices.
struct CleanupView: View {
    let model: ScanModel

    var body: some View {
        Group {
            if let report = model.junkReport {
                if report.findings.isEmpty {
                    ContentUnavailableView(
                        "Rien à récupérer", systemImage: "sparkles",
                        description: Text("Aucun cache ni artefact connu dans ce dossier.")
                    )
                } else {
                    content(report)
                }
            } else {
                ContentUnavailableView(
                    "Analyse en attente", systemImage: "wand.and.sparkles",
                    description: Text("Lancez un scan pour repérer les fichiers récupérables.")
                )
            }
        }
    }

    private func content(_ report: JunkReport) -> some View {
        VStack(spacing: 0) {
            Summary(model: model, report: report)
            Divider()
            List {
                ForEach(report.populatedCategories) { category in
                    Section {
                        ForEach(report.findings(in: category.id)) { finding in
                            FindingRow(
                                finding: finding,
                                isChecked: model.junkSelection.contains(finding.node),
                                toggle: { model.toggleJunk(finding.node) }
                            )
                        }
                    } header: {
                        CategoryHeader(
                            category: category,
                            findings: report.findings(in: category.id),
                            model: model
                        )
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

// MARK: - Summary

private struct Summary: View {
    let model: ScanModel
    let report: JunkReport

    private var selectedBytes: Int64 {
        report.findings
            .filter { model.junkSelection.contains($0.node) }
            .reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(report.totalBytes))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("repérés sur \(Format.count(report.findings.count)) éléments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(Format.bytes(safeBytes))
                    .font(.system(size: 15, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                Text("sans risque")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.junkSelection.isEmpty {
                Text(Format.bytes(selectedBytes))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            Button("Tout ce qui est sûr") { model.selectSafeJunk() }
            Button(role: .destructive) {
                model.requestJunkDeletion()
            } label: {
                Label("Mettre à la corbeille", systemImage: "trash")
            }
            .disabled(model.junkSelection.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var safeBytes: Int64 {
        report.findings.filter { $0.safety == .safe }.reduce(0) { $0 + $1.bytes }
    }
}

// MARK: - Rows

private struct CategoryHeader: View {
    let category: JunkCategory
    let findings: [JunkFinding]
    let model: ScanModel

    var body: some View {
        HStack {
            Label(category.title, systemImage: category.symbol)
            Text("·").foregroundStyle(.tertiary)
            Text(Format.bytes(findings.reduce(0) { $0 + $1.bytes }))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Tout") {
                model.selectJunk(findings.map(\.node))
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

private struct FindingRow: View {
    let finding: JunkFinding
    let isChecked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in toggle() }))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if finding.safety == .caution {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let recovery = finding.recovery {
                    Text(recovery)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help(shortPath)

            Spacer(minLength: 10)

            Text(Format.bytes(finding.bytes))
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }

    private var folderName: String {
        (finding.path as NSString).lastPathComponent
    }

    /// Prefer naming the thing itself — "Spotify", "iPhone 17 Pro" — and demote
    /// the rule to the subtitle. Which cache it is matters less than whose.
    ///
    /// Nothing here is guessed. Either the system resolves a bundle identifier
    /// to an installed app, or the folder's own name is shown verbatim: a cache
    /// directory called `Firefox` is already telling us what it is, and the
    /// generic rule title was simply hiding it.
    private var headline: String {
        if let resolved = AppNames.shared.friendlyName(
            for: folderName, path: finding.path
        ) { return resolved }
        return finding.subject ?? finding.title
    }

    private var subtitle: String {
        headline == finding.title ? shortPath : "\(finding.title) · \(shortPath)"
    }

    private var shortPath: String {
        finding.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
