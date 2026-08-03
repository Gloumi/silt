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
                    }
                    .contextMenu {
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
        }
        .listStyle(.sidebar)
        .task {
            volumes = Volumes.mounted()
            // Open pointing at the boot volume, without scanning it. Starting a
            // multi-minute walk of the whole disk because someone opened the
            // app is not a decision to make on their behalf.
            if model.selectedRoot == nil, let first = volumes.first {
                model.select(path: first.url.path, name: first.name)
            }
        }
    }

    /// One selectable row.
    ///
    /// The highlight is drawn here rather than left to `List(selection:)`: a
    /// sidebar selection is painted with the accent colour, which shouts for
    /// something that is permanently on screen. `.tint` does not reach it —
    /// tried, and the selection stayed blue — so the background is ours. This
    /// is the system token for a selection that is present without claiming
    /// attention, the same grey the Finder's sidebar uses.
    private func row<Content: View>(
        path: String, name: String, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.selectedRoot == path
                          ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                          : .clear)
            }
            .contentShape(.rect)
            // Selects, never scans: reading a whole volume is a decision, not
            // a side effect of pointing at it.
            .onTapGesture { model.select(path: path, name: name) }
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
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
