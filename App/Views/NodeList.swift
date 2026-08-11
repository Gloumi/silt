import AppKit
import SwiftUI

/// The one list in Silt, and the one place its Finder behaviour is written.
///
/// Both browsing lists — the tree and the large-files extract — are an ordered
/// run of nodes with a selection, a double-click and a right-click menu. They
/// used to implement that twice over, in gestures hung on the rows. That is
/// what broke them: `.contentShape(.rect)` plus `.onTapGesture` sit *in front
/// of* the NSTableView a List is really made of, so the table stopped seeing
/// the clicks it needs to select, to extend and to open. Single clicks were
/// swallowed, double clicks mostly never arrived, and the extract — which had
/// no selection binding at all — had no keyboard either.
///
/// Here the table keeps every click. `contextMenu(forSelectionType:)` is what
/// buys that back: applied to the List — never to a row — it hands AppKit both
/// the menu and the double-click, so selecting, ⇧-clic, ⌘-clic, ↑↓ and
/// right-click-then-select are the system's own, and the primary action fires
/// with the set the table settled on.
///
/// Rows supplied by callers must stay pure presentation. Any gesture added back
/// to one re-opens exactly the bug this exists to close.
struct NodeList<Row: View, MenuItems: View>: View {
    /// In display order — the order ↑ and ↓ will walk.
    let nodes: [Int32]
    @Binding var selection: Set<Int32>

    /// Double-click, and ⏎. Receives the set the table settled on, which for a
    /// double-click is the row under the pointer.
    let primaryAction: (Set<Int32>) -> Void

    /// The row, and whether it is selected. The flag is handed down rather than
    /// read from the model per row: the proportional bar is drawn inside the
    /// cell, so it lands on top of the selection fill and has to change colour
    /// to stay legible.
    @ViewBuilder let row: (Int32, Bool) -> Row

    /// Right-click. The set is the table's: the clicked row when it was not
    /// selected, the whole selection when it was, and empty on empty space.
    /// Act on *it*, never on the selection — that is the entire point.
    @ViewBuilder let menu: (Set<Int32>) -> MenuItems

    var body: some View {
        List(nodes, id: \.self, selection: $selection) { node in
            row(node, selection.contains(node))
                // The bar spans the whole row; a hairline across it reads as a
                // division of the bar rather than of the list.
                .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
        // On the List. On a row it would be a menu of its own, which does not
        // move the table's selection — hence the `if !selection.contains(node)`
        // patch-up both call sites used to carry, and the missing highlight
        // around the row the menu belongs to.
        .contextMenu(forSelectionType: Int32.self) { items in
            menu(items)
        } primaryAction: { items in
            primaryAction(items)
        }
        // ⏎ opens as well: it is wired to the table's double-click action, not
        // to the keyboard, and the Finder spends ⏎ on renaming — which Silt
        // does not do, so the key is free and it is the one people try first.
        // Needs the list to be first responder, as ↑↓ do; ⌘↓ in the menu is the
        // form that works before the list has ever been clicked into.
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            primaryAction(selection)
            return .handled
        }
    }
}

/// The app's one "ouvrir" gesture, performed.
///
/// A namespace rather than a method on `ScanModel`: one of the three answers is
/// `NSWorkspace`, and the model has stayed clear of AppKit. The model decides
/// *which* of the three — that depends on the view on screen, and the ⌘↓ menu
/// command has no view to ask.
enum Open {
    /// Acts on a single item only. Opening several folders would take several
    /// windows, and the menu item is dark for a multi-selection to match.
    @MainActor
    static func perform(_ items: Set<Int32>, in model: ScanModel) {
        guard items.count == 1, let node = items.first else { return }
        switch model.openIntent(for: node) {
        case .enter(let node): model.enter(node)
        case .reveal(let node): model.reveal(node)
        case .finder(let path): inFinder(path)
        case nil: break
        }
    }

    @MainActor
    static func inFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: path)]
        )
    }
}
