import AppKit
import SwiftUI

/// The search box: a collapsed magnifying glass that expands into the real
/// AppKit search field.
///
/// The expanded state is a bridged `NSSearchField`, and that is capability
/// rather than taste. SwiftUI on macOS cannot keep a search field collapsed
/// (`SearchToolbarBehavior.minimize` is `@available(macOS, unavailable)`, at
/// every version), cannot put a menu on the glass (`searchMenuTemplate` is
/// AppKit-only), and `@FocusState` does not track a field hosted in a toolbar —
/// the caret sits in the box while the binding still reads false, which left
/// ⌘⌫ trashing files and clicks never releasing the field. The native control
/// answers all of it, plus the glass on the left of the text, the chevron that
/// appears the moment a menu is attached, the cancel button and the padding.
struct SearchField: View {
    let model: ScanModel

    @State private var expanded = false

    var body: some View {
        Group {
            if expanded {
                BridgedSearchField(
                    // Handed over once, never read back: an observed read of
                    // the query from a toolbar view rebuilds the whole bar on
                    // every keystroke, and SwiftUI answers that by recreating
                    // this field — which retakes focus and selects all.
                    initialText: model.untrackedSearchText,
                    scope: model.searchScope,
                    recents: Preferences.shared.recentSearches,
                    focusToken: model.focusSearchRequests,
                    resetToken: model.searchResetToken,
                    model: model,
                    // End of editing alone must not collapse the box: opening
                    // the glass's own menu ends the session too, and an empty
                    // field vanishing under the menu it just opened is what
                    // that would look like.
                    onFocusLost: { model.rememberSearch() },
                    onClickedAway: {
                        model.rememberSearch()
                        if model.untrackedSearchText.isEmpty { expanded = false }
                    },
                    onDismiss: {
                        model.rememberSearch()
                        model.searchText = ""
                        expanded = false
                    }
                )
                .frame(width: 220)
            } else {
                // A bare toolbar button, unstyled on purpose: that is what lets
                // the toolbar draw it round, like its neighbours.
                Button {
                    model.requestSearchFocus()
                } label: {
                    Label("Rechercher", systemImage: "magnifyingglass")
                }
                .help("Rechercher dans l'arborescence (⌘F)")
            }
        }
        .onChange(of: model.focusSearchRequests) { expanded = true }
        // Recreated mid-search — a presentation switch, a window rebuild — the
        // box must come back open: the active filter has no other face.
        .onAppear { if !model.untrackedSearchText.isEmpty { expanded = true } }
    }
}

// MARK: - AppKit bridge

private struct BridgedSearchField: NSViewRepresentable {
    /// Seeds the control and nothing more — the field owns its text from then
    /// on, and reports changes upwards.
    let initialText: String
    let scope: ScanModel.SearchScope
    let recents: [String]
    let focusToken: Int
    let resetToken: Int
    let model: ScanModel
    let onFocusLost: () -> Void
    let onClickedAway: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: initialText)
        field.delegate = context.coordinator
        field.placeholderString = "Nom, ou .extension"
        field.font = .systemFont(ofSize: 12)
        context.coordinator.field = field
        context.coordinator.installClickMonitor()
        // Grab the caret as soon as the field exists: it only ever appears
        // because the user asked to search. Deferred a turn — there is no
        // window to ask until the view is attached.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            context.coordinator.putCaretAtEnd()
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // The field is the source of truth for its own text. It is only ever
        // overwritten from outside on an explicit reset — a new scan — which
        // announces itself with a token rather than by comparing strings.
        if resetToken != coordinator.lastResetToken {
            coordinator.lastResetToken = resetToken
            field.stringValue = initialText
        }
        if field.isEnabled != context.environment.isEnabled {
            field.isEnabled = context.environment.isEnabled
        }
        // Same rule for the menu: reassigning the template makes the cell
        // rebuild its search button mid-edit, which resets the field editor and
        // leaves the text select-all'd.
        let menuKey = "\(scope.rawValue)\u{1}\(recents.joined(separator: "\u{1}"))"
        if menuKey != coordinator.lastMenuKey {
            coordinator.lastMenuKey = menuKey
            field.searchMenuTemplate = coordinator.menu(scope: scope, recents: recents)
        }
        if focusToken != coordinator.lastFocusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                coordinator.putCaretAtEnd()
            }
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BridgedSearchField
        weak var field: NSSearchField?
        var lastFocusToken: Int
        var lastResetToken: Int
        var lastMenuKey = ""
        private var clickMonitor: Any?

        /// Taking first responder on an `NSTextField` selects everything it
        /// holds. Fine for a fresh empty box, ruinous for one that already has
        /// a query in it — the next keystroke would replace the lot.
        func putCaretAtEnd() {
            guard let editor = field?.currentEditor() else { return }
            let end = (editor.string as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }

        init(_ parent: BridgedSearchField) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
            self.lastResetToken = parent.resetToken
        }

        /// Clicking anywhere that is not the field gives the caret back.
        ///
        /// AppKit only moves the first responder when the click lands on
        /// something that wants it, and most of this app — the canvases above
        /// all — does not. Without this, the caret sat in the box through every
        /// interaction with the charts.
        func installClickMonitor() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { event in
                // Same shape as the space monitor in SiltApp: the closure is
                // nonisolated, the work is not.
                MainActor.assumeIsolated { self.releaseFocusIfClickedAway(event) }
                return event
            }
        }

        /// Monitors retain their closure, which retains us: the cycle is broken
        /// here, from `dismantleNSView`, never from deinit.
        func teardown() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        private func releaseFocusIfClickedAway(_ event: NSEvent) {
            // A click in another window — the glass's own menu above all — is
            // not "away": choosing a scope must not fold the box it belongs to.
            guard let field, let window = field.window,
                  event.window === window
            else { return }
            let point = field.convert(event.locationInWindow, from: nil)
            guard !field.bounds.contains(point) else { return }
            // Release the caret if the click will not take it — the canvases
            // never do — and let the owner fold an abandoned empty box. Not
            // gated on an editing session: a box left open by a menu round
            // trip has none, and it must still fold.
            if let editor = window.firstResponder as? NSTextView,
               editor.delegate === field {
                window.makeFirstResponder(nil)
            }
            parent.onClickedAway()
        }

        // MARK: Delegate

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.model.searchText = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusLost()
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.model.rememberSearch()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // First escape clears, second gives the field back — the stock
                // rhythm of a macOS search field.
                if parent.model.untrackedSearchText.isEmpty {
                    control.window?.makeFirstResponder(nil)
                    parent.onDismiss()
                } else {
                    control.stringValue = ""
                    parent.model.searchText = ""
                }
                return true
            default:
                // Everything else — ⌘⌫ deleting the line included — belongs to
                // the field editor.
                return false
            }
        }

        // MARK: Glass menu

        func menu(scope: ScanModel.SearchScope, recents: [String]) -> NSMenu {
            let menu = NSMenu()
            for candidate in ScanModel.SearchScope.allCases {
                let item = NSMenuItem(
                    title: candidate.label,
                    action: #selector(pickScope(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = candidate.rawValue
                item.state = candidate == scope ? .on : .off
                menu.addItem(item)
            }
            if !recents.isEmpty {
                menu.addItem(.separator())
                // No target and no action: the menu disables it by itself,
                // which is all a header is.
                menu.addItem(NSMenuItem(
                    title: "Récentes", action: nil, keyEquivalent: ""
                ))
                for query in recents {
                    let item = NSMenuItem(
                        title: query,
                        action: #selector(useRecent(_:)), keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = query
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
                menu.addItem(.separator())
                let clear = NSMenuItem(
                    title: "Effacer les récentes",
                    action: #selector(clearRecents), keyEquivalent: ""
                )
                clear.target = self
                menu.addItem(clear)
            }
            return menu
        }

        @objc private func pickScope(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let scope = ScanModel.SearchScope(rawValue: raw) else { return }
            parent.model.searchScope = scope
        }

        @objc private func useRecent(_ sender: NSMenuItem) {
            guard let query = sender.representedObject as? String else { return }
            // Written straight into the control as well: `updateNSView` now
            // refuses to touch a field being edited, and this one may well be.
            field?.stringValue = query
            parent.model.searchText = query
            if let field {
                field.window?.makeFirstResponder(field)
                putCaretAtEnd()
            }
        }

        @objc private func clearRecents() {
            Preferences.shared.clearRecentSearches()
        }
    }
}
