import AppKit
import QuickLookUI

/// The Finder's own Quick Look panel, driven from anywhere in the app.
///
/// `QLPreviewPanel` is shared per process and finds its data source by walking
/// the responder chain from the key window's first responder. SwiftUI gives us
/// nowhere dependable to sit in that chain — which is why this used to be a
/// `QLPreviewView` in a sheet of our own — but the chain ends at the
/// application delegate, and `QuickLookController` below is installed as one.
/// The panel that comes back is the real thing: floating, resizable, with full
/// screen, Share and "Open with", and arrow keys walking a whole selection.
@MainActor
final class QuickLookPanel: NSObject {
    static let shared = QuickLookPanel()

    /// What the panel is showing, in the order the arrow keys walk them.
    private(set) var items: [URL] = []

    private override init() { super.init() }

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func show(_ urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        items = urls
        let panel = QLPreviewPanel.shared()!
        // Set here as well as in `beginPreviewPanelControl`: the panel only goes
        // looking for a controller once it is on screen, and it has to know what
        // to draw before that.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = items.indices.contains(index) ? index : 0
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// True when the key was worth swallowing — the caller lets space fall
    /// through to the scroll views as page-down when there is nothing to show.
    @discardableResult
    func toggle(_ urls: [URL], startingAt index: Int = 0) -> Bool {
        if isOpen {
            close()
            return true
        }
        guard !urls.isEmpty else { return false }
        show(urls, startingAt: index)
        return true
    }

    /// Keeps an open panel in step with a selection that moved under it.
    func update(_ urls: [URL]) {
        guard isOpen else { return }
        guard !urls.isEmpty else { return close() }
        let panel = QLPreviewPanel.shared()!
        let current = items.indices.contains(panel.currentPreviewItemIndex)
            ? items[panel.currentPreviewItemIndex]
            : nil
        items = urls
        panel.reloadData()
        // Stay on the same file when it survived the change: adding a fourth
        // item to a selection of three must not snap the panel back to the
        // first. When it did not survive, the selection moved — show where it
        // went.
        panel.currentPreviewItemIndex = current.flatMap(urls.firstIndex(of:)) ?? 0
    }
}

extension QuickLookPanel: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        // A URL crosses the hop where the NSURL the panel wants — not Sendable —
        // cannot; the bridge is on this side of it.
        let url: URL? = MainActor.assumeIsolated {
            items.indices.contains(index) ? items[index] : nil
        }
        return url.map { $0 as NSURL }
    }
}

extension QuickLookPanel: QLPreviewPanelDelegate {
    /// ↑ and ↓ keep driving the list behind the panel, the way they do in the
    /// Finder. The panel is the key window while it is up, so the event has to
    /// be handed back by hand; the selection then changes, and whoever is
    /// watching it calls `update`. Everything else is the panel's own business —
    /// ← and → between items, escape to close.
    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, handle event: NSEvent!
    ) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags
                  .intersection([.command, .shift, .option, .control]).isEmpty
        else { return false }
        // The action the key stands for rather than the key event itself: a
        // selector crosses to the main actor where the event, not Sendable,
        // would not — and it is what the list would have ended up calling.
        let command: Selector? = switch event.keyCode {
        case 125: #selector(NSResponder.moveDown(_:))
        case 126: #selector(NSResponder.moveUp(_:))
        default: nil
        }
        guard let command else { return false }
        return MainActor.assumeIsolated {
            // A panel never becomes main, so the window behind is still there to
            // be found — and a sheet over it owns the keyboard on its behalf.
            guard let main = NSApp.mainWindow,
                  let target = (main.attachedSheet ?? main).firstResponder,
                  !(target is NSWindow) // nothing focused: let the panel beep
            else { return false }
            return target.tryToPerform(command, with: nil)
        }
    }
}


/// The last link of the responder chain, and so the one place a SwiftUI app can
/// answer the preview panel reliably when it goes looking for a controller.
///
/// Installed as the application delegate — that is its whole job. Nothing else
/// is implemented here on purpose: the app's lifecycle is SwiftUI's, and a
/// delegate that starts answering `applicationShould…` would quietly take some
/// of it back.
final class QuickLookController: NSObject, NSApplicationDelegate {
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPanel.shared
            panel.delegate = QuickLookPanel.shared
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
