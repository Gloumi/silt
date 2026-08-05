import AppKit
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
    /// Last tile the pointer was over, kept after the hover ends: opening a
    /// context menu can clear the hover first, and the menu would then have no
    /// target.
    @State private var menuTarget: Int32?
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
                            // Assigned even when nil — see the sunburst: an
                            // aggregated tile has no node, and keeping the last
                            // one aimed the context menu at the wrong folder.
                            menuTarget = hovered?.node
                        case .ended:
                            hovered = nil
                        }
                    }
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { handleTap(at: $0.location) }
                    )
                    .contextMenu {
                        SliceMenu(model: model, node: menuTarget)
                    }

                if let hovered, let lines = tooltipText(for: hovered) {
                    Tooltip(lines: lines)
                        .position(
                            x: min(max(110, hoverPoint.x), geometry.size.width - 110),
                            y: max(30, hoverPoint.y - 36)
                        )
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if model.colorMode == .age {
                    AgeLegend().padding(.bottom, 10)
                }
            }
            .onChange(of: geometry.size, initial: true) { _, size in
                lastSize = size
                rebuild(in: size)
            }
            .onChange(of: model.scanID) { rebuild(in: lastSize) }
            .onChange(of: model.currentNode) { rebuild(in: lastSize) }
            .onChange(of: model.useLogicalSize) { rebuild(in: lastSize) }
            .onChange(of: model.treeVersion) { rebuild(in: lastSize) }
            .onChange(of: model.searchVersion) { rebuild(in: lastSize) }
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
            children: model.visibleOthersScope,
            in: CGRect(origin: .zero, size: size),
            maxDepth: Self.maxDepth,
            useLogicalSize: model.useLogicalSize,
            filter: model.searchMask
        )
        hovered = nil
        menuTarget = nil
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext) {
        // One "now" for the whole pass: reading the clock per tile would let the
        // cutoff drift across a single frame.
        let now = Date()
        let ageMode = model.colorMode == .age
        for tile in tiles {
            // A 2px gap between fills, so neighbours read as separate blocks
            // without any need for outlines.
            let rect = tile.rect.insetBy(dx: 1, dy: 1)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            let isHovered = hovered?.id == tile.id
            let isSelected = tile.node.map { model.selection.contains($0) } ?? false
            let band = ageMode ? ageBand(of: tile, now: now) : nil

            let color = fill(
                for: tile, band: band, emphasised: isHovered || isSelected
            )

            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(color))

            // The gap alone stops working once neighbours share a colour, which
            // is the normal case in the age mode.
            if ageMode {
                context.stroke(
                    path, with: .color(Palette.ageEdge(band, dark: isDark)),
                    lineWidth: 1
                )
            }

            if isSelected {
                context.stroke(
                    path, with: .color(isDark ? .white : .black), lineWidth: 1.5
                )
            }
        }
        drawLabels(context: context, now: now)
    }

    /// The two colour modes, side by side. Geometry is identical either way —
    /// only the paint changes, which is why switching needs no rebuild.
    private func fill(
        for tile: TreemapTile, band: AgeBand?, emphasised: Bool
    ) -> Color {
        switch model.colorMode {
        case .category:
            return emphasised
                ? Palette.highlighted(
                    slot: tile.slot, ring: tile.depth,
                    sibling: tile.siblingIndex, dark: isDark)
                : Palette.color(
                    slot: tile.slot, ring: tile.depth,
                    sibling: tile.siblingIndex, dark: isDark)
        case .age:
            return emphasised
                ? Palette.ageHighlighted(band, dark: isDark)
                : Palette.age(band, dark: isDark)
        }
    }

    /// Nil for an aggregated tile: it stands for items of every age at once, so
    /// there is no honest colour for it.
    private func ageBand(of tile: TreemapTile, now: Date) -> AgeBand? {
        guard let node = tile.node, let store = model.store else { return nil }
        return AgeBand.band(modTime: store.modTime[Int(node)], now: now)
    }

    private func drawLabels(context: GraphicsContext, now: Date) {
        guard let store = model.store else { return }
        let ageMode = model.colorMode == .age
        for tile in tiles {
            guard let node = tile.node,
                  tile.rect.width > 40,
                  tile.rect.height > TreemapLayout.headerHeight
            else { continue }

            // In the age mode the block under the label can be anything from
            // near-white to deep rust, so the ink follows the block; the
            // categorical palette holds one lightness and needs only the theme.
            let ink = ageMode
                ? Palette.ageInk(ageBand(of: tile, now: now), dark: isDark).text
                : (isDark ? Color.white : Color.black)

            let text = Text(store.name(of: node))
                .font(.system(size: 10, weight: tile.depth == 1 ? .semibold : .regular))
                .foregroundStyle(ink)
            let resolved = context.resolve(text)
            // Measured unconstrained on purpose: measuring inside the tile's own
            // width returns a value clamped to that width, so the "does it fit"
            // test could never fail and long names spilled into their
            // neighbours.
            let measured = resolved.measure(
                in: CGSize(width: CGFloat.greatestFiniteMagnitude,
                           height: CGFloat.greatestFiniteMagnitude)
            )
            guard measured.width <= tile.rect.width - 8 else { continue }

            // Clipped as well: geometry should already guarantee containment,
            // but a label escaping its block is the most visible possible bug.
            var label = context
            label.clip(to: Path(tile.rect))
            label.draw(
                resolved,
                at: CGPoint(x: tile.rect.minX + 5,
                            y: tile.rect.minY + TreemapLayout.headerHeight / 2 + 1),
                anchor: .leading
            )
        }
    }

    // MARK: - Interaction

    private func handleTap(at location: CGPoint) {
        guard let tile = TreemapLayout.hitTest(tiles: tiles, point: location) else {
            model.selection = []
            return
        }
        guard let node = tile.node else {
            // Step into it, exactly as the rings do — the two views share the
            // scope, so one of them refusing to enter would contradict the
            // breadcrumb the other just set.
            if !tile.mergedNodes.isEmpty { model.enterOthers(tile.mergedNodes) }
            return
        }
        model.activate(node)
    }

    private func tooltipText(for tile: TreemapTile) -> [String]? {
        guard let store = model.store else { return nil }
        guard let node = tile.node else {
            return ["\(tile.mergedCount) autres éléments", Format.bytes(tile.size)]
        }
        var detail = "\(Format.bytes(tile.size)) · "
            + "\(Format.count(Int(store.fileCount[Int(node)]))) fichiers"
        // Only in the age mode: it is what the colour is claiming, so the
        // tooltip is where that claim gets checked.
        if model.colorMode == .age,
           let age = Format.age(unixSeconds: store.modTime[Int(node)]) {
            detail += " · \(age)"
        }
        return [store.name(of: node), detail]
    }
}

/// Right-click actions on whatever the pointer is over.
///
/// Right-click follows hover on macOS, so the hovered slice is the one the menu
/// belongs to. This is what preserves acting on a sibling without navigating
/// into it, now that a plain click opens.
struct SliceMenu: View {
    let model: ScanModel
    let node: Int32?

    var body: some View {
        if let node, let store = model.store {
            let path = store.path(of: node)
            Button("Ouvrir") { model.enter(node) }
                .disabled(!model.canEnter(node))
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: path)]
                )
            }
            Divider()
            Button("Mettre à la corbeille", role: .destructive) {
                model.selection = [node]
                model.requestDeletion()
            }
            .disabled(DenyList.verdict(for: path).isForbidden)
        } else {
            Button("Remonter d'un niveau") { model.goUp() }
                .disabled(model.trail.count <= 1)
        }
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
