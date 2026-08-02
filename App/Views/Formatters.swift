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

    /// How old a cached scan is. Under a minute reads as "à l'instant" rather
    /// than "il y a 0 minute".
    static func age(since date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        guard seconds >= 60 else { return "à l'instant" }
        return date.formatted(.relative(presentation: .named))
    }
}

extension ShapeStyle where Self == Color {
    /// Fill behind a row, sized to the row's share of its parent.
    static var proportionBar: Color { .accentColor.opacity(0.14) }
}
