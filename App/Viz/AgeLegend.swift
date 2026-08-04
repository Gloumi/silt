import SwiftUI

/// Names the five steps of the age ramp, for the treemap and the sunburst.
///
/// A sequential scale is unreadable without one — a block is "quite dark", which
/// means nothing until something on screen says dark is old. It floats over the
/// drawing rather than taking a band of its own underneath, so switching colour
/// modes never resizes the canvas, and it exists only while the age mode is on:
/// nobody who keeps the folder colours pays a pixel for it.
struct AgeLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            compact
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(radius: 3, y: 1)
        // Purely a caption: it must never eat a click meant for the block
        // underneath it.
        .allowsHitTesting(false)
    }

    private var full: some View {
        HStack(spacing: 10) {
            ForEach(AgeBand.allCases) { band in
                HStack(spacing: 4) {
                    swatch(band)
                    Text(band.shortLabel)
                }
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
    }

    /// Narrow windows: the ramp still reads left to right, only the middle
    /// labels go — the two ends are what fix its direction.
    private var compact: some View {
        HStack(spacing: 5) {
            Text("récent")
            HStack(spacing: 2) {
                ForEach(AgeBand.allCases) { swatch($0) }
            }
            Text("ancien")
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
    }

    /// Outlined like the blocks themselves — the palest band would otherwise
    /// vanish into the material this sits on.
    private func swatch(_ band: AgeBand) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Palette.age(band, dark: isDark))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Palette.ageEdge(band, dark: isDark), lineWidth: 0.75)
            }
            .frame(width: 11, height: 11)
    }
}
