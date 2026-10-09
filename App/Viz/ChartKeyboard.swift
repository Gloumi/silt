import AppKit
import SwiftUI

extension View {
    /// The arrow keys over a chart, walking the children of the folder on
    /// screen the way ↑↓ walk the list.
    ///
    /// `nodes` is what the chart actually draws at its first level, in drawing
    /// order: the rings clockwise, the tiles largest first. Children folded
    /// into an "others" slice are left out — selecting something with nothing
    /// lit up to show for it would look like the key did nothing.
    ///
    /// Order rather than geometry, for both charts: a treemap's neighbours in
    /// space are not a sequence anyone can predict, and walking by size is what
    /// the list beside it does too. ⏎ opens, as a click does; ⌘↑ is already
    /// the menu's.
    func chartKeyboard(model: ScanModel, nodes: [Int32]) -> some View {
        modifier(ChartKeyboard(model: model, nodes: nodes))
    }
}

private struct ChartKeyboard: ViewModifier {
    let model: ScanModel
    let nodes: [Int32]
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.downArrow, .rightArrow]) { _ in step(+1) }
            .onKeyPress(keys: [.upArrow, .leftArrow]) { _ in step(-1) }
            .onKeyPress(.return) {
                guard !model.selection.isEmpty else { return .ignored }
                Open.perform(model.selection, in: model)
                return .handled
            }
            // A canvas never takes the keyboard by being clicked, so it is
            // handed over whenever the chart is used instead: shown, stepped
            // into, or a slice picked.
            .onAppear(perform: takeKeyboard)
            .onChange(of: model.currentNode) { takeKeyboard() }
            .onChange(of: model.selection) { takeKeyboard() }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard !nodes.isEmpty else { return .ignored }
        let current = nodes.firstIndex { model.selection.contains($0) }
        let next: Int
        if let current {
            next = min(max(current + offset, 0), nodes.count - 1)
        } else {
            next = offset > 0 ? 0 : nodes.count - 1
        }
        model.selection = [nodes[next]]
        return .handled
    }

    /// Same reserve as the lists: a caret in the search field keeps the keys.
    private func takeKeyboard() {
        guard !isFocused,
              !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        isFocused = true
    }
}
