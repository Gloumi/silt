import SwiftUI

/// Perceptual colour space (Björn Ottosson's OKLab).
///
/// Everything here happens in OKLab rather than RGB because the ring shading
/// needs *perceptually* even steps: equal RGB steps look wildly uneven, which is
/// exactly what makes a naive sunburst look muddy in the middle and washed out
/// at the edge.
struct OKLab {
    var L: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }

    /// Scales chroma while keeping hue and lightness.
    func withChroma(scale: Double) -> OKLab {
        OKLab(L: L, a: a * scale, b: b * scale)
    }

    func withLightness(_ newL: Double) -> OKLab {
        OKLab(L: newL, a: a, b: b)
    }

    // MARK: - Conversion

    init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }

    init(hex: UInt32) {
        let r = Self.toLinear(Double((hex >> 16) & 0xFF) / 255)
        let g = Self.toLinear(Double((hex >> 8) & 0xFF) / 255)
        let bl = Self.toLinear(Double(hex & 0xFF) / 255)

        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)

        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var color: Color {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)

        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        return Color(
            .sRGB,
            red: Self.fromLinear(r),
            green: Self.fromLinear(g),
            blue: Self.fromLinear(bl)
        )
    }

    private static func toLinear(_ c: Double) -> Double {
        c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
    }

    private static func fromLinear(_ c: Double) -> Double {
        let clamped = min(1, max(0, c))
        return clamped > 0.0031308
            ? 1.055 * pow(clamped, 1 / 2.4) - 0.055
            : 12.92 * clamped
    }
}

/// What the treemap and the sunburst encode in their colours.
///
/// Two genuinely different questions — "which branch is this" and "how long has
/// this been sitting here" — and no way to answer both at once in one hue. So it
/// is a mode, not a blend.
enum ColorMode: String, CaseIterable, Identifiable {
    case category, age

    var id: String { rawValue }

    var label: String {
        switch self {
        case .category: "Couleur par dossier"
        case .age: "Couleur par ancienneté"
        }
    }

    /// Each symbol is the literal noun of its label — a folder, a calendar.
    /// Anything cleverer (a palette, a clock) has to be learned, and a clock at
    /// this size is one rounded rectangle away from a disk icon.
    var symbol: String {
        switch self {
        case .category: "folder"
        case .age: "calendar"
        }
    }
}

/// Colour assignment for the sunburst and the treemap.
///
/// Two rules, both load-bearing:
///
/// 1. **Hues are a fixed list, assigned in angular order — never hashed, never
///    cycled.** Slot order is the colourblind-safety mechanism: this exact
///    sequence was validated so that every *neighbouring* pair stays separable
///    (worst protanopia ΔE 9.1 light / 8.4 dark, worst normal-vision ΔE 19.6 /
///    19.3). Because slices are painted in slot order around the circle, visual
///    adjacency and slot adjacency are the same thing. The seam where the last
///    slice meets the first was checked too (ΔE 21.6 protan). A ninth sibling
///    does not get a new hue — it is drawn in a neutral grey instead. Only
///    slices too thin to see fold into "others": the eight-hue limit is about
///    telling categories apart, never about hiding one.
///
/// 2. **Depth is a sequential ramp on the branch's own hue**, so a whole subtree
///    reads as one family and the eye can follow it outward.
enum Palette {
    /// Validated categorical order: blue, orange, aqua, yellow, magenta, green,
    /// violet, red.
    ///
    /// Chroma raised by 12 % over the first version, which read as muted on a
    /// dark surface. Done in OKLab at constant lightness, and **gamut-mapped**:
    /// where sRGB cannot hold the extra chroma at that lightness the boost is
    /// reduced instead of letting the conversion clip. Clipping is not neutral —
    /// it drags lightness with it, and the naive version pushed the dark yellow
    /// out of its validated band by exactly that mechanism. Aqua and green
    /// therefore gained little; they were already at the edge of the gamut.
    private static let lightHexes: [UInt32] = [
        0x1676E1, 0xF45F1C, 0x00B079, 0xEDA100,
        0xEF75A4, 0x008300, 0x4B34B1, 0xEC3A3E,
    ]
    private static let darkHexes: [UInt32] = [
        0x2986F0, 0xE15004, 0x009F6F, 0xC98500,
        0xDD4680, 0x008300, 0x9082F3, 0xEE5F61,
    ]

    static let slotCount = 8

    private static func base(slot: Int, dark: Bool) -> OKLab {
        let hexes = dark ? darkHexes : lightHexes
        return OKLab(hex: hexes[slot % hexes.count])
    }

    /// Lightness offset that separates neighbouring siblings.
    ///
    /// From the second ring outward every child of a branch inherits the same
    /// hue, so without this a large folder reads as one flat wedge and the gaps
    /// have to do all the work. A three-step cycle guarantees adjacent siblings
    /// differ, while staying far too small to be mistaken for a category change.
    ///
    /// It deliberately does **not** apply to the first ring: there each child
    /// already carries its own hue, so the nudge would buy nothing — and it
    /// would push the eighth slot out of the validated lightness band, which is
    /// exactly what the palette checks caught.
    private static func siblingOffset(_ index: Int, ring: Int) -> Double {
        guard ring > 1 else { return 0 }
        return [0.0, 0.045, 0.022][index % 3]
    }

    /// Lightness spread for the neutral slices — the ninth sibling onward.
    ///
    /// Wider than the coloured nudge and applied on every ring, because grey is
    /// all these have: without it a folder with twenty entries drew a dozen
    /// identical grey wedges. There is no validated band to protect here, which
    /// is exactly why the coloured version stays off the first ring.
    private static func neutralOffset(_ index: Int) -> Double {
        [0.0, 0.075, 0.037, 0.110][index % 4]
    }

    /// How much the outer rings drift from their base hue.
    ///
    /// Kept small on purpose. Fading hard toward white with depth is the usual
    /// way sunbursts end up looking washed out; here the outer rings stay
    /// recognisably the same colour as the branch they belong to.
    private static let lightnessPerRing = 0.038
    private static let chromaLossPerRing = 0.03

    /// Colour for a slice in `slot`'s branch at `ring` rings from the centre.
    ///
    /// Ring 1 is the base hue. Deeper rings step lighter and slightly less
    /// saturated — away from the surface in both light and dark mode, so the
    /// outer rings never sink into the background.
    static func color(
        slot: Int, ring: Int, sibling: Int = 0, dark: Bool
    ) -> Color {
        shade(slot: slot, ring: ring, sibling: sibling, dark: dark, boost: 0)
    }

    /// Hover highlight: same hue, pushed toward the light end.
    static func highlighted(
        slot: Int, ring: Int, sibling: Int = 0, dark: Bool
    ) -> Color {
        shade(slot: slot, ring: ring, sibling: sibling, dark: dark, boost: 0.11)
    }

    private static func shade(
        slot: Int, ring: Int, sibling: Int, dark: Bool, boost: Double
    ) -> Color {
        guard slot >= 0 else {
            let grey = dark ? 0.40 : 0.62
            return Color(white: grey + neutralOffset(sibling) + boost)
        }
        let base = base(slot: slot, dark: dark)
        let step = Double(max(0, ring - 1))
        return base
            .withLightness(
                min(0.93, base.L + step * lightnessPerRing
                    + siblingOffset(sibling, ring: ring) + boost)
            )
            .withChroma(scale: max(0.8, 1 - step * chromaLossPerRing))
            .color
    }

    // MARK: - Age ramp

    /// Sequential ramp for the age mode: one warm hue, five steps of lightness.
    ///
    /// A single hue on purpose. Age is an *ordinal* variable, and the moment
    /// lightness alone carries the order the scale survives every kind of colour
    /// blindness without a pairwise check — which is the opposite problem from
    /// the categorical palette above, where the whole difficulty is that eight
    /// hues have to stay apart.
    ///
    /// The dark ramp does not simply mirror the light one: pushing "old" as far
    /// down there as it goes here would sink the oldest blocks into the
    /// background, so the range is compressed upward and the darkest step stays
    /// clearly above the surface it sits on.
    private static let lightAgeHexes: [UInt32] = [
        0xFBE0A6, 0xF3C171, 0xE09E44, 0xC0782A, 0x9A5A1C,
    ]
    private static let darkAgeHexes: [UInt32] = [
        0xF7D08A, 0xE6AC55, 0xCE8A32, 0xA96C25, 0x82511E,
    ]

    /// Colour for a slice of a given age. Nil means no date — an aggregated
    /// "others" tile, or a filesystem that gave us nothing — and is painted
    /// neutral rather than guessed at.
    ///
    /// Depth plays no part here, unlike the categorical mode: in this mode the
    /// lightness *is* the reading, and shading it by ring would make two blocks
    /// of the same age look different.
    static func age(_ band: AgeBand?, dark: Bool, boost: Double = 0) -> Color {
        guard let band else { return Color(white: (dark ? 0.40 : 0.62) + boost) }
        let hexes = dark ? darkAgeHexes : lightAgeHexes
        let base = OKLab(hex: hexes[band.rawValue])
        return base.withLightness(min(0.93, base.L + boost)).color
    }

    /// Hover highlight for the age mode.
    ///
    /// Half the nudge the categorical mode uses, because here lightness carries
    /// the meaning: a full highlight would move a block a whole band up the
    /// legend. The views draw an outline as well, which is what actually says
    /// "this one" — the lift only keeps the feedback immediate.
    static func ageHighlighted(_ band: AgeBand?, dark: Bool) -> Color {
        age(band, dark: dark, boost: 0.05)
    }

    /// Inner edge of the sunburst's radial gradient, age mode.
    static func ageDeepened(_ band: AgeBand?, dark: Bool) -> Color {
        guard let band else { return Color(white: (dark ? 0.40 : 0.62) - 0.05) }
        let hexes = dark ? darkAgeHexes : lightAgeHexes
        let base = OKLab(hex: hexes[band.rawValue])
        return base.withLightness(max(0.2, base.L - 0.085)).color
    }

    /// Hairline around a block in the age mode.
    ///
    /// The categorical palette separates neighbours by *being* different
    /// colours, helped by the sibling nudge. This ramp cannot: two folders in
    /// the same band are the same paint down to the pixel, and the gap between
    /// them only shows their parent — the same paint again — so a row of blocks
    /// welds into one slab. The edge is drawn in the block's own hue, a step
    /// darker, which restores the boundary without adding a second colour the
    /// eye has to interpret.
    static func ageEdge(_ band: AgeBand?, dark: Bool) -> Color {
        guard let band else { return Color(white: (dark ? 0.40 : 0.62) - 0.13) }
        let hexes = dark ? darkAgeHexes : lightAgeHexes
        let base = OKLab(hex: hexes[band.rawValue])
        return base.withLightness(max(0.18, base.L - 0.15))
            .withChroma(scale: 1.05)
            .color
    }

    /// Label ink for a block in the age mode, plus the halo behind it.
    ///
    /// The categorical palette keeps its lightness roughly level across the
    /// eight hues, so one ink per theme carries every slice. This ramp is built
    /// on the opposite principle — lightness *is* the variable, running from
    /// near-white down to a deep rust — so the text has to follow the block it
    /// sits on rather than the window it sits in. White on the first bands is
    /// what made the recent folders unreadable.
    static func ageInk(_ band: AgeBand?, dark: Bool) -> (text: Color, halo: Color) {
        let onLightBackground: Bool
        if let band {
            let hexes = dark ? darkAgeHexes : lightAgeHexes
            onLightBackground = OKLab(hex: hexes[band.rawValue]).L > 0.62
        } else {
            // The neutral grey, which is light in light mode and dark in dark.
            onLightBackground = !dark
        }
        return onLightBackground ? (.black, .white) : (.white, .black)
    }

    /// Slightly deeper variant of a slice's colour, for the inner edge of a
    /// radial gradient. Gives the rings a sense of depth instead of reading as
    /// flat paint.
    static func deepened(
        slot: Int, ring: Int, sibling: Int, dark: Bool
    ) -> Color {
        guard slot >= 0 else {
            return Color(white: (dark ? 0.40 : 0.62) + neutralOffset(sibling) - 0.05)
        }
        let base = base(slot: slot, dark: dark)
        let step = Double(max(0, ring - 1))
        return base
            .withLightness(
                max(0.2, base.L + step * lightnessPerRing
                    + siblingOffset(sibling, ring: ring) - 0.085)
            )
            .withChroma(scale: max(0.8, 1 - step * chromaLossPerRing))
            .color
    }
}
