import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SiltApp: App {
    @State private var model = ScanModel()
    /// Only here to put a Quick Look controller at the end of the responder
    /// chain; see QuickLookPanel.
    @NSApplicationDelegateAdaptor(QuickLookController.self) private var quickLook

    var body: some Scene {
        Window("Silt", id: "main") {
            ContentView(model: model)
                // NSApp exists by the time a window appears, which it does not
                // when Preferences is first constructed.
                .task { Preferences.shared.applyAppearance() }
                // Read once at launch so the sidebar can say straight away that
                // something is still waiting to be put back — the tool itself
                // may never be opened, and that count is the only hint.
                .task { await model.refreshRestorable() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings { SettingsView() }
        .commands {
            // Hiding the sidebar is a system gesture; this is the one line that
            // puts it in the Présentation menu, under ⌃⌘S, localised by SwiftUI.
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Analyser un dossier…") { chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Accès complet au disque…") { model.showsWelcome = true }
                Divider()
                Link("Code source", destination: URL(string: "https://github.com/")!)
            }
            // Where macOS puts Find. Declared by hand because `.searchable` —
            // which would have installed it — is not what draws the field; see
            // SearchField for why it cannot be.
            CommandGroup(after: .textEditing) {
                Button("Rechercher…") { model.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.canSearch)
            }
            CommandGroup(after: .toolbar) {
                // Written out rather than taken from `InspectorCommands()`,
                // which files an item titled "Inspecteur Show" — half
                // translated — under ⌃⌘I, and leaves it disabled. The shortcut
                // has to live in the menu and not on the toolbar button: the
                // button belongs to the inspector column now.
                //
                // Plain ⌘I, the Finder's "Lire les informations", because that
                // is what the column holds: the details of whatever is
                // selected. Preview spells its own inspector the same way. The
                // shortcut is free to take — nothing else here describes a
                // selection.
                Toggle("Inspecteur", isOn: Binding(
                    get: { model.showsInspector },
                    set: { model.showsInspector = $0 }
                ))
                .keyboardShortcut("i", modifiers: .command)
                Divider()
                // ⌘R is already the inspector's "Afficher dans le Finder".
                Button("Actualiser l'analyse") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canRescan)
                // ⌘↓ / ⌘↑ are the Finder's pair, and a menu item is the only
                // form of them that works before a list has been clicked into:
                // key equivalents are consulted before any responder sees the
                // key. The title changes with what is picked — three verbs for
                // one key is the Finder's own habit.
                Button(model.openLabel(for: model.openIntent)) {
                    Open.perform(model.selection, in: model)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.openIntent == nil)
                Button("Remonter d'un niveau") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    // `canGoUp`, not the trail alone: standing inside an
                    // aggregated slice is a level to leave like any other.
                    .disabled(!model.canGoUp)
                Button("Aperçu rapide") {
                    QuickLookPanel.shared.toggle(model.previewItems)
                }
                .keyboardShortcut(.space, modifiers: [])
                // The key-down monitor below swallows ⌘⌫ while a text field is
                // being edited, so reaching this action always means the tree.
                Button("Mettre à la corbeille") { model.requestDeletion() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selection.isEmpty)
                Divider()
                Toggle("Taille logique", isOn: Binding(
                    get: { model.useLogicalSize },
                    set: { model.useLogicalSize = $0 }
                ))
                // Here rather than in the breadcrumb bar: a second selector up
                // there would appear and vanish with the current view, and make
                // the bar jump every time you switched.
                //
                // Two toggles rather than a Picker: a menu Picker draws the
                // ticks by itself, but there is no supported way to hang a
                // keyboard shortcut off its items — and without shortcuts a
                // mode buried in a menu is a mode nobody flips twice.
                Toggle(ColorMode.category.label, isOn: colorMode(.category))
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Toggle(ColorMode.age.label, isOn: colorMode(.age))
                    .keyboardShortcut("2", modifiers: [.command, .option])
            }
        }
    }

    /// Radio behaviour out of a toggle: ticking one sets the mode, and unticking
    /// the mode already on does nothing rather than leaving the views with no
    /// colour scheme at all.
    private func colorMode(_ mode: ColorMode) -> Binding<Bool> {
        Binding(
            get: { model.colorMode == mode },
            set: { if $0 { model.colorMode = mode } }
        )
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
    /// Owned here rather than by ScanModel: the reboot measurement has
    /// nothing to do with the scan lifecycle and survives all its resets.
    @State private var reboot = RebootModel()
    /// Owned here for the same reason: the inventory of installed applications
    /// is taken from the filesystem directly, with or without a scan.
    @State private var apps = AppsModel()
    /// Owned here for the same reason again: snapshots are read from the
    /// volumes themselves and have never been part of any tree.
    @State private var snapshots = SnapshotsModel()
    /// Token for the space-key monitor, held so reopening the window never
    /// installs a second one — two monitors would toggle the preview twice,
    /// which is to say not at all.
    @State private var spaceMonitor: Any?

    var body: some View {
        // The banner is stacked under the whole split view rather than laid over
        // it. A `safeAreaInset` on the NavigationSplitView never reaches the
        // columns — the banner floated over the status bar and over the smallest
        // treemap tiles — and insetting the detail column alone stopped it short
        // of the sidebar. Below the stack it keeps the full window width *and*
        // takes real height, so everything above simply lays out in what is left.
        VStack(spacing: 0) {
            splitView
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
    }

    private var splitView: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            BrowserView(model: model, reboot: reboot, apps: apps, snapshots: snapshots)
        }
        .inspector(isPresented: Bindable(model).showsInspector) {
            InspectorView(model: model, apps: apps)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                // Declared on the inspector's own content rather than on the
                // split view, so the button sits over the inspector column the
                // way the sidebar's toggle sits over the sidebar — and slides
                // back into the window's bar when the column folds away.
                .toolbar {
                    ToolbarItem {
                        Button {
                            model.showsInspector.toggle()
                        } label: {
                            Label("Inspecteur", systemImage: "sidebar.trailing")
                        }
                    }
                }
        }
        .sheet(isPresented: Bindable(model).showsWelcome) {
            WelcomeSheet(
                unreadableCount: model.result?.unreadablePaths.count ?? 0
            ) {
                model.showsWelcome = false
                Preferences.shared.hasSeenWelcome = true
            }
        }
        .sheet(item: Bindable(model).deletionPlanBox) { box in
            DeletionSheet(
                plan: box.plan,
                onCancel: { model.deletionPlan = nil },
                onConfirm: { excluded in
                    Task { await model.confirmDeletion(excluding: excluded) }
                }
            )
        }
        .sheet(item: Bindable(snapshots).request) { request in
            SnapshotDeletionSheet(
                request: request,
                onCancel: { snapshots.request = nil },
                onConfirm: { Task { await snapshots.confirm(reporting: model) } }
            )
        }
        .sheet(item: Bindable(model).uninstallPlan) { plan in
            UninstallSheet(
                model: model, plan: plan,
                onDismiss: { model.uninstallPlan = nil }
            )
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.goUp()
                } label: {
                    Label("Remonter", systemImage: "chevron.up")
                }
                .disabled(!model.canGoUp)
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
            // Kept out of the browsing views' own bar on purpose: search
            // belongs where macOS puts it, and a `ToolbarItem` — unlike
            // `.searchable` in a NavigationSplitView — stays inside the
            // detail's toolbar group rather than spanning across the
            // inspector. It keeps its slot in the views it does not apply to,
            // like the colour switcher: losing it would shuffle the group
            // every time you stepped into Cleanup.
            //
            // It sits next to the size picker rather than out at the trailing
            // edge, which is where it belongs. Nothing moves it there: neither
            // `ToolbarSpacer(.flexible)` (macOS 26) at either placement, nor an
            // item claiming the leftover width itself. Tracked in issue #1.
            ToolbarItem(placement: .primaryAction) {
                SearchField(model: model)
                    .disabled(!model.canSearch)
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
                let consumed = MainActor.assumeIsolated { handleKey(event) == nil }
                return consumed ? nil : event
            }
        }
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
        // An open panel follows the selection, the way it does in the Finder —
        // including when its own arrow keys are what moved it.
        .onChange(of: model.selection) {
            QuickLookPanel.shared.update(model.previewItems)
        }
    }

    /// Returns nil to consume the event, or the event to let it through.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // ⌘⌫ while a caret is in any text field means "delete the line", never
        // "trash the selection" — but the Trash menu item's key equivalent is
        // consulted before the field editor ever sees the key. Same cure as
        // space below: do the editing gesture here and swallow the event, so
        // the menu never fires. The event names its own window, which spares
        // us guessing at `keyWindow` from inside a menu action.
        if event.keyCode == 51, // delete (backspace)
           event.modifierFlags
               .intersection([.command, .shift, .option, .control]) == .command,
           let editor = event.window?.firstResponder as? NSTextView {
            editor.deleteToBeginningOfLine(nil)
            return nil
        }
        return handleSpace(event)
    }

    private func handleSpace(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49, // space
              event.modifierFlags
                  .intersection([.command, .shift, .option, .control]).isEmpty
        else { return event }

        // Before the guard below, and not after: the preview panel is itself an
        // NSPanel, and it holds the keyboard while it is up. Space closes it,
        // like the Finder.
        if QuickLookPanel.shared.isOpen {
            QuickLookPanel.shared.close()
            return nil
        }

        guard let window = NSApp.keyWindow,
              !(window is NSPanel), // Open panel, Settings: not our keyboard
              !(window.firstResponder is NSTextView), // typing in a filter field
              !window.isSheet // sheets do their own previewing
        else { return event }

        // Only swallow the key when a preview actually opens; otherwise the
        // scroll views keep their page-down.
        return QuickLookPanel.shared.toggle(model.previewItems) ? nil : event
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
        // The buttons come and go with the message — an offer to undo, then a
        // bare "Restauration effectuée." — and a bandeau that shrank with them
        // would shove the whole window's content up and down. The tallest state
        // sets the height for every state.
        .frame(minHeight: 42)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35), value: message)
        .task(id: message) {
            guard isTransient else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    /// A message with nothing to act on has already said everything it had to
    /// say; making the user click it away would be a chore. One that still holds
    /// the way back stays until they take it or dismiss it themselves.
    private var isTransient: Bool { !canUndo && !needsAppManagement }
}


/// `sheet(item:)` needs identity; a file URL is its own.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
