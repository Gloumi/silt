import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct StrataApp: App {
    @State private var model = ScanModel()

    var body: some Scene {
        Window("Strata", id: "main") {
            ContentView(model: model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Analyser un dossier…") { chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Remonter d'un niveau") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.trail.count <= 1)
                Divider()
                Toggle("Taille logique", isOn: Binding(
                    get: { model.useLogicalSize },
                    set: { model.useLogicalSize = $0 }
                ))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyser"
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(path: url.path)
        }
    }
}

struct ContentView: View {
    let model: ScanModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            BrowserView(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.goUp()
                } label: {
                    Label("Remonter", systemImage: "chevron.up")
                }
                .disabled(model.trail.count <= 1)
            }
            ToolbarItem {
                Picker("Vue", selection: Binding(
                    get: { model.presentation },
                    set: { model.presentation = $0 }
                )) {
                    ForEach(ScanModel.Presentation.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Picker("Taille", selection: Binding(
                    get: { model.useLogicalSize },
                    set: { model.useLogicalSize = $0 }
                )) {
                    Text("Sur le disque").tag(false)
                    Text("Logique").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Taille réellement occupée, ou taille logique du contenu.")
            }
        }
        // Dropping a folder on the window is the fastest way to start a scan.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.scan(path: url.path) }
            }
            return true
        }
    }
}
