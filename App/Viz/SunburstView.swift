import DiskCore
import SwiftUI

struct SunburstView: View {
    let model: ScanModel

    static let maxRings = 4
    /// Shortest slice we are willing to draw, in points along its own arc.
    /// Below this it is a hairline nobody can aim at.
    private static let minimumArcLength = 6.0

    @Environment(\.colorScheme) private var colorScheme
    @State private var arcs: [Arc] = []
    /// Rings the tree actually fills, up to `maxRings`. A folder one level deep
    /// used to occupy only the innermost quarter and leave the rest blank.
    @State private var usedRings = SunburstView.maxRings
    /// Last size the layout was built for. The merge threshold is expressed in
    /// points, so the layout depends on it.
    @State private var lastSize: CGSize = .zero
    /// Set when an "others" slice is opened, to list what it stands for.
    @State private var othersArc: Arc?
    /// Geometry of the previous layout, keyed by node, used to animate a drill.
    @State private var previousGeometry: [Int32: Arc] = [:]
    @State private var transition: Double = 1
    /// Scan the current arcs were built from. Node indices are only meaningful
    /// within one store, so geometry from a previous scan must never be reused.
    @State private var builtScanID = -1
    @State private var hovered: Arc?
    /// Last slice the pointer was over, kept after the hover ends: opening a
    /// context menu can clear the hover first, and the menu would then have no
    /// target.
    @State private var menuTarget: Int32?
    @State private var hoverPoint: CGPoint = .zero

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            let metrics = Metrics(size: geometry.size, rings: usedRings)

            ZStack {
                Canvas { context, _ in
                    draw(context: context, metrics: metrics)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverPoint = location
                        hovered = SunburstLayout.hitTest(
                            arcs: arcs,
                            point: metrics.relative(location),
                            innerRadius: metrics.innerRadius,
                            ringWidth: metrics.ringWidth
                        )
                        if let node = hovered?.node { menuTarget = node }
                    case .ended:
                        hovered = nil
                    }
                }
                // One click opens. Anything that cannot be opened — a file, a
                // collapsed folder — is selected instead, so a click is never
                // inert.
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            handleTap(at: event.location, metrics: metrics)
                        }
                )
                // Acting on a child without entering it: the one thing
                // click-to-open would otherwise have cost.
                .contextMenu {
                    SliceMenu(model: model, node: menuTarget)
                }

                CenterLabel(model: model, hovered: hovered)
                    .frame(width: metrics.innerRadius * 1.7)
                    .allowsHitTesting(false)

                if let hovered, let tooltip = tooltipText(for: hovered) {
                    Tooltip(lines: tooltip)
                        .position(
                            x: min(max(110, hoverPoint.x), geometry.size.width - 110),
                            y: max(34, hoverPoint.y - 40)
                        )
                        .allowsHitTesting(false)
                }
            }
            // The merge threshold is a length in points, so the layout depends
            // on how big the chart is drawn. Rebuilt on a step change only —
            // dragging a window edge must not rebuild on every pixel.
            .onChange(of: geometry.size, initial: true) { _, size in
                guard abs(size.width - lastSize.width) > 8
                    || abs(size.height - lastSize.height) > 8 else { return }
                lastSize = size
                rebuild(animated: false)
            }
        }
        // Only a drill within the same scan animates. A new scan, a switch of
        // size mode, or simply coming back to this tab rebuilds instantly —
        // re-running an animation there reads as if the app were re-analysing.
        .onChange(of: model.scanID, initial: true) { rebuild(animated: false) }
        .onChange(of: model.currentNode) { rebuild(animated: true) }
        .onChange(of: model.useLogicalSize) { rebuild(animated: false) }
        // Redraw as the scan fills the tree in. Keyed on the tree's version and
        // not on the number of rows: a folder reaches its final child count
        // almost immediately while the sizes behind them keep growing.
        .onChange(of: model.treeVersion) { rebuild(animated: false) }
        .sheet(item: $othersArc) { arc in
            OthersSheet(model: model, arc: arc) { othersArc = nil }
        }
    }

    // MARK: - Layout lifecycle

    private func rebuild(animated: Bool) {
        guard let store = model.store else { arcs = []; usedRings = 1; return }

        let sameScan = builtScanID == model.scanID
        var geometryByNode: [Int32: Arc] = [:]
        if sameScan {
            for arc in arcs {
                if let node = arc.node { geometryByNode[node] = arc }
            }
        }
        previousGeometry = geometryByNode
        builtScanID = model.scanID

        // Two passes on purpose. The merge threshold is a length in points, so
        // it depends on the ring width — which depends on how many rings the
        // tree actually fills, which is only known once it is built. The layout
        // costs about 0.1 ms, so measuring and redoing it beats guessing.
        func build(rings: Int) -> [Arc] {
            SunburstLayout.build(
                store: store,
                root: model.currentNode,
                maxRings: Self.maxRings,
                useLogicalSize: model.useLogicalSize,
                minimumSweep: minimumSweep(rings: rings)
            )
        }

        var built = build(rings: Self.maxRings)
        let depth = ringsFilled(by: built)
        if depth != Self.maxRings { built = build(rings: depth) }

        arcs = built
        usedRings = ringsFilled(by: built)
        hovered = nil

        if animated, sameScan, !geometryByNode.isEmpty {
            transition = 0
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                transition = 1
            }
        } else {
            transition = 1
        }
    }

    private func ringsFilled(by arcs: [Arc]) -> Int {
        max(1, arcs.map(\.ring).max() ?? 1)
    }

    /// Smallest sweep worth drawing, derived from the radius it will be drawn
    /// at rather than fixed once and for all.
    ///
    /// The old constant of 0.006 rad was under two points of arc on the inner
    /// ring of a 300 pt chart — visible, but not something anyone could click.
    /// Ring 1 is the worst case since it has the smallest radius.
    private func minimumSweep(rings: Int) -> Double {
        let size = lastSize == .zero ? CGSize(width: 420, height: 420) : lastSize
        let radius = Metrics(size: size, rings: rings).radius(ring: 1, fraction: 0.5)
        guard radius > 0 else { return 0.006 }
        return min(0.05, max(0.006, Self.minimumArcLength / radius))
    }

    /// Where an arc should be drawn right now, part-way through a drill.
    ///
    /// A slice that existed before slides from its old wedge to its new one; a
    /// slice that is new to this view grows out of where its parent used to be.
    /// That is what makes drilling read as a zoom rather than a cut.
    private func interpolated(_ arc: Arc) -> (Arc, Double) {
        guard transition < 1 else { return (arc, 1) }

        let source: Arc?
        if let node = arc.node, let old = previousGeometry[node] {
            source = old
        } else if let node = arc.node, let store = model.store {
            source = previousGeometry[store.parent[Int(node)]]
        } else {
            source = nil
        }

        // No ancestor to grow from — show it straight away rather than fading
        // in, so a rebuild can never leave an empty circle on screen.
        guard let from = source else { return (arc, 1) }

        let t = transition
        var result = arc
        result.startAngle = from.startAngle + (arc.startAngle - from.startAngle) * t
        result.endAngle = from.endAngle + (arc.endAngle - from.endAngle) * t
        return (result, 1)
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, metrics: Metrics) {
        // Geometry first, drawing second: the shadow needs the silhouette of
        // what is actually there, and the labels need each slice's own path to
        // clip against.
        var shapes: [(arc: Arc, path: Path, opacity: Double)] = []
        shapes.reserveCapacity(arcs.count)
        var silhouette = Path()

        for arc in arcs {
            let (shape, opacity) = interpolated(arc)
            // Fractional ring during the transition would need radius easing
            // too; the angular slide already carries the motion.
            let inner = metrics.radius(ring: shape.ring, fraction: 0)
            let outer = metrics.radius(ring: shape.ring, fraction: 1)
            let gap = Self.gapRadians(for: shape.sweep)

            // A hairline of background, not a groove. The old 2 pt radial gap
            // plus a wider angle read as heavy black seams.
            guard let path = annularSector(
                center: metrics.center,
                innerRadius: inner + 0.25,
                outerRadius: outer - 0.75,
                startAngle: shape.startAngle,
                endAngle: shape.endAngle,
                gapRadians: gap
            ) else { continue }

            // Same wedge without the gaps, so neighbours weld into one shape.
            if let solid = annularSector(
                center: metrics.center,
                innerRadius: inner, outerRadius: outer,
                startAngle: shape.startAngle, endAngle: shape.endAngle,
                gapRadians: 0
            ) {
                silhouette.addPath(solid)
            }
            shapes.append((arc, path, opacity))
        }

        drawPlateShadow(context: context, silhouette: silhouette)

        var selected: [Path] = []

        for (arc, path, opacity) in shapes {
            let shape = interpolated(arc).0
            let outerRadius = metrics.radius(ring: shape.ring, fraction: 1)
            let gap = Self.gapRadians(for: shape.sweep)

            let isHovered = hovered.map {
                $0.node == arc.node && $0.ring == arc.ring
            } ?? false
            let isSelected = arc.node.map { model.selection.contains($0) } ?? false

            let outerColor = (isHovered || isSelected)
                ? Palette.highlighted(
                    slot: arc.slot, ring: arc.ring,
                    sibling: arc.siblingIndex, dark: isDark)
                : Palette.color(
                    slot: arc.slot, ring: arc.ring,
                    sibling: arc.siblingIndex, dark: isDark)
            let innerColor = (isHovered || isSelected)
                ? outerColor
                : Palette.deepened(
                    slot: arc.slot, ring: arc.ring,
                    sibling: arc.siblingIndex, dark: isDark)

            // One radial gradient shared by every slice, anchored at the centre
            // of the chart: the rings gain depth without any slice inventing a
            // light source of its own.
            context.fill(
                path,
                with: .radialGradient(
                    Gradient(colors: [
                        innerColor.opacity(opacity),
                        outerColor.opacity(opacity),
                    ]),
                    center: metrics.center,
                    startRadius: metrics.innerRadius,
                    endRadius: metrics.outerRadius
                )
            )

            // A lit edge along the outer rim only. Strokes the boundary rather
            // than the fill, so the validated palette is untouched.
            if let rim = outerEdge(
                center: metrics.center, radius: outerRadius - 1.1,
                startAngle: shape.startAngle, endAngle: shape.endAngle,
                gapRadians: gap
            ) {
                context.stroke(
                    rim,
                    with: .color(.white.opacity(isDark ? 0.16 : 0.30)),
                    lineWidth: 1
                )
            }

            if isSelected { selected.append(path) }
        }

        drawSheen(context: context, silhouette: silhouette, metrics: metrics)

        // Above the sheen, so a picked slice stays unambiguous wherever it sits
        // under the lighting.
        for path in selected {
            context.stroke(path, with: .color(isDark ? .white : .black), lineWidth: 1.5)
        }

        drawLabels(context: context, metrics: metrics, shapes: shapes)
    }

    /// Angular gap between neighbouring slices, in radians.
    private static func gapRadians(for sweep: Double) -> Double {
        min(0.006, sweep * 0.05)
    }

    /// Soft shadow around the rings, and nowhere else.
    ///
    /// Cast by the silhouette of what is actually drawn, not by the full
    /// annulus — branches shallower than the deepest one leave their outer
    /// rings empty, and a full-annulus plate showed through there as a black
    /// wedge.
    ///
    /// Clipped to the *outside* of that silhouette: the shape has to be filled
    /// for anything to cast a shadow, but that fill would otherwise show
    /// through every gap between slices as a hard black seam, which is exactly
    /// what made the first attempt look harsher rather than softer.
    private func drawPlateShadow(context: GraphicsContext, silhouette: Path) {
        guard !silhouette.isEmpty else { return }
        var layer = context
        layer.clip(to: silhouette, options: .inverse)
        layer.addFilter(.shadow(
            color: .black.opacity(isDark ? 0.55 : 0.26),
            radius: 16, x: 0, y: 6
        ))
        layer.fill(silhouette, with: .color(.black))
    }

    /// A single light source above the chart, laid over the finished rings.
    ///
    /// This is what actually reads as depth. Per-slice shading cannot do it —
    /// each slice would carry its own highlight and the disc would look like a
    /// mosaic rather than one object. Applied uniformly, so the hue separation
    /// the palette was validated for is preserved.
    private func drawSheen(context: GraphicsContext, silhouette: Path, metrics: Metrics) {
        guard !silhouette.isEmpty else { return }
        let center = metrics.center
        let radius = metrics.outerRadius

        // Soft light rather than plain alpha. Painting translucent white over a
        // colour drags it toward grey — which is precisely why the first
        // attempt came out muted. Soft light lightens without desaturating, so
        // the extra chroma in the palette survives the lighting.
        var lighting = context
        lighting.blendMode = .softLight
        lighting.fill(
            silhouette,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0.85), location: 0),
                    .init(color: .white.opacity(0.25), location: 0.34),
                    .init(color: .clear, location: 0.54),
                    .init(color: .black.opacity(0.40), location: 1),
                ]),
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)
            )
        )

        // The glass part: one broad specular dome across the top, clipped to the
        // rings so it never spills into the gaps or past the rim.
        var gloss = context
        gloss.clip(to: silhouette)
        let dome = Path(ellipseIn: CGRect(
            x: center.x - radius * 1.15,
            y: center.y - radius * 1.62,
            width: radius * 2.3,
            height: radius * 1.85
        ))
        gloss.fill(
            dome,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(isDark ? 0.20 : 0.26), location: 0),
                    .init(color: .white.opacity(isDark ? 0.07 : 0.10), location: 0.55),
                    .init(color: .clear, location: 1),
                ]),
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius * 0.12)
            )
        )
    }

    /// Just the outer boundary of a slice, as a stroke-able path.
    private func outerEdge(
        center: CGPoint, radius: Double,
        startAngle: Double, endAngle: Double, gapRadians: Double
    ) -> Path? {
        let start = startAngle + gapRadians / 2
        let end = endAngle - gapRadians / 2
        guard end > start, radius > 0 else { return nil }
        var path = Path()
        path.addArc(
            center: center, radius: radius,
            startAngle: .radians(start), endAngle: .radians(end),
            clockwise: false
        )
        return path
    }

    /// Labels only where they genuinely fit — the light-mode palette sits below
    /// 3:1 on three hues, so visible labels are the required relief, but a label
    /// crammed into a sliver is worse than none.
    private func drawLabels(
        context: GraphicsContext, metrics: Metrics,
        shapes: [(arc: Arc, path: Path, opacity: Double)]
    ) {
        guard transition >= 1, let store = model.store else { return }
        let ringWidth = metrics.ringWidth
        guard ringWidth >= 14 else { return }

        for (arc, path, _) in shapes where arc.sweep > 0.18 {
            let radius = metrics.radius(ring: arc.ring, fraction: 0.5)

            // The text is drawn horizontally, so what it has to fit inside is
            // the chord across the slice, not the arc length along it. Near 3
            // and 9 o'clock those two are perpendicular, which is how long
            // names used to spill over the neighbouring rings.
            let chord = 2 * radius * sin(min(arc.sweep, .pi) / 2)
            let available = min(chord, ringWidth * 3.4) - 6
            guard available >= 26 else { continue }

            let name: String
            if let node = arc.node {
                name = store.name(of: node)
            } else {
                name = "Autres (\(arc.mergedCount))"
            }
            guard let resolved = fittedLabel(
                name, width: available, context: context
            ) else { continue }

            let point = CGPoint(
                x: metrics.center.x + cos(arc.midAngle) * radius,
                y: metrics.center.y + sin(arc.midAngle) * radius
            )

            // Clipped to its own slice. The geometry above should be enough,
            // but a label escaping its slice is the most visible defect there
            // is, so it is also made impossible.
            var layer = context
            layer.clip(to: path)
            layer.addFilter(.shadow(
                color: (isDark ? Color.black : Color.white).opacity(0.55),
                radius: 1.5
            ))
            layer.draw(resolved, at: point)
        }
    }

    /// The name, truncated with an ellipsis until it fits, or nil if even one
    /// character will not.
    ///
    /// Measured against `greatestFiniteMagnitude`: measuring inside the width
    /// we are testing against returns a value clamped to that width, so the
    /// comparison could never fail. The treemap hit the same trap.
    private func fittedLabel(
        _ name: String, width: Double, context: GraphicsContext
    ) -> GraphicsContext.ResolvedText? {
        let unbounded = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        func resolve(_ string: String) -> GraphicsContext.ResolvedText {
            context.resolve(
                Text(string)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isDark ? .white : .black)
            )
        }

        let full = resolve(name)
        let fullWidth = full.measure(in: unbounded).width
        if fullWidth <= width { return full }
        guard fullWidth > 0 else { return nil }

        // Estimate from the average character width rather than removing one
        // character at a time: a per-character loop would resolve text dozens
        // of times per label, every frame.
        let characters = Array(name)
        var count = min(
            characters.count - 1,
            max(1, Int(Double(characters.count) * width / fullWidth) - 1)
        )
        for _ in 0..<6 {
            guard count >= 1 else { return nil }
            let candidate = resolve(String(characters[0..<count]) + "…")
            if candidate.measure(in: unbounded).width <= width { return candidate }
            count -= max(1, count / 8)
        }
        return nil
    }

    private func annularSector(
        center: CGPoint,
        innerRadius: Double,
        outerRadius: Double,
        startAngle: Double,
        endAngle: Double,
        gapRadians: Double
    ) -> Path? {
        let start = startAngle + gapRadians / 2
        let end = endAngle - gapRadians / 2
        guard end > start, outerRadius > innerRadius else { return nil }

        func point(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }

        var path = Path()
        path.move(to: point(innerRadius, start))
        path.addLine(to: point(outerRadius, start))
        path.addArc(
            center: center, radius: outerRadius,
            startAngle: .radians(start), endAngle: .radians(end),
            clockwise: false
        )
        path.addLine(to: point(innerRadius, end))
        path.addArc(
            center: center, radius: innerRadius,
            startAngle: .radians(end), endAngle: .radians(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }

    // MARK: - Interaction

    private func handleTap(at location: CGPoint, metrics: Metrics) {
        let relative = metrics.relative(location)
        let distance = (relative.x * relative.x + relative.y * relative.y).squareRoot()
        if distance <= metrics.innerRadius {
            model.goUp()
            return
        }
        // Outside the disc is not a miss, it is not a target at all. Clearing
        // the selection there meant clicking the empty corners of the view
        // silently undid what the user had picked.
        guard distance <= metrics.outerRadius else { return }

        guard let arc = SunburstLayout.hitTest(
            arcs: arcs, point: relative,
            innerRadius: metrics.innerRadius, ringWidth: metrics.ringWidth
        ) else {
            model.selection = []
            return
        }
        guard let node = arc.node else {
            // The one slice that hides its contents now says what it hides.
            if !arc.mergedNodes.isEmpty { othersArc = arc }
            return
        }
        model.activate(node)
    }

    private func tooltipText(for arc: Arc) -> [String]? {
        guard let store = model.store else { return nil }
        guard let node = arc.node else {
            return [
                "\(arc.mergedCount) autres éléments",
                Format.bytes(arc.size),
            ]
        }
        let files = store.fileCount[Int(node)]
        return [
            store.name(of: node),
            "\(Format.bytes(arc.size)) · \(Format.count(Int(files))) fichiers",
        ]
    }

    // MARK: - Geometry

    private struct Metrics {
        let center: CGPoint
        let innerRadius: Double
        let outerRadius: Double
        /// Rings the tree actually fills. Dividing by a constant instead left
        /// three quarters of the disc empty for a folder one level deep.
        let rings: Int

        init(size: CGSize, rings: Int) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The margin has to hold the drop shadow, not just the disc: at 14
            // the shadow was clipped flat by the bottom of the canvas, which
            // read as the status bar cutting it off.
            outerRadius = max(40, min(size.width, size.height) / 2 - 26)
            innerRadius = outerRadius * 0.23
            self.rings = max(1, rings)
        }

        var ringWidth: Double { (outerRadius - innerRadius) / Double(rings) }

        func radius(ring: Int, fraction: Double) -> Double {
            innerRadius + (Double(ring - 1) / Double(rings) + fraction / Double(rings))
                * (outerRadius - innerRadius)
        }

        func relative(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - center.x, y: point.y - center.y)
        }
    }
}

// MARK: - Others

/// What an aggregated slice stands for.
///
/// The merge threshold keeps the chart readable, but it is also the only place
/// where the picture stops telling the truth about what is there. This is the
/// way back in.
private struct OthersSheet: View {
    let model: ScanModel
    let arc: Arc
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(arc.mergedCount) éléments trop petits pour être dessinés")
                        .font(.headline)
                    Text("\(Format.bytes(arc.size)) au total")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            List(rows, id: \.self) { node in
                if let store = model.store {
                    HStack(spacing: 8) {
                        Image(systemName: store.isDirectory(node) ? "folder" : "doc")
                            .foregroundStyle(.secondary)
                        Text(store.name(of: node))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(Format.bytes(model.size(of: node)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        model.activate(node)
                        onDismiss()
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Spacer()
                Button("Fermer", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 380)
    }

    /// Already sorted largest first by the layout; capped because an "others"
    /// slice can stand for tens of thousands of entries and no one scrolls that.
    private var rows: [Int32] { Array(arc.mergedNodes.prefix(200)) }
}

// MARK: - Overlays

private struct CenterLabel: View {
    let model: ScanModel
    let hovered: Arc?

    var body: some View {
        VStack(spacing: 2) {
            if let store = model.store {
                Text(store.name(of: model.currentNode))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(Format.bytes(model.size(of: model.currentNode)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if model.trail.count > 1 {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            }
        }
        .padding(6)
    }
}

