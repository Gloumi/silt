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
struct ViewModeSwitcher: View {
    let model: ScanModel

    @State private var hovered: ScanModel.Presentation?
    @Namespace private var selectionShape

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ScanModel.Presentation.allCases) { mode in
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
