import DiskCore
import SwiftUI

/// Rectangular counterpart to the sunburst.
///
/// The rings answer "how is this folder divided"; the treemap answers "where is
/// the weight", showing far more items at once at the cost of a less legible
/// hierarchy. Same tree, same colours, same interactions — only the geometry
/// differs, which is why both were worth having.
struct TreemapView: View {
    let model: ScanModel

    static let maxDepth = 3

    @Environment(\.colorScheme) private var colorScheme
    @State private var tiles: [TreemapTile] = []
    @State private var hovered: TreemapTile?
    @State private var hoverPoint: CGPoint = .zero
    @State private var builtScanID = -1
    @State private var lastSize: CGSize = .zero

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, _ in draw(context: context) }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverPoint = location
                            hovered = TreemapLayout.hitTest(
                                tiles: tiles, point: location
                            )
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { handleTap(at: $0.location, drill: true) }
                    )
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { handleTap(at: $0.location, drill: false) }
                    )

                if let hovered, let lines = tooltipText(for: hovered) {
                    Tooltip(lines: lines)
                        .position(
                            x: min(max(110, hoverPoint.x), geometry.size.width - 110),
                            y: max(30, hoverPoint.y - 36)
                        )
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: geometry.size, initial: true) { _, size in
                lastSize = size
                rebuild(in: size)
            }
            .onChange(of: model.scanID) { rebuild(in: lastSize) }
            .onChange(of: model.currentNode) { rebuild(in: lastSize) }
            .onChange(of: model.useLogicalSize) { rebuild(in: lastSize) }
            .onChange(of: model.rows.count) { rebuild(in: lastSize) }
        }
    }

    private func rebuild(in size: CGSize) {
        guard let store = model.store, size.width > 1, size.height > 1 else {
            tiles = []
            return
        }
        builtScanID = model.scanID
        tiles = TreemapLayout.build(
            store: store,
            root: model.currentNode,
            in: CGRect(origin: .zero, size: size),
            maxDepth: Self.maxDepth,
            useLogicalSize: model.useLogicalSize
        )
        hovered = nil
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext) {
        for tile in tiles {
            // A 2px gap between fills, so neighbours read as separate blocks
            // without any need for outlines.
            let rect = tile.rect.insetBy(dx: 1, dy: 1)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            let isHovered = hovered.map {
                $0.node == tile.node && $0.depth == tile.depth
            } ?? false
            let isSelected = tile.node.map { model.selection.contains($0) } ?? false

            let color = (isHovered || isSelected)
                ? Palette.highlighted(
                    slot: tile.slot, ring: tile.depth,
                    sibling: tile.siblingIndex, dark: isDark)
                : Palette.color(
                    slot: tile.slot, ring: tile.depth,
                    sibling: tile.siblingIndex, dark: isDark)

            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(color))

            if isSelected {
                context.stroke(
                    path, with: .color(isDark ? .white : .black), lineWidth: 1.5
                )
            }
        }
        drawLabels(context: context)
    }

    private func drawLabels(context: GraphicsContext) {
        guard let store = model.store else { return }
        for tile in tiles {
            guard let node = tile.node,
                  tile.rect.width > 54, tile.rect.height > 16
            else { continue }

            let text = Text(store.name(of: node))
                .font(.system(size: 10, weight: tile.depth == 1 ? .semibold : .regular))
                .foregroundStyle(isDark ? .white : .black)
            let resolved = context.resolve(text)
            let measured = resolved.measure(
                in: CGSize(width: tile.rect.width - 8, height: 16)
            )
            guard measured.width <= tile.rect.width - 8 else { continue }

            context.draw(
                resolved,
                at: CGPoint(x: tile.rect.minX + 5, y: tile.rect.minY + 8),
                anchor: .leading
            )
        }
    }

    // MARK: - Interaction

    private func handleTap(at location: CGPoint, drill: Bool) {
        guard let tile = TreemapLayout.hitTest(tiles: tiles, point: location),
              let node = tile.node
        else {
            model.selection = []
            return
        }
        if drill {
            model.enter(node)
        } else {
            model.selection = [node]
        }
    }

    private func tooltipText(for tile: TreemapTile) -> [String]? {
        guard let store = model.store else { return nil }
        guard let node = tile.node else {
            return ["\(tile.mergedCount) autres éléments", Format.bytes(tile.size)]
        }
        return [
            store.name(of: node),
            "\(Format.bytes(tile.size)) · "
                + "\(Format.count(Int(store.fileCount[Int(node)]))) fichiers",
        ]
    }
}

/// Shared with the sunburst so both views speak the same way on hover.
struct Tooltip: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: index == 0 ? 11 : 10,
                                  weight: index == 0 ? .semibold : .regular))
                    .foregroundStyle(index == 0 ? .primary : .secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .shadow(radius: 5, y: 2)
    }
}
