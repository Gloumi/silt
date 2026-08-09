import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnail of a file, falling back to its file-type icon.
///
/// Shared by the duplicate cards and the deletion recap. Uses the thumbnail
/// service rather than a live `QLPreviewView`: these sit in lists and grids
/// that re-render freely, and spinning up a preview each time would be far
/// heavier than the picture it produces. The `.task` is keyed on the path, so
/// a view recycled by a lazy container reloads for the file it now shows.
///
/// The caller frames it; `aspectRatio(.fit)` does the rest.
struct FileThumbnail: View {
    let path: String
    /// Folders reach this view too, since a duplicate can be one. Hard-coded
    /// false until then, which dropped every folder onto the generic document
    /// icon — the one picture guaranteed to be wrong.
    var isDirectory: Bool = false
    let isPackage: Bool
    /// Pixel size asked of the generator. Ask for the largest the layout can
    /// show — the image scales down well and up badly.
    var pixelSize: CGFloat = 220
    /// Breathing room around the *fallback icon* only: at card sizes an icon
    /// drawn edge to edge looks blown up next to real thumbnails.
    var fallbackPadding: CGFloat = 0

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: IconCache.shared.icon(
                    name: (path as NSString).lastPathComponent,
                    isDirectory: isDirectory, isPackage: isPackage
                ))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(fallbackPadding)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        thumbnail = nil
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: 2,
            representationTypes: .thumbnail
        )
        let generated = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
        guard !Task.isCancelled else { return }
        thumbnail = generated?.nsImage
    }
}
