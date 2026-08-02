import AppKit
import DiskCore
import SwiftUI

/// The list of things worth deleting, grouped by what they are.
///
/// Grouped by category rather than purely by size, because the decision the user
/// is making is not "what is biggest" — the rings already answer that — but
/// "what can I afford to lose". A 6 GB build folder and a 6 GB photo library are
/// the same bar on a chart and completely different choices.
///
/// Two levels, not one. A rule like `__pycache__` matches hundreds of times in a
/// single repository, and since a matched subtree is never descended into, each
/// one is its own finding. Flat, that buries everything else; folded by rule, it
/// is one line carrying a total.
struct CleanupView: View {
    let model: ScanModel

    @State private var collapsed: Set<String> = []
    @State private var expandedRules: Set<String> = []
    @State private var search = ""
    @State private var safeOnly = false
    @State private var sort: Sort = .category

    enum Sort: String, CaseIterable, Identifiable {
        case category, size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .category: "Par catégorie"
            case .size: "Par taille"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.junkScope != nil { ScopeBanner(model: model) }
            content
        }
        // The rule engine runs when this view is first shown rather than at the
        // end of every scan — it walks the whole tree, and that used to block
        // the main actor exactly when the visualisation was trying to appear.
        .task(id: model.scanID) { model.ensureJunkReport() }
    }

    @ViewBuilder
    private var content: some View {
        if let report = model.junkReport {
            if report.findings.isEmpty {
                ContentUnavailableView(
                    "Rien à récupérer", systemImage: "sparkles",
                    description: Text("Aucun cache ni artefact connu ici.")
                )
            } else {
                loaded(report)
            }
        } else if model.junkPhase == .running {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Recherche des fichiers récupérables…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Analyse en attente", systemImage: "wand.and.sparkles",
                description: Text("Lancez un scan pour repérer les fichiers récupérables.")
            )
        }
    }

    private func loaded(_ report: JunkReport) -> some View {
        let sections = self.sections(of: report)
        return VStack(spacing: 0) {
            Summary(
                model: model, report: report,
                sort: $sort, search: $search, safeOnly: $safeOnly,
                allCollapsed: collapsed.count >= sections.count,
                toggleAll: { toggleAll(sections.map(\.category.id)) }
            )
            Divider()

            if sections.isEmpty {
                ContentUnavailableView(
                    "Aucun résultat", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Aucune trouvaille ne correspond au filtre.")
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            if !collapsed.contains(section.category.id) {
                                rows(of: section)
                            }
                        } header: {
                            CategoryHeader(
                                section: section, model: model,
                                isCollapsed: collapsed.contains(section.category.id),
                                toggle: { toggle(section.category.id) }
                            )
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func rows(of section: CategorySection) -> some View {
        ForEach(section.groups) { group in
            // A rule that matched once needs no folder around it.
            if group.findings.count == 1, let finding = group.findings.first {
                FindingRow(model: model, finding: finding, indented: false)
            } else {
                RuleHeader(
                    group: group, model: model,
                    isExpanded: expandedRules.contains(group.id),
                    toggle: {
                        if expandedRules.contains(group.id) {
                            expandedRules.remove(group.id)
                        } else {
                            expandedRules.insert(group.id)
                        }
                    }
                )
                if expandedRules.contains(group.id) {
                    ForEach(group.findings) { finding in
                        FindingRow(model: model, finding: finding, indented: true)
                    }
                }
            }
        }
    }

    // MARK: - Grouping

    private func sections(of report: JunkReport) -> [CategorySection] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()

        var built: [CategorySection] = []
        for category in report.populatedCategories {
            let findings = report.findings(in: category.id).filter { finding in
                if safeOnly && finding.safety != .safe { return false }
                guard !needle.isEmpty else { return true }
                return finding.path.lowercased().contains(needle)
                    || finding.title.lowercased().contains(needle)
                    || (finding.subject?.lowercased().contains(needle) ?? false)
            }
            guard !findings.isEmpty else { continue }

            var byRule: [String: [JunkFinding]] = [:]
            for finding in findings { byRule[finding.ruleID, default: []].append(finding) }
            let groups = byRule.values
                .map { RuleGroup(findings: $0) }
                .sorted { $0.bytes > $1.bytes }
            built.append(CategorySection(category: category, groups: groups))
        }

        if sort == .size { built.sort { $0.bytes > $1.bytes } }
        return built
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func toggleAll(_ ids: [String]) {
        if collapsed.count >= ids.count { collapsed = [] } else { collapsed = Set(ids) }
    }
}

// MARK: - Model

private struct RuleGroup: Identifiable {
    let findings: [JunkFinding]

    var id: String { findings.first?.ruleID ?? "" }
    var title: String { findings.first?.title ?? "" }
    var safety: JunkSafety { findings.contains { $0.safety == .caution } ? .caution : .safe }
    var recovery: String? { findings.first?.recovery }
    var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
    var nodes: [Int32] { findings.map(\.node) }
}

private struct CategorySection: Identifiable {
    let category: JunkCategory
    let groups: [RuleGroup]

    var id: String { category.id }
    var bytes: Int64 { groups.reduce(0) { $0 + $1.bytes } }
    var count: Int { groups.reduce(0) { $0 + $1.findings.count } }
    var nodes: [Int32] { groups.flatMap(\.nodes) }
}

// MARK: - Scope

/// Shown when the list has been narrowed to one folder, because otherwise a
/// short list looks like a clean machine rather than a filtered view.
private struct ScopeBanner: View {
    let model: ScanModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").foregroundStyle(.secondary)
            Text("Résultats pour ")
                .foregroundStyle(.secondary)
                + Text(shortPath).fontWeight(.medium)
            Spacer()
            Button("Analyser tout le disque") { model.clearJunkScope() }
                .buttonStyle(.link)
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }

    private var shortPath: String {
        (model.junkScopePath ?? "")
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Summary

private struct Summary: View {
    let model: ScanModel
    let report: JunkReport
    @Binding var sort: CleanupView.Sort
    @Binding var search: String
    @Binding var safeOnly: Bool
    let allCollapsed: Bool
    let toggleAll: () -> Void

    private var selectedBytes: Int64 {
        report.findings
            .filter { model.junkSelection.contains($0.node) }
            .reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 9) {
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

            HStack(spacing: 10) {
                Picker("", selection: $sort) {
                    ForEach(CleanupView.Sort.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Toggle("Sûr uniquement", isOn: $safeOnly)
                    .toggleStyle(.checkbox)

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filtrer", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
                .frame(maxWidth: 260)

                Spacer()

                Button(allCollapsed ? "Tout déplier" : "Tout replier", action: toggleAll)
                    .buttonStyle(.link)
            }
            .font(.callout)
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
    let section: CategorySection
    let model: ScanModel
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Label(section.category.title, systemImage: section.category.symbol)
            Text("·").foregroundStyle(.tertiary)
            Text(Format.bytes(section.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("· \(Format.count(section.count))")
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Tout") { model.selectJunk(section.nodes) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }
}

/// One rule that matched several times, folded into a single line.
private struct RuleHeader: View {
    let group: RuleGroup
    let model: ScanModel
    let isExpanded: Bool
    let toggle: () -> Void

    private var checked: Bool {
        group.nodes.allSatisfy(model.junkSelection.contains)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { checked },
                set: { _ in model.selectJunk(group.nodes) }
            ))
            .labelsHidden()

            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.title).fontWeight(.medium).lineLimit(1)
                    if group.safety == .caution {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(Format.count(group.findings.count)) dossiers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 10)

            Text(Format.bytes(group.bytes))
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
    }
}

private struct FindingRow: View {
    let model: ScanModel
    let finding: JunkFinding
    let indented: Bool

    private var isChecked: Bool { model.junkSelection.contains(finding.node) }

    var body: some View {
        HStack(spacing: 10) {
            if indented { Spacer().frame(width: 22) }

            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { _ in model.toggleJunk(finding.node) }
            ))
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
                if let recovery = finding.recovery, !indented {
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
        .onTapGesture { model.toggleJunk(finding.node) }
        .contextMenu {
            Button("Voir dans l'arborescence") { model.reveal(finding.node) }
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: finding.path)]
                )
            }
        }
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
