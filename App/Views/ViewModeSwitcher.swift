import SwiftUI

/// Icon-only switch between the three views, with tooltips that appear at once.
///
/// Hand-rolled rather than a `Picker(.segmented)` for one reason: `.help()`
/// routes through AppKit's tooltip service, which imposes its own delay and
/// offers no way to shorten it. Drawing the label here means it shows the
/// instant the pointer arrives.
///
/// It lives in the breadcrumb bar rather than the window toolbar because a
/// toolbar clips its items, and the tooltip has to hang below the control.
/// A lone action in the trailing group of the breadcrumb bar, shaped like the
/// switchers it sits next to.
///
/// Same capsule, same 24pt row, same hover fill — so the three controls read as
/// one cluster instead of a bare glyph pushed up against two pills.
struct BarButton: View {
    let symbol: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // `primary`, not the accent colour: tinted, it read as the one thing to
        // press in the bar, when it is an everyday utility sitting beside two
        // selectors. This is the same ink their active segment uses.
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .background {
            if hovered, isEnabled { Capsule().fill(.quaternary) }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .onHover { hovered = $0 }
        .disabled(!isEnabled)
        .help(help)
    }
}

/// Picks what the drawn views colour by, right beside the view switcher.
///
/// The menu and ⌥⌘1 / ⌥⌘2 already did this, and that was the mistake: reading an
/// age map means flicking back to the folder map and back again, over and over,
/// and a mode you have to open a menu to leave is a mode you stop trying.
///
/// Two segments rather than one button that lights up: a lone toggle only ever
/// shows you the state you are *not* in — you have to know what unlit means.
/// Side by side, both modes are named and the lit one is the answer.
///
/// Gone entirely in the views it does not apply to, not merely dimmed: it sits
/// at the *left* end of the bar's trailing run, so its coming and going eats
/// into the flexible space instead of sliding the refresh button and the view
/// switcher — which keep a constant distance from the window edge either way.
/// An invisible-but-present slot was tried first and read as a hole in the bar.
struct ColorModeSwitcher: View {
    let model: ScanModel

    @State private var hovered: ColorMode?
    @Namespace private var selectionShape

    private var applies: Bool {
        ScanModel.Presentation.charts.contains(model.presentation)
    }

    var body: some View {
        if applies {
            HStack(spacing: 2) {
                ForEach(ColorMode.allCases) { mode in
                    segment(mode)
                }
            }
            .padding(2)
            .background(.quaternary.opacity(0.6), in: .capsule)
            .overlay(alignment: .bottom) { tooltip }
        }
    }

    private func segment(_ mode: ColorMode) -> some View {
        let isSelected = model.colorMode == mode
        return Button {
            model.colorMode = mode
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(radius: 0.5, y: 0.5)
                    .matchedGeometryEffect(id: "colorSelection", in: selectionShape)
            } else if hovered == mode {
                Capsule().fill(.quaternary)
            }
        }
        .animation(.snappy(duration: 0.18), value: model.colorMode)
        .onHover { inside in
            if inside {
                hovered = mode
            } else if hovered == mode {
                hovered = nil
            }
        }
        .accessibilityLabel(mode.label)
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered {
            Text(hovered.label)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .shadow(radius: 3, y: 1)
                .fixedSize()
                .offset(y: 26)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

struct ViewModeSwitcher: View {
    let model: ScanModel

    @State private var hovered: ScanModel.Presentation?
    @Namespace private var selectionShape

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ScanModel.Presentation.browsing) { mode in
                segment(mode)
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .overlay(alignment: .bottom) { tooltip }
    }

    private func segment(_ mode: ScanModel.Presentation) -> some View {
        let isSelected = model.presentation == mode
        return Button {
            model.presentation = mode
        } label: {
            Image(systemName: mode.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(radius: 0.5, y: 0.5)
                    .matchedGeometryEffect(id: "selection", in: selectionShape)
            } else if hovered == mode {
                Capsule().fill(.quaternary)
            }
        }
        .animation(.snappy(duration: 0.18), value: model.presentation)
        .onHover { inside in
            if inside {
                hovered = mode
            } else if hovered == mode {
                hovered = nil
            }
        }
        .accessibilityLabel(mode.label)
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered {
            Text(hovered.label)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .shadow(radius: 3, y: 1)
                .fixedSize()
                .offset(y: 26)
                // Never intercept the pointer: doing so would flicker the hover
                // state the tooltip itself depends on.
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
