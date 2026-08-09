import AppKit
import DiskCore
import SwiftUI

/// Folders and files with byte-identical content under the current folder,
/// resolved one group at a time.
///
/// Whole folders come first, and the file copies they cover disappear into
/// them: a photo library duplicated onto the Desktop is one decision, not two
/// hundred.
///
/// Master/detail rather than one long list: the left column names the groups
/// (sorted by what cleaning them returns), the right side spreads the chosen
/// group out as cards with a thumbnail — for photos and videos the picture
/// *is* the decision. Each group carries one marked survivor ("Conservée",
/// the newest copy until the user says otherwise); the trash button sends the
/// rest through the usual confirmation sheet, and the group leaves the list.
///
/// A click selects a card for the inspector, space previews it — marking and
/// looking are two different gestures on purpose; the first version merged
/// them and inspecting anything became impossible. Everything drawn here
/// comes from `model.duplicateDisplay`, rebuilt only when its key moves — the
/// first version rebuilt paths on every render and crawled.
struct DuplicatesView: View {
    let model: ScanModel
    let store: NodeStore

    /// Digest of the group open on the right. Falls back to the first group
    /// when the pointed-at one gets cleaned away or the scope changes.
    @State private var focused: [UInt8]?

    /// Which pane the arrow keys drive: → from the list steps into the
    /// cards, ← from the first card steps back out.
    private enum Pane: Hashable { case list, cards }
    @FocusState private var pane: Pane?

    var body: some View {
        content
            .task(id: model.duplicatesKey) { model.ensureDuplicates() }
            .task(id: model.duplicateDisplayKey) { model.rebuildDuplicateDisplay() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            // Hashing a tree still being discovered would compare files that
            // are about to change; the key moves again when the scan settles.
            VStack(spacing: 10) {
                ProgressView()
                Text("L'analyse doit d'abord se terminer.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.duplicatesPhase {
            case .running:
                running
            case .cancelled:
                ContentUnavailableView {
                    Label("Recherche annulée", systemImage: "doc.on.doc")
                } description: {
                    Text("Rien n'a été conservé de la comparaison interrompue.")
                } actions: {
                    Button("Relancer") { model.ensureDuplicates() }
                }
            case .ready:
                ready
            case .idle:
                // The `.task` above is about to flip this to `.running`.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Recherche des doublons…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Hashing in progress

    /// Determinate as soon as the byte total is known: a whole-disk pass can
    /// read tens of gigabytes, and a spinner over that would be a lie of
    /// omission. Annuler is load-bearing here, not decoration.
    private var running: some View {
        VStack(spacing: 10) {
            progressBody(model.duplicatesProgress)
            Button("Annuler") { model.cancelDuplicates() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func progressBody(
        _ progress: DuplicateFinder.Progress?
    ) -> some View {
        if let progress, progress.stage == .folderScan {
            // Reading folders is bound by syscalls per entry, not by bytes, so
            // a byte bar here would sit at zero through the longest part of
            // the pass. Count what is actually being done instead.
            ProgressView()
            Text(stageLabel(progress.stage))
                .foregroundStyle(.secondary)
            Text("\(Format.count(progress.filesHashed)) éléments lus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if let progress, progress.stage != .collecting,
                  progress.bytesToHash > 0 {
            ProgressView(
                value: Double(progress.bytesHashed),
                total: Double(progress.bytesToHash)
            )
            .frame(maxWidth: 280)
            Text(stageLabel(progress.stage))
                .foregroundStyle(.secondary)
            Text("\(Format.bytes(progress.bytesHashed)) sur \(Format.bytes(progress.bytesToHash)) · \(Format.count(progress.filesHashed)) fichiers sur \(Format.count(progress.filesToHash))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            ProgressView()
            Text("Recherche des candidats…")
                .foregroundStyle(.secondary)
        }
    }

    private func stageLabel(_ stage: DuplicateFinder.Progress.Stage) -> String {
        switch stage {
        case .collecting: "Recherche des candidats…"
        case .folderScan: "Lecture des dossiers candidats…"
        case .folderCompare: "Comparaison des dossiers…"
        case .prefixPass: "Lecture des débuts de fichiers…"
        case .fullPass: "Comparaison du contenu…"
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var ready: some View {
        let groups = model.duplicateDisplay
        if groups.isEmpty, model.isFiltering {
            ContentUnavailableView {
                Label("Aucun doublon ne correspond", systemImage: "doc.on.doc")
            } description: {
                Text("Rien ne correspond à « \(model.searchText) » ici.")
            } actions: {
                Button("Effacer la recherche") { model.searchText = "" }
            }
        } else if groups.isEmpty {
            ContentUnavailableView {
                Label("Aucun doublon", systemImage: "doc.on.doc")
            } description: {
                Text("Aucun fichier d'au moins \(Preferences.shared.duplicateThreshold.label), ni aucun dossier d'au moins \(Preferences.shared.duplicateFolderThreshold.label), n'existe ici en plusieurs exemplaires. Les deux seuils se règlent dans les Réglages.")
            }
        } else {
            loaded(groups)
        }
    }

    private func loaded(_ groups: [ScanModel.DuplicateGroupDisplay]) -> some View {
        VStack(spacing: 0) {
            summary(groups)
            Divider()
            HStack(spacing: 0) {
                masterList(groups)
                    .frame(width: 270)
                Divider()
                detail(for: focusedGroup(in: groups), groups: groups)
            }
        }
        // When the group under the cursor disappears — cleaned, filtered,
        // undone — land on its neighbour, not back at the top of the list.
        .onChange(of: groups) { old, new in
            guard let focused, !new.contains(where: { $0.id == focused }),
                  let oldIndex = old.firstIndex(where: { $0.id == focused })
            else { return }
            self.focused = new.isEmpty
                ? nil : new[min(oldIndex, new.count - 1)].id
        }
        .onAppear { if pane == nil { pane = .list } }
        // ⌘⏎ from anywhere in the view: straight to the recap. The button it
        // mirrors is disabled with nothing marked, so this guards the same.
        .background {
            Button("") { model.requestMarkedDuplicatesDeletion() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
        }
    }

    private func focusedGroup(
        in groups: [ScanModel.DuplicateGroupDisplay]
    ) -> ScanModel.DuplicateGroupDisplay? {
        groups.first { $0.id == focused } ?? groups.first
    }

    /// "Estimation haute" is not hedging, it is the truth of the measure: APFS
    /// clones share their space invisibly, so some of these bytes may already
    /// be counted once. Said more loudly when folders are in the list —
    /// duplicating a folder in the Finder is *how* clones get made, so the gap
    /// between promised and freed is widest exactly there.
    private func summaryLine(
        _ groups: [ScanModel.DuplicateGroupDisplay], copies: Int
    ) -> String {
        let folders = groups.count { $0.isFolder }
        let head = folders == 0
            ? "dans \(Format.count(groups.count)) groupes · \(Format.count(copies)) copies"
            : folders == 1
                ? "dans 1 groupe de dossiers et \(Format.count(groups.count - folders)) groupes de fichiers · \(Format.count(copies)) copies"
                : "dans \(Format.count(folders)) groupes de dossiers et \(Format.count(groups.count - folders)) groupes de fichiers · \(Format.count(copies)) copies"
        return folders == 0
            ? "\(head) · estimation haute, les clones APFS partagent déjà leur espace"
            : "\(head) · estimation haute : un dossier dupliqué dans le Finder est un clone APFS, dont l'espace est déjà partagé"
    }

    private func summary(_ groups: [ScanModel.DuplicateGroupDisplay]) -> some View {
        let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        let copies = groups.reduce(0) { $0 + $1.copyCount }

        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("jusqu'à \(Format.bytes(reclaimable))")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                // "Estimation haute" is not hedging, it is the truth of the
                // measure: APFS clones share their space invisibly, so some
                // of these bytes may already be counted once.
                Text(summaryLine(groups, copies: copies))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dropped = model.duplicates?.droppedCount, dropped > 0 {
                    Text(dropped == 1
                         ? "1 élément ignoré (modifié ou illisible depuis l'analyse)"
                         : "\(Format.count(dropped)) éléments ignorés (modifiés ou illisibles depuis l'analyse)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Only offered when it changes something on screen — but its
                // label then says how many groups it is holding back, so the
                // control explains its own existence.
                if model.duplicatesHiddenGroupCount > 0 || model.duplicatesShowManaged {
                    Toggle(isOn: Bindable(model).duplicatesShowManaged) {
                        Text(model.duplicatesShowManaged || model.duplicatesHiddenGroupCount == 0
                             ? "Inclure les copies gérées par les apps et les outils"
                             : model.duplicatesHiddenGroupCount == 1
                                 ? "Inclure les copies gérées par les apps et les outils (1 groupe masqué)"
                                 : "Inclure les copies gérées par les apps et les outils (\(model.duplicatesHiddenGroupCount) groupes masqués)")
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Presse-papiers, caches, conteneurs et dossiers de build (.next…) gardent parfois la copie d'un fichier. Ces groupes-là sont masqués par défaut : les résoudre relève de l'application ou de l'outil plus que de vous.")
                }
            }

            Spacer(minLength: 12)

            // The basket total sits *under* its buttons rather than beside
            // them: on the same line it competed with the headline figure on
            // the left, and two large numbers at opposite ends of one row
            // read as a comparison they are not.
            let marked = model.duplicateMarkedStats
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    if marked.groups > 0 {
                        Button("Tout démarquer") { model.unmarkAllDuplicateGroups() }
                    }
                    if marked.groups < groups.count {
                        Button("Tout marquer") { model.markAllDuplicateGroups() }
                            .help("Marque chaque groupe pour suppression, en gardant sa copie « Conservée ». Rien n'est supprimé avant le récapitulatif.")
                    }
                    Button(role: .destructive) {
                        model.requestMarkedDuplicatesDeletion()
                    } label: {
                        Label("Supprimer…", systemImage: "trash")
                    }
                    .disabled(marked.groups == 0)
                    .help("Récapitule tout ce que les groupes marqués enverraient à la corbeille, puis supprime en une fois — restaurable ensuite (⌘⏎).")
                }
                if marked.groups > 0 {
                    Text(marked.groups == 1
                         ? "1 groupe marqué · \(Format.bytes(marked.bytes))"
                         : "\(Format.count(marked.groups)) groupes marqués · \(Format.bytes(marked.bytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Master list

    private func masterList(_ groups: [ScanModel.DuplicateGroupDisplay]) -> some View {
        List(groups, selection: Binding(
            get: { focusedGroup(in: groups)?.id },
            set: { focused = $0 }
        )) { group in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if group.isFolder {
                            Text("dossier")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                                .foregroundStyle(.secondary)
                                .help("Dossier entièrement identique, contenu vérifié fichier par fichier. Les fichiers qu'il contient ne sont plus listés séparément.")
                        }
                        Text(group.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(group.isFolder
                         ? "\(Format.count(group.copyCount)) dossiers · \(Format.bytes(group.eachBytes)) · \(Format.bytes(group.reclaimableBytes)) récupérables"
                         : "\(Format.count(group.copyCount)) copies · \(Format.bytes(group.eachBytes)) · \(Format.bytes(group.reclaimableBytes)) récupérables")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.isDuplicateMarked(group.id) {
                    Image(systemName: "trash.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Marqué pour suppression")
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
        .focused($pane, equals: .list)
        .onKeyPress(.rightArrow) {
            enterCards(in: groups)
            return .handled
        }
        // ⏎ and ⌫ both mark: return because marking is *the* action of the
        // list, delete because a promise to the trash deserves the key the
        // trash already owns. Both toggle; only marking advances.
        .onKeyPress(.return) {
            toggleMarkFocused(in: groups)
            return .handled
        }
        .onKeyPress(.deleteForward) {
            toggleMarkFocused(in: groups)
            return .handled
        }
        .onKeyPress(KeyEquivalent("\u{7F}")) {
            toggleMarkFocused(in: groups)
            return .handled
        }
    }

    private func toggleMarkFocused(in groups: [ScanModel.DuplicateGroupDisplay]) {
        guard let group = focusedGroup(in: groups) else { return }
        let wasMarked = model.isDuplicateMarked(group.id)
        model.toggleDuplicateMark(group.id)
        if !wasMarked { advance(from: group, in: groups) }
    }

    /// → from the list: focus the cards, standing on the kept copy unless a
    /// card of this group is already selected.
    private func enterCards(in groups: [ScanModel.DuplicateGroupDisplay]) {
        guard let group = focusedGroup(in: groups) else { return }
        if !group.copies.contains(where: { model.selection.contains($0.id) }) {
            selectKeeper(of: group)
        }
        pane = .cards
    }

    /// The kept copy is the group's representative: identical content, and
    /// the file that will still exist afterwards.
    private func selectKeeper(of group: ScanModel.DuplicateGroupDisplay) {
        let keeper = model.duplicateKeeper(for: group)
        if let kept = group.copies.first(where: { $0.identity == keeper })
            ?? group.copies.first {
            model.selection = [kept.id]
        }
    }

    // MARK: - Group detail

    @ViewBuilder
    private func detail(
        for group: ScanModel.DuplicateGroupDisplay?,
        groups: [ScanModel.DuplicateGroupDisplay]
    ) -> some View {
        if let group {
            let keeper = model.duplicateKeeper(for: group)
            VStack(spacing: 0) {
                detailHeader(group, keeper: keeper, groups: groups)
                Divider()
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                        alignment: .leading, spacing: 12
                    ) {
                        ForEach(group.copies) { copy in
                            CopyCard(
                                model: model,
                                copy: copy,
                                isKept: copy.identity == keeper,
                                isSelected: model.selection.contains(copy.id),
                                onSelect: {
                                    model.selection = [copy.id]
                                    pane = .cards
                                },
                                onKeep: {
                                    model.setDuplicateKeeper(
                                        copy.identity, for: group.id
                                    )
                                }
                            )
                        }
                    }
                    .padding(14)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($pane, equals: .cards)
                .onKeyPress(.leftArrow) { moveCardSelection(-1, in: group) }
                .onKeyPress(.rightArrow) { moveCardSelection(+1, in: group) }
                // ⏎ crowns the selected card; ⌫ marks the group and hands
                // back to the list — the "decided, next" gesture.
                .onKeyPress(.return) {
                    keepSelected(in: group)
                    return .handled
                }
                .onKeyPress(KeyEquivalent("\u{7F}")) {
                    markFromCards(group, in: groups)
                    return .handled
                }
                .onKeyPress(.deleteForward) {
                    markFromCards(group, in: groups)
                    return .handled
                }
            }
            .frame(maxWidth: .infinity)
            // Landing on a group selects its kept copy, so the inspector and
            // space's Quick Look always describe the group on screen — never
            // whatever was clicked three groups ago.
            .onChange(of: group.id, initial: true) { _, _ in
                if !group.copies.contains(where: { model.selection.contains($0.id) }) {
                    selectKeeper(of: group)
                }
            }
        }
    }

    private func keepSelected(in group: ScanModel.DuplicateGroupDisplay) {
        guard let copy = group.copies.first(where: {
            model.selection.contains($0.id)
        }) else { return }
        model.setDuplicateKeeper(copy.identity, for: group.id)
    }

    private func markFromCards(
        _ group: ScanModel.DuplicateGroupDisplay,
        in groups: [ScanModel.DuplicateGroupDisplay]
    ) {
        let wasMarked = model.isDuplicateMarked(group.id)
        model.toggleDuplicateMark(group.id)
        if !wasMarked {
            pane = .list
            advance(from: group, in: groups)
        }
    }

    /// ←/→ between the cards; ← past the first hands focus back to the list.
    private func moveCardSelection(
        _ delta: Int, in group: ScanModel.DuplicateGroupDisplay
    ) -> KeyPress.Result {
        let copies = group.copies
        guard let current = copies.firstIndex(where: {
            model.selection.contains($0.id)
        }) else {
            selectKeeper(of: group)
            return .handled
        }
        let next = current + delta
        if next < 0 {
            pane = .list
            return .handled
        }
        if copies.indices.contains(next) {
            model.selection = [copies[next].id]
        }
        return .handled
    }

    private func detailHeader(
        _ group: ScanModel.DuplicateGroupDisplay,
        keeper: ScanModel.CopyIdentity?,
        groups: [ScanModel.DuplicateGroupDisplay]
    ) -> some View {
        let others = group.copies.count { $0.identity != keeper }
        let freed = keeper.map { group.freedBytes(keeping: $0) } ?? 0
        let isMarked = model.isDuplicateMarked(group.id)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(group.isFolder
                     ? "\(Format.count(group.copyCount)) dossiers · \(Format.bytes(group.eachBytes)) chacun · \(Format.count(group.fileCount)) fichiers · estimation haute"
                     : "\(Format.count(group.copyCount)) copies · \(Format.bytes(group.eachBytes)) chacune")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(group.isFolder
                          ? "Dupliquer un dossier dans le Finder (⌘D) crée des clones APFS, qui partagent leur espace sans que rien ne le signale : le gain annoncé est un maximum, souvent supérieur à ce qui sera réellement libéré."
                          : "")
            }
            Spacer()
            if isMarked {
                Button("Ne plus marquer") {
                    model.toggleDuplicateMark(group.id)
                }
            } else {
                // Marking, not deleting: the gesture stays cheap, hops to the
                // next group by itself, and the batch is confirmed once from
                // the bar — triage, not paperwork.
                Button {
                    model.toggleDuplicateMark(group.id)
                    advance(from: group, in: groups)
                } label: {
                    Label(
                        others == 1
                            ? (group.isFolder
                               ? "Marquer : l'autre dossier · \(Format.bytes(freed))"
                               : "Marquer : l'autre copie · \(Format.bytes(freed))")
                            : (group.isFolder
                               ? "Marquer : les \(others) autres dossiers · \(Format.bytes(freed))"
                               : "Marquer : les \(others) autres copies · \(Format.bytes(freed))"),
                        systemImage: "trash.circle"
                    )
                }
                .help("Promet ces copies à la corbeille et passe au groupe suivant (⏎ ou ⌫). Rien n'est supprimé avant « Supprimer… ».")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// After marking, land on the next unmarked group — the one the triage
    /// naturally continues with — or stay put at the end of the list.
    private func advance(
        from group: ScanModel.DuplicateGroupDisplay,
        in groups: [ScanModel.DuplicateGroupDisplay]
    ) {
        guard let index = groups.firstIndex(where: { $0.id == group.id })
        else { return }
        let following = groups[(index + 1)...] + groups[..<index]
        if let next = following.first(where: { !model.isDuplicateMarked($0.id) }) {
            focused = next.id
        }
    }
}

// MARK: - Cards

/// One copy, thumbnail first: where it sits and when it last moved are the
/// whole decision, so they get the caption; its size does not — every card of
/// a group weighs the same and the header says how much.
private struct CopyCard: View {
    let model: ScanModel
    let copy: ScanModel.DuplicateCopy
    let isKept: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FileThumbnail(
                path: copy.path, isDirectory: copy.isDirectory,
                isPackage: copy.isPackage, fallbackPadding: 20
            )
            .frame(maxWidth: .infinity)
            .frame(height: 110)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(copy.relativeFolder ?? "ici")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if copy.isHardlinked {
                        Text("lien dur")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                            .foregroundStyle(.secondary)
                            .help("Ces chemins partagent le même espace disque : en supprimer un ne libère rien.")
                    }
                    if copy.isManaged {
                        Text(copy.managedBy.map {
                            $0.hasPrefix(".") ? "dans \($0)" : "interne à \($0)"
                        } ?? "copie gérée")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                            .foregroundStyle(.orange)
                            .help("Fichier qu'une application ou un outil garde pour lui (presse-papiers, cache, dossier de build). Jamais choisi comme copie à conserver ; le supprimer peut perturber l'application, ou sera simplement régénéré.")
                    }
                }
                if let age = Format.age(unixSeconds: copy.modTime) {
                    Text(age)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(Format.exactDate(unixSeconds: copy.modTime) ?? "")
                }
            }

            // A fixed slot either way, so choosing a keeper never reflows the
            // grid under the pointer.
            if isKept {
                Label("Conservée", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(height: 20)
            } else {
                Button("Garder celle-ci", action: onKeep)
                    .controlSize(.small)
                    .frame(height: 20)
            }
        }
        .padding(10)
        .background(.quinary, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isSelected ? Color.accentColor : .clear, lineWidth: 2
                )
        }
        .contentShape(.rect)
        // Selecting, not marking: the inspector follows, space previews, and
        // the arrow keys pick up from here.
        .onTapGesture(perform: onSelect)
        .help(copy.path)
        .contextMenu {
            // A folder card is shown *selected in its parent*: opening it
            // would replace the list being worked in with its contents, which
            // answers a question nobody asked.
            Button("Voir dans l'arborescence") {
                model.reveal(copy.id, selectingInParent: copy.isDirectory)
            }
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: copy.path)]
                )
            }
            Button("Aperçu rapide") {
                QuickLookPanel.shared.show([URL(fileURLWithPath: copy.path)])
            }
            Divider()
            Button("Mettre à la corbeille", role: .destructive) {
                model.selection = [copy.id]
                model.requestDeletion()
            }
        }
    }
}

