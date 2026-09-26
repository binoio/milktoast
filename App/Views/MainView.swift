import SwiftUI
import UniformTypeIdentifiers
import MilktoastCore

struct MainView: View {
    let model: AppModel
    @State private var isTargetedForDrop = false

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.toolProblem {
                ToolProblemBanner(message: problem)
            }

            if model.jobs.isEmpty {
                DropZoneView(isTargeted: isTargetedForDrop) {
                    model.presentOpenPanel()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            JobRow(
                                job: job,
                                openTitle: model.manualOpenTitle,
                                onOpen: { model.openInPlayer(job) },
                                onCancel: { model.cancel(job) }
                            )
                            if job.id != model.jobs.last?.id { Divider() }
                        }
                    }
                }
                .frame(minHeight: 120)

                Divider()
                FooterBar(model: model)
            }
        }
        .frame(width: 460)
        .frame(minHeight: model.jobs.isEmpty ? 280 : 200)
        .background(.background)
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            load(providers)
            return true
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.enqueue([url]) }
            }
        }
    }
}

private struct ToolProblemBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

private struct FooterBar: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text("Cache \(model.cacheSizeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.jobs.contains(where: \.phase.isTerminal) {
                Button("Clear Finished") { model.removeFinished() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button("Add Movie…") { model.presentOpenPanel() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
