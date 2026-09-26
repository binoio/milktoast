import SwiftUI

struct DropZoneView: View {
    let isTargeted: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text("Drop a Matroska movie here")
                    .font(.headline)
                Text("Milktoast rewraps it as a QuickTime movie — no re-encoding — then opens it in QuickTime Player.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Choose Movie…", action: onChoose)
                .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
                .padding(12)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}
