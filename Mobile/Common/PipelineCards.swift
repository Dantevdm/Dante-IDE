import SwiftUI

/// Each pipeline as the Mac's Pipelines card shows it: its state, branch and time, a track of
/// its stages and its last runs. Tapping one opens it: every stage by name, the run's number,
/// commit, who started it and why, and a link to the run.
struct PipelineList: View {
    let pipelines: [Briefing.Pipeline]
    var limit = 8
    @State private var open: String?
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(showsAll ? pipelines : Array(pipelines.prefix(limit))) { pipeline in
                PipelineRow(pipeline: pipeline, isOpen: open == pipeline.id) {
                    withAnimation(.snappy) { open = open == pipeline.id ? nil : pipeline.id }
                }
            }
            if pipelines.count > limit {
                Button(showsAll ? "Show fewer" : "Show all \(pipelines.count) pipelines") { withAnimation(.snappy) { showsAll.toggle() } }
                    .font(.subheadline.weight(.medium))
            }
        }
    }
}

private struct PipelineRow: View {
    let pipeline: Briefing.Pipeline
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        StatusMark(status: pipeline.status, running: pipeline.isRunning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pipeline.name).font(.body.weight(.semibold)).foregroundStyle(Palette.text).lineLimit(1)
                            Text(subtitle).font(.caption).foregroundStyle(Palette.text3).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(pipeline.state).font(.caption.weight(.semibold)).foregroundStyle(color(pipeline.status))
                            if let when = pipeline.finished ?? pipeline.started {
                                Text(when, style: .relative).font(.caption2).foregroundStyle(Palette.text3).monospacedDigit()
                            }
                        }
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.text3)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                    if !pipeline.stages.isEmpty || !pipeline.history.isEmpty {
                        HStack(spacing: 14) {
                            if !pipeline.stages.isEmpty { StageTrack(stages: pipeline.stages) }
                            Spacer(minLength: 0)
                            if !pipeline.history.isEmpty { History(statuses: pipeline.history + [pipeline.status]) }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { details }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(isOpen ? Palette.background : Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pipeline.status == .bad ? Palette.red.opacity(0.4) : Palette.line))
    }

    private var subtitle: String {
        [pipeline.project, pipeline.branch.isEmpty ? nil : pipeline.branch, pipeline.environment].compactMap { $0 }.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !pipeline.stages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pipeline.stages) { stage in
                        HStack(spacing: 10) {
                            StatusMark(status: stage.status, running: stage.active)
                            Text(stage.name).font(.subheadline).foregroundStyle(Palette.text)
                            Spacer()
                            Text(stage.state).font(.caption).foregroundStyle(color(stage.status))
                        }
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                fact("Run", pipeline.number)
                fact("Commit", pipeline.commit)
                fact("Started by", pipeline.requestedBy)
                fact("Why", pipeline.reason)
                fact("Took", duration)
            }
            if let url = pipeline.url {
                Button { openURL(url) } label: { Label("Open the run", systemImage: "arrow.up.right.square") }
                    .font(.subheadline.weight(.medium))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder private func fact(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(name).font(.caption).foregroundStyle(Palette.text3)
                Text(value).font(.caption.monospaced()).foregroundStyle(Palette.text2).textSelection(.enabled)
            }
        }
    }

    private var duration: String? {
        guard let started = pipeline.started, let finished = pipeline.finished, finished > started else { return nil }
        return Duration.seconds(finished.timeIntervalSince(started)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// The stages in order, as joined segments coloured by state, the running one pulsing.
private struct StageTrack: View {
    let stages: [Briefing.Pipeline.Stage]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(stages) { stage in
                RoundedRectangle(cornerRadius: 3)
                    .fill(stage.status == .quiet && !stage.active ? Palette.line : color(stage.status))
                    .frame(width: 26, height: 6)
                    .phaseAnimator(stage.active ? [1, 0.35] : [1]) { view, phase in view.opacity(phase) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(stages.map { "\($0.name) \($0.state)" }.joined(separator: ", "))
    }
}

/// Recent runs, oldest first, as small squares.
private struct History: View {
    let statuses: [Briefing.Status]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                RoundedRectangle(cornerRadius: 2).fill(status == .quiet ? Palette.line : color(status)).frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Last runs")
    }
}

private struct StatusMark: View {
    let status: Briefing.Status
    let running: Bool

    var body: some View {
        Image(systemName: running ? "circle.dotted" : symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(running ? Palette.accent : color(status))
            .symbolEffect(.pulse, isActive: running)
            .frame(width: 18)
    }

    private var symbol: String {
        switch status {
        case .good: "checkmark.circle.fill"
        case .bad: "xmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .quiet: "minus.circle"
        }
    }
}
