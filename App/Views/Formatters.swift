import SwiftUI

enum Format {
    /// Finder shows decimal sizes (1 GB = 1 000 000 000 bytes). The engine works
    /// in binary units, but users compare these numbers against Finder and the
    /// Storage pane, so the UI must speak the same dialect.
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
    }
}

extension ShapeStyle where Self == Color {
    /// Fill behind a row, sized to the row's share of its parent.
    static var proportionBar: Color { .accentColor.opacity(0.14) }
}
