import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen + Dynamic Island UI for in-flight Chat / Code / Vision work.
struct AIThinkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AIThinkingAttributes.self) { context in
            lockScreenView(context: context)
                .widgetURL(deepLinkURL(for: context.attributes.kind))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.title)
                            .font(.headline)
                    } icon: {
                        Image(systemName: kindImage(context.attributes.kind))
                    }
                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.status)
                            .font(.subheadline.weight(.semibold))
                        if !context.state.promptPreview.isEmpty {
                            Text(context.state.promptPreview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: kindImage(context.attributes.kind))
                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } minimal: {
                Image(systemName: kindImage(context.attributes.kind))
                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
            }
            .widgetURL(deepLinkURL(for: context.attributes.kind))
        }
    }

    // MARK: - Lock Screen banner

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<AIThinkingAttributes>) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.42, green: 0.66, blue: 1.0).opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: kindImage(context.attributes.kind))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("RoamSocket · \(context.attributes.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(context.state.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(context.state.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if !context.state.promptPreview.isEmpty {
                    Text(context.state.promptPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(.white)
    }

    private func kindImage(_ raw: String) -> String {
        AIThinkingAttributes.Kind(rawValue: raw)?.systemImage
            ?? "sparkles"
    }

    private func deepLinkURL(for kindRaw: String) -> URL {
        AIThinkingAttributes.Kind(rawValue: kindRaw)?.deepLink.url
            ?? AppDeepLink.chat.url
    }
}
