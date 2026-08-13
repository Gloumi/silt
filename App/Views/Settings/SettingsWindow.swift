import SwiftUI

/// The settings window: one subject per pane, picked from a sidebar.
///
/// A single grouped Form held all of this until the two duplicate thresholds
/// and their estimate arrived, at which point four sections and some fourteen
/// hundred characters of explanation were sharing one 460 pt column and the
/// window scrolled. Splitting it is only worth doing because there was also
/// something to add: the pinned folders and their per-folder view were
/// reachable from a context menu and nowhere else, and there was no way back
/// to the defaults short of `defaults delete`.
///
/// A sidebar rather than the toolbar tabs of the old Preferences window,
/// because tabs re-size the window on every switch — under a `Settings` scene
/// the ideal size is the selected tab's — and a pane with two pickers next to
/// one with two sliders and a four-state estimator would make the window jump
/// every time. Here the size constraint lives on the scene, outside the
/// switch, so changing pane cannot move anything.
struct SettingsWindow: View {
    let model: ScanModel
    @State private var pane: SettingsPane = .general
    /// Panes visited, and where in them we are. Drives the back/forward pair,
    /// which System Settings puts in the same place.
    @State private var history: [SettingsPane] = [.general]
    @State private var cursor = 0

    var body: some View {
        // No `columnVisibility` binding, and none needed: the app files its own
        // ⌃⌘S against the browser window's state rather than taking the one
        // `SidebarCommands()` aims at whichever window is key. See SiltApp.
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label { Text(pane.title) } icon: { PaneBadge(pane: pane) }
                    .tag(pane)
            }
            .listStyle(.sidebar)
            // 215 pt is what System Settings uses, and the three bounds are
            // equal so the divider stays put. Spelled as a range rather than
            // through the single-value overload: that one is a constraint
            // reapplied after the fact, and it landed a visible jump at the end
            // of the reveal animation — the column animated open, then snapped.
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
            // No way to fold the pane list away, which is the point: it is the
            // only way around this window. It also takes the jump with it —
            // mid-reveal AppKit could not place the toggle and showed the
            // toolbar's overflow chevron, then re-laid the bar out once the
            // column had arrived.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                // Names the pane in the titlebar, the way System Settings does,
                // rather than saying "Réglages" forever.
                .navigationTitle(pane.title)
                .toolbar {
                    ToolbarItem(placement: .navigation) { navigationButtons }
                }
        }
    }

    /// Back and forward through the panes visited, at the head of the detail
    /// column — where System Settings keeps its own pair.
    ///
    /// `navigation` alone does not put them there. It is a *semantic* placement:
    /// SwiftUI "determines the appropriate placement for the item based on this
    /// intent and its surrounding context", and the style of the group is part
    /// of that context. Left at the default style the very same placement
    /// resolved to the trailing edge of the window; given `.navigation`, the
    /// style macOS draws back/forward pairs in, it resolves to the head of the
    /// column. `fixedSize` keeps the group from stretching to fill the slot.
    ///
    /// Two placements that do not work, so nobody tries them again: asked for
    /// from the pane list, `.navigation` lands in the titlebar above the list,
    /// on the wrong side of the divider; `.principal` centres, taking the title
    /// with it.
    ///
    /// Keeping them is not only about navigation. With no toolbar item at all
    /// SwiftUI installs no toolbar, and with no toolbar the window stops running
    /// its content under the titlebar — which is exactly what lifts the pane
    /// list up behind the traffic lights. The fold button used to hold the bar
    /// open and was bad at it: mid-reveal it sat between the two columns, AppKit
    /// could not place it, showed the overflow chevron, then re-laid the bar out
    /// once the column had landed. That was the jump, and dropping the button is
    /// also what makes the pane list unfoldable — which it should be, being the
    /// only way around this window.
    private var navigationButtons: some View {
        ControlGroup {
            Button {
                cursor -= 1
                pane = history[cursor]
            } label: {
                Label("Précédent", systemImage: "chevron.backward")
            }
            .disabled(cursor == 0)
            .keyboardShortcut("[", modifiers: .command)

            Button {
                cursor += 1
                pane = history[cursor]
            } label: {
                Label("Suivant", systemImage: "chevron.forward")
            }
            .disabled(cursor >= history.count - 1)
            .keyboardShortcut("]", modifiers: .command)
        }
        .controlGroupStyle(.navigation)
        .fixedSize()
    }

    /// A List hands back nil when its row is deselected — command-clicking the
    /// current pane does it — and "no pane" is not a state these settings have.
    ///
    /// The only place that records history: going back must not itself be a
    /// step forward.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }) { new in
            guard let new, new != pane else { return }
            pane = new
            // Anything ahead of the cursor is a branch nobody took.
            if cursor + 1 < history.count {
                history.removeSubrange((cursor + 1)...)
            }
            history.append(new)
            cursor = history.count - 1
        }
    }

    /// No frame anywhere in here. The scene carries the size (see SiltApp), so
    /// a short pane and a tall one produce the same window, and each pane is a
    /// grouped Form that scrolls on its own when it needs to.
    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .scanning: ScanSettings()
        case .duplicates: DuplicatesSettings()
        case .locations: LocationsSettings(model: model)
        case .permissions: PermissionsSettings()
        }
    }
}

// MARK: - The panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, scanning, duplicates, locations, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Général"
        case .appearance: "Apparence"
        case .scanning: "Analyse"
        case .duplicates: "Doublons"
        case .locations: "Emplacements"
        case .permissions: "Autorisations"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .scanning: "magnifyingglass"
        case .duplicates: "square.on.square"
        case .locations: "folder.fill"
        case .permissions: "lock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: .pink
        case .scanning: .teal
        case .duplicates: .orange
        case .locations: .blue
        case .permissions: .indigo
        }
    }
}

/// The rounded tinted square System Settings puts beside every pane name.
///
/// Sized with `.font()` rather than `.resizable()`: a resized SF Symbol is
/// scaled rather than redrawn, and its strokes come out the wrong weight.
private struct PaneBadge: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(pane.tint)
            )
            // Keeps the badge legible on the selected row, where the sidebar
            // paints the accent colour behind it — Emplacements is blue.
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.14))
            )
    }
}

// MARK: - Shared bits

/// The sentence under a control.
///
/// A row of its own rather than a wrapper around the control it explains: a
/// grouped Form reserves a label column per row, and folding a Picker into a
/// VStack with its explanation costs that alignment — the same trap the
/// duplicate sliders documented with `labelsHidden()`.
struct SettingHelp: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
