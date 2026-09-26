import SwiftUI
import MilktoastCore

struct JobRow: View {
    let job: RemuxJob
    let openTitle: String
    let onOpen: () -> Void
    let onCancel: () -> Void
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(job.statusText)
                        .font(.caption)
                        .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                trailingControl
            }

            if !job.phase.isTerminal {
                if job.isIndeterminate {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: job.fraction ?? 0)
                }
            }

            if hasDetail {
                DisclosureGroup(isExpanded: $showsDetail) {
                    detailContent
                } label: {
                    Text(isFailed ? "Details" : "What Milktoast did")
                        .font(.caption)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Pieces

    private var isFailed: Bool {
        if case .failed = job.phase { return true }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.phase {
        case .playing:
            Image(systemName: "play.circle.fill").foregroundStyle(.green)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .working(let isEncode):
            Image(systemName: isEncode ? "wand.and.rays" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.tint)
        default:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch job.phase {
        case .playing, .ready:
            if let output = job.output {
                HStack(spacing: 6) {
                    if job.phase == .ready {
                        Button(openTitle, action: onOpen)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Play Again", action: onOpen)
                            .controlSize(.small)
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal the prepared movie in Finder")
                }
            }
        case .failed, .cancelled:
            EmptyView()
        default:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Cancel")
        }
    }

    private var hasDetail: Bool {
        job.failureDetail != nil || !(job.plan?.warnings.isEmpty ?? true)
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let plan = job.plan {
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: warning.severity == .warning
                            ? "exclamationmark.triangle"
                            : "info.circle")
                            .foregroundStyle(warning.severity == .warning ? .orange : .secondary)
                        Text(warning.message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let detail = job.failureDetail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = job.commandLine {
                Text(command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}
