import AppKit
import SwiftUI

struct SidebarView: View {
    let model: ScanModel
    @State private var volumes: [VolumeInfo] = []
    @Bindable private var preferences = Preferences.shared
    private let locations = QuickLocation.standard()

    var body: some View {
        List {
            Section("Volumes") {
                ForEach(volumes) { volume in
                    row(path: volume.url.path, name: volume.name) {
                        VolumeRow(volume: volume)
                    }
                }
            }

            Section {
                ForEach(locations) { location in
                    row(path: location.path, name: location.name) {
                        Label(location.name, systemImage: location.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Added folders sit with the standard ones: to the user they
                // are the same kind of thing, only one set happens to be
                // removable.
                ForEach(preferences.customLocations, id: \.self) { path in
                    row(path: path, name: QuickLocation.displayName(of: path)) {
                        Label(QuickLocation.displayName(of: path), systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } menuItems: {
                        Divider()
                        Button("Retirer de la liste") {
                            preferences.removeLocation(path)
                            // Leaving the selection on a row that no longer
                            // exists would strand the window on it.
                            if model.selectedRoot == path,
                               let fallback = volumes.first {
                                model.select(
                                    path: model.rootPath ?? fallback.url.path,
                                    name: fallback.name
                                )
                            }
                        }
                        Button("Afficher dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)]
                            )
                        }
                    }
                }
            } header: {
                HStack(spacing: 0) {
                    Text("Emplacements")
                    Spacer(minLength: 4)
                    // Sized and coloured off the header itself, not left at the
                    // body default — an oversized glyph beside small grey caps
                    // reads as a stray control rather than part of the heading.
                    Button(action: addFolder) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    // Inset to sit off the edge by about what the title is
                    // inset on the left, so the header reads as one line rather
                    // than a title with something pinned to the window edge.
                    .padding(.trailing, 8)
                    .help("Ajouter un dossier à la liste")
                }
            }

            Section("Outils") {
                row(isSelected: model.showsApps, action: model.showApps) {
                    Label {
                        Text("Applications")
                    } icon: {
                        if let icon = Self.applicationsIcon {
                            Image(nsImage: icon)
                                .renderingMode(.template)
                                .resizable()
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app.badge")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                row(isSelected: model.showsCleanup, action: model.showCleanup) {
                    Label("Nettoyage", systemImage: "wand.and.sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                row(isSelected: model.showsReboot, action: model.showReboot) {
                    Label("Redémarrage", systemImage: "restart.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.sidebar)
        .task {
            refreshVolumes()
            // Open pointing at the boot volume, without scanning it. Starting a
            // multi-minute walk of the whole disk because someone opened the
            // app is not a decision to make on their behalf.
            if model.selectedRoot == nil, let first = volumes.first {
                model.select(path: first.url.path, name: first.name)
            }
            // The gauges must track what other apps do to the disk, and no
            // notification covers "some process wrote or freed bytes" — so a
            // slow poll, tied to the view's lifetime.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                refreshVolumes()
            }
        }
        // Freeing space in the app should move the gauge now, not within 30 s.
        .onChange(of: model.deletionEpoch) { refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didMountNotification
        )) { _ in refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didUnmountNotification
        )) { _ in refreshVolumes() }
    }

    private func refreshVolumes() {
        volumes = Volumes.mounted()
    }

    /// The glyph the Finder itself puts beside Applications in its sidebar.
    ///
    /// `NSWorkspace.icon(forFile: "/Applications")` gives the full-colour
    /// folder, which shouts next to rows drawn in a single tint. The artwork
    /// ships black, so it has to be marked as a template — otherwise it
    /// disappears into a dark sidebar. Nil on a system that has moved it,
    /// and the row falls back to a symbol.
    private static let applicationsIcon: NSImage? = {
        let icon = NSImage(contentsOfFile: "/System/Library/CoreServices"
            + "/CoreTypes.bundle/Contents/Resources/SidebarApplicationsFolder.icns")
        icon?.isTemplate = true
        return icon
    }()

    /// One selectable row.
    ///
    /// The highlight is drawn here rather than left to `List(selection:)`: a
    /// sidebar selection is painted with the accent colour, which shouts for
    /// something that is permanently on screen. `.tint` does not reach it —
    /// tried, and the selection stayed blue — so the background is ours. This
    /// is the system token for a selection that is present without claiming
    /// attention, the same grey the Finder's sidebar uses.
    private func row<Content: View>(
        isSelected: Bool, action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                          ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                          : .clear)
            }
            .contentShape(.rect)
            .onTapGesture(perform: action)
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }

    /// A row that stands for a place. While a tool holds the window, no place
    /// is what is on screen, so none of them gets the highlight.
    ///
    /// The context menu is attached here rather than at the call sites: every
    /// place carries the default-view submenu, and stacking a second
    /// `.contextMenu` outside would replace this one rather than merge.
    private func row<Content: View, MenuItems: View>(
        path: String, name: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        row(
            isSelected: model.selectedRoot == path
                && ScanModel.Presentation.browsing.contains(model.presentation),
            // Selects, never scans: reading a whole volume is a decision, not
            // a side effect of pointing at it.
            action: { model.select(path: path, name: name) },
            content: content
        )
        .contextMenu {
            defaultViewMenu(for: path)
            menuItems()
        }
    }

    /// Rows with nothing beyond the shared menu.
    private func row<Content: View>(
        path: String, name: String, @ViewBuilder content: () -> Content
    ) -> some View {
        row(path: path, name: name, content: content, menuItems: { EmptyView() })
    }

    /// The "default view" submenu every place row carries. Toggles rather than
    /// a Picker: menus render them as checkmark items, and a Picker cannot hold
    /// the divider that separates the four views from "follow the global
    /// setting".
    @ViewBuilder
    private func defaultViewMenu(for path: String) -> some View {
        Menu("Vue par défaut") {
            ForEach(ScanModel.Presentation.browsing) { mode in
                Toggle(mode.label, isOn: Binding(
                    get: { preferences.presentation(for: path) == mode },
                    set: { _ in
                        preferences.setPresentation(mode, for: path)
                        // Seeing the change at once beats waiting for the next
                        // selection — but only when this row is on screen.
                        if model.selectedRoot == path { model.presentation = mode }
                    }
                ))
            }
            Divider()
            Toggle("Globale", isOn: Binding(
                get: { preferences.presentation(for: path) == nil },
                set: { _ in preferences.setPresentation(nil, for: path) }
            ))
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ajouter"
        panel.message = "Choisissez un dossier à garder dans la liste."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.addLocation(url.path)
        model.select(path: url.path, name: QuickLocation.displayName(of: url.path))
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(volume.name, systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
                .lineLimit(1)

            CapacityBar(fraction: volume.usedFraction)
                .frame(height: 4)

            Text("\(Format.bytes(volume.availableBytes)) libres sur \(Format.bytes(volume.totalBytes))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct CapacityBar: View {
    let fraction: Double

    /// Turns amber then red as the disk fills — the one place in the app where
    /// colour carries meaning rather than identity.
    ///
    /// Explicitly blue rather than the accent colour: the sidebar now retints
    /// itself grey for the selection, and a gauge whose "everything is fine"
    /// state is grey says nothing at all.
    private var tint: Color {
        switch fraction {
        case ..<0.75: .blue
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
    }
}
