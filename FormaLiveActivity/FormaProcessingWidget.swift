import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
@MainActor
struct FormaProcessingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FormaProcessingAttributes.self) { context in
            FormaProcessingLockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.055, green: 0.075, blue: 0.085))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(processingURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Forma", systemImage: processingSymbol(context.state))
                        .font(.headline).foregroundStyle(processingAccent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(processingPercent(context.state))
                        .font(.headline.monospacedDigit()).foregroundStyle(.white)
                        .accessibilityLabel("Progreso: \(processingPercent(context.state))")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.title).font(.subheadline.bold()).lineLimit(1)
                        ProgressView(value: processingProgress(context.state)).tint(processingAccent)
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(context.state.status).font(.caption).lineLimit(2)
                                Text(context.state.energyLabel).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            FormaProcessingPauseButton(context: context)
                        }
                    }.foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName: processingSymbol(context.state)).foregroundStyle(processingAccent)
                    .accessibilityLabel("Forma: \(context.state.status)")
            } compactTrailing: {
                Text(processingPercent(context.state)).font(.caption.monospacedDigit())
                    .foregroundStyle(processingAccent)
                    .accessibilityLabel("Progreso: \(processingPercent(context.state))")
            } minimal: {
                Image(systemName: processingSymbol(context.state)).foregroundStyle(processingAccent)
                    .accessibilityLabel("Forma, \(processingPercent(context.state)), \(context.state.status)")
            }
            .keylineTint(processingAccent)
            .widgetURL(processingURL)
        }
    }
}

@MainActor
private struct FormaProcessingLockScreenView: View {
    let context: ActivityViewContext<FormaProcessingAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: processingSymbol(context.state)).foregroundStyle(processingAccent)
                Text(context.attributes.title).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Text(processingPercent(context.state)).font(.headline.monospacedDigit())
                    .accessibilityLabel("Progreso: \(processingPercent(context.state))")
            }
            ProgressView(value: processingProgress(context.state)).tint(processingAccent)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.status).font(.caption).lineLimit(2)
                    Text(context.state.energyLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                FormaProcessingPauseButton(context: context)
            }
        }.padding(16).foregroundStyle(.white)
    }
}

@MainActor
private struct FormaProcessingPauseButton: View {
    let context: ActivityViewContext<FormaProcessingAttributes>

    @ViewBuilder var body: some View {
        let phase = context.state.phase
        if phase == "running" || phase == "saving" || phase == "paused" {
            let paused = phase == "paused"
            Button(intent: FormaProcessingActionIntent(
                jobID: context.attributes.jobID.uuidString, action: paused ? "resume" : "pause")) {
                Label(paused ? "Reanudar" : "Pausar", systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered).tint(processingAccent)
            .accessibilityIdentifier("formaActivityPause")
        } else if phase == "pausedForeground" {
            Link(destination: processingURL) {
                Label("Abrir Forma", systemImage: "arrow.up.forward.app")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered).tint(processingAccent)
            .accessibilityIdentifier("formaActivityOpenApp")
        } else if phase == "pausing" {
            Label("Pausando…", systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private let processingAccent = Color(red: 0.32, green: 0.88, blue: 0.77)
private let processingURL = URL(string: "forma://processing")!

private func processingProgress(_ state: FormaProcessingAttributes.ContentState) -> Double {
    state.progress.isFinite ? min(1, max(0, state.progress)) : 0
}

private func processingPercent(_ state: FormaProcessingAttributes.ContentState) -> String {
    "\(Int((processingProgress(state) * 100).rounded()))%"
}

private func processingSymbol(_ state: FormaProcessingAttributes.ContentState) -> String {
    switch state.phase {
    case "paused", "pausing", "pausedForeground": return "pause.circle.fill"
    case "completed": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.circle.fill"
    case "saving": return "square.and.arrow.down.fill"
    default: return "cube.transparent.fill"
    }
}
