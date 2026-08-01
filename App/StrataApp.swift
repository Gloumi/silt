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
                Button("Mettre à la corbeille") { model.requestDeletion() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
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
    @State private var showsInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            BrowserView(model: model)
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .sheet(item: Bindable(model).deletionPlanBox) { box in
            DeletionSheet(
                plan: box.plan,
                onCancel: { model.deletionPlan = nil },
                onConfirm: { Task { await model.confirmDeletion() } }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.deletionMessage {
                DeletionBanner(
                    message: message,
                    canUndo: model.lastDeletion != nil,
                    onUndo: { Task { await model.undoLastDeletion() } },
                    onDismiss: { model.dismissDeletionMessage() }
                )
            }
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
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspecteur", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            ToolbarItem {
                Picker("Vue", selection: Binding(
                    get: { model.presentation },
                    set: { model.presentation = $0 }
                )) {
                    ForEach(ScanModel.Presentation.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol)
                            .help(mode.hint)
                            .tag(mode)
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


/// Confirmation of what just happened, with the way back.
///
/// Shown after the fact rather than as an alert: the deletion is already
/// reversible, so interrupting the user again would be ceremony without value.
private struct DeletionBanner: View {
    let message: String
    let canUndo: Bool
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
            Spacer(minLength: 8)
            if canUndo {
                Button("Annuler", action: onUndo)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35), value: message)
    }
}
