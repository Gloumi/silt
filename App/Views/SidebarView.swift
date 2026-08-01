import SwiftUI

struct SidebarView: View {
    let model: ScanModel
    @State private var volumes: [VolumeInfo] = []
    private let locations = QuickLocation.standard()

    var body: some View {
        List {
            Section("Volumes") {
                ForEach(volumes) { volume in
                    VolumeRow(volume: volume)
                        .contentShape(.rect)
                        .onTapGesture { model.scan(path: volume.url.path) }
                }
            }

            Section("Emplacements") {
                ForEach(locations) { location in
                    Label(location.name, systemImage: location.symbol)
                        .contentShape(.rect)
                        .onTapGesture { model.scan(path: location.path) }
                }
            }
        }
        .listStyle(.sidebar)
        .task { volumes = Volumes.mounted() }
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(volume.name, systemImage: volume.isInternal ? "internaldrive" : "externaldrive")
                .lineLimit(1)

            CapacityBar(fraction: volume.usedFraction)
                .frame(height: 4)

            Text("\(Format.bytes(volume.availableBytes)) libres sur \(Format.bytes(volume.totalBytes))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct CapacityBar: View {
    let fraction: Double

    /// Turns amber then red as the disk fills — the one place in the app where
    /// colour carries meaning rather than identity.
    private var tint: Color {
        switch fraction {
        case ..<0.75: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
    }
}
