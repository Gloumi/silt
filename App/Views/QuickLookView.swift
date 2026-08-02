import Quartz
import SwiftUI

/// Quick Look preview of one file.
///
/// Hosts a `QLPreviewView` in a sheet rather than driving the shared
/// `QLPreviewPanel`. The panel expects a data source somewhere in the responder
/// chain, which SwiftUI does not give us a reliable place to sit in; owning the
/// view outright keeps the whole thing under our control.
struct QuickLookSheet: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Afficher dans le Finder")
                Button("Fermer", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()
            PreviewRepresentable(url: url)
        }
        .frame(width: 680, height: 520)
        // Space closes it again, matching how Quick Look behaves in the Finder.
        .background {
            Button("", action: onDismiss)
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0)
        }
    }
}

private struct PreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }
}
