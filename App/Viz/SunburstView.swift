import DiskCore
import SwiftUI

struct SunburstView: View {
    let model: ScanModel

    static let maxRings = 4

    @Environment(\.colorScheme) private var colorScheme
    @State private var arcs: [Arc] = []
    /// Geometry of the previous layout, keyed by node, used to animate a drill.
    @State private var previousGeometry: [Int32: Arc] = [:]
    @State private var transition: Double = 1
    /// Scan the current arcs were built from. Node indices are only meaningful
    /// within one store, so geometry from a previous scan must never be reused.
    @State private var builtScanID = -1
    @State private var hovered: Arc?
    @State private var hoverPoint: CGPoint = .zero

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            let metrics = Metrics(size: geometry.size)

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
                    case .ended:
                        hovered = nil
                    }
                }
                // Single click selects (feeding the inspector), double click
                // drills in. Without the first, the rings would be the only
                // view from which nothing can be inspected or deleted.
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { event in
                            handleTap(at: event.location, metrics: metrics, drill: true)
                        }
                )
                .gesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            handleTap(at: event.location, metrics: metrics, drill: false)
                        }
                )

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
        }
        // Only a drill within the same scan animates. A new scan, a switch of
        // size mode, or simply coming back to this tab rebuilds instantly —
        // re-running an animation there reads as if the app were re-analysing.
        .onChange(of: model.scanID, initial: true) { rebuild(animated: false) }
        .onChange(of: model.currentNode) { rebuild(animated: true) }
        .onChange(of: model.useLogicalSize) { rebuild(animated: false) }
        // Redraw as the scan fills the tree in.
        .onChange(of: model.rows.count) { rebuild(animated: false) }
    }

    // MARK: - Layout lifecycle

    private func rebuild(animated: Bool) {
        guard let store = model.store else { arcs = []; return }

        let sameScan = builtScanID == model.scanID
        var geometryByNode: [Int32: Arc] = [:]
        if sameScan {
            for arc in arcs {
                if let node = arc.node { geometryByNode[node] = arc }
            }
        }
        previousGeometry = geometryByNode
        builtScanID = model.scanID

        arcs = SunburstLayout.build(
            store: store,
            root: model.currentNode,
            maxRings: Self.maxRings,
            useLogicalSize: model.useLogicalSize
        )
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
        let ringFraction = 1.0 / Double(Self.maxRings)

        for arc in arcs {
            let (shape, opacity) = interpolated(arc)
            // Fractional ring during the transition would need radius easing
            // too; the angular slide already carries the motion.
            let inner = metrics.radius(ring: shape.ring, fraction: 0)
            let outer = metrics.radius(ring: shape.ring, fraction: ringFraction)

            guard let path = annularSector(
                center: metrics.center,
                innerRadius: inner + 0.5,
                outerRadius: outer - 1.5,
                startAngle: shape.startAngle,
                endAngle: shape.endAngle,
                gapRadians: min(0.010, shape.sweep * 0.07)
            ) else { continue }

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

            if isSelected {
                context.stroke(
                    path,
                    with: .color(isDark ? .white : .black),
                    lineWidth: 1.5
                )
            }
        }

        drawLabels(context: context, metrics: metrics, ringFraction: ringFraction)
    }

    /// Labels only where they genuinely fit — the light-mode palette sits below
    /// 3:1 on three hues, so visible labels are the required relief, but a label
    /// crammed into a sliver is worse than none.
    private func drawLabels(
        context: GraphicsContext, metrics: Metrics, ringFraction: Double
    ) {
        for arc in arcs where arc.sweep > 0.22 && arc.ring <= 3 {
            guard transition >= 1, let node = arc.node, let store = model.store
            else { continue }

            let radius = (metrics.radius(ring: arc.ring, fraction: 0)
                + metrics.radius(ring: arc.ring, fraction: ringFraction)) / 2
            let point = CGPoint(
                x: metrics.center.x + cos(arc.midAngle) * radius,
                y: metrics.center.y + sin(arc.midAngle) * radius
            )

            let text = Text(store.name(of: node))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isDark ? .white : .black)
            let resolved = context.resolve(text)
            let measured = resolved.measure(in: CGSize(width: 200, height: 20))

            // Chord available at this radius; skip if the name cannot fit.
            guard measured.width < arc.sweep * radius * 0.92 else { continue }
            context.draw(resolved, at: point)
        }
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

    private func handleTap(at location: CGPoint, metrics: Metrics, drill: Bool) {
        let relative = metrics.relative(location)
        let distance = (relative.x * relative.x + relative.y * relative.y).squareRoot()
        if distance <= metrics.innerRadius {
            model.goUp()
            return
        }
        guard let arc = SunburstLayout.hitTest(
            arcs: arcs, point: relative,
            innerRadius: metrics.innerRadius, ringWidth: metrics.ringWidth
        ), let node = arc.node else {
            model.selection = []
            return
        }
        if drill {
            model.enter(node)
        } else {
            model.selection = [node]
        }
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

        init(size: CGSize) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            outerRadius = max(40, min(size.width, size.height) / 2 - 14)
            innerRadius = outerRadius * 0.23
        }

        var ringWidth: Double {
            (outerRadius - innerRadius) / Double(SunburstView.maxRings)
        }

        func radius(ring: Int, fraction: Double) -> Double {
            innerRadius + (Double(ring - 1) / Double(SunburstView.maxRings) + fraction)
                * (outerRadius - innerRadius)
        }

        func relative(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - center.x, y: point.y - center.y)
        }
    }
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

private struct Tooltip: View {
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
