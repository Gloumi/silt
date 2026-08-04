import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SiltApp: App {
    @State private var model = ScanModel()

    var body: some Scene {
        Window("Silt", id: "main") {
            ContentView(model: model)
                // NSApp exists by the time a window appears, which it does not
                // when Preferences is first constructed.
                .task { Preferences.shared.applyAppearance() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings { SettingsView() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Analyser un dossier…") { chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Accès complet au disque…") { model.showsWelcome = true }
                Divider()
                Link("Code source", destination: URL(string: "https://github.com/")!)
            }
            CommandGroup(after: .toolbar) {
                // ⌘R is already the inspector's "Afficher dans le Finder".
                Button("Actualiser l'analyse") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canRescan)
                Button("Remonter d'un niveau") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model.trail.count <= 1)
                Button("Aperçu rapide") { model.togglePreview() }
                    .keyboardShortcut(.space, modifiers: [])
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
    /// Owned here rather than by ScanModel: the reboot measurement has
    /// nothing to do with the scan lifecycle and survives all its resets.
    @State private var reboot = RebootModel()
    /// Token for the space-key monitor, held so reopening the window never
    /// installs a second one — two monitors would toggle the preview twice,
    /// which is to say not at all.
    @State private var spaceMonitor: Any?

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            BrowserView(model: model, reboot: reboot)
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .sheet(isPresented: Bindable(model).showsWelcome) {
            WelcomeSheet(
                unreadableCount: model.result?.unreadablePaths.count ?? 0
            ) {
                model.showsWelcome = false
                Preferences.shared.hasSeenWelcome = true
            }
        }
        .sheet(item: Bindable(model).previewURL) { url in
            QuickLookSheet(url: url) { model.previewURL = nil }
        }
        .sheet(item: Bindable(model).deletionPlanBox) { box in
            DeletionSheet(
                plan: box.plan,
                onCancel: { model.deletionPlan = nil },
                onConfirm: { Task { await model.confirmDeletion() } }
            )
        }
        .sheet(item: Bindable(model).uninstallPlan) { plan in
            UninstallSheet(
                model: model, plan: plan,
                onDismiss: { model.uninstallPlan = nil }
            )
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.deletionMessage {
                DeletionBanner(
                    message: message,
                    canUndo: model.lastDeletion != nil,
                    needsAppManagement: model.needsAppManagement,
                    onEmptyTrash: { Task { await model.emptyTrash() } },
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
        // Space is Quick Look everywhere on this platform, but the menu
        // command's key equivalent never fires: every list lives in an
        // NSScrollView, which swallows space as page-down before the menu is
        // consulted. A local monitor sees the event first.
        .onAppear {
            guard spaceMonitor == nil else { return }
            spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // The monitor already runs on the main thread; the hop is only
                // formal. A Bool crosses it where the non-Sendable event cannot.
                let consumed = MainActor.assumeIsolated { handleSpace(event) == nil }
                return consumed ? nil : event
            }
        }
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
    }

    /// Returns nil to consume the event, or the event to let it through.
    private func handleSpace(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49, // space
              event.modifierFlags
                  .intersection([.command, .shift, .option, .control]).isEmpty,
              let window = NSApp.keyWindow,
              !(window is NSPanel), // Open panel, Settings: not our keyboard
              !(window.firstResponder is NSTextView) // typing in a filter field
        else { return event }

        if window.isSheet {
            // One sheet at a time, so a non-nil preview URL means this sheet
            // *is* the Quick Look one: space closes it, like the Finder. Any
            // other sheet keeps its own keyboard handling.
            guard model.previewURL != nil else { return event }
            model.previewURL = nil
            return nil
        }

        // Only swallow the key when a preview actually toggles; otherwise the
        // scroll views keep their page-down.
        let before = model.previewURL
        model.togglePreview()
        return model.previewURL != before ? nil : event
    }
}


/// Confirmation of what just happened, with the way back.
///
/// Shown after the fact rather than as an alert: the deletion is already
/// reversible, so interrupting the user again would be ceremony without value.
private struct DeletionBanner: View {
    let message: String
    let canUndo: Bool
    let needsAppManagement: Bool
    let onEmptyTrash: () -> Void
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
            Spacer(minLength: 8)
            if needsAppManagement {
                Button("Ouvrir les Réglages") { AppManagement.openSettings() }
            }
            if canUndo {
                Button("Vider la corbeille", action: onEmptyTrash)
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


/// `sheet(item:)` needs identity; a file URL is its own.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
