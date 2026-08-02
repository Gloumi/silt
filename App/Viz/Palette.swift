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
///    does not get a new hue — it folds into a neutral "others" slice.
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

    /// Slice that absorbs everything past the eighth sibling, plus all the
    /// slivers too thin to draw. Deliberately colourless: it is not a category,
    /// it is the absence of one.
    static func otherColor(dark: Bool) -> Color {
        dark ? Color(white: 0.42) : Color(white: 0.66)
    }

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
            let grey = dark ? 0.42 : 0.66
            return Color(white: grey + siblingOffset(sibling, ring: ring) + boost)
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

    /// Slightly deeper variant of a slice's colour, for the inner edge of a
    /// radial gradient. Gives the rings a sense of depth instead of reading as
    /// flat paint.
    static func deepened(
        slot: Int, ring: Int, sibling: Int, dark: Bool
    ) -> Color {
        guard slot >= 0 else {
            return Color(white: (dark ? 0.42 : 0.66) + siblingOffset(sibling, ring: ring) - 0.05)
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
