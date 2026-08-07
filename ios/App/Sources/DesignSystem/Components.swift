import SwiftUI

/// Three-way (or N-way) segmented control that always uses `Theme` colors.
/// System `Picker(.segmented)` can render white-on-white in light mode when the
/// app uses a custom palette; this control avoids that.
struct ThemeSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.inkOnAccent : Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.accent)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.field, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 1)
        )
    }
}

/// A rounded pill control used in the composer's bottom row (model, permission).
struct Pill: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The model-selector pill shown in the chat + coding-session composers.
///
/// When the user has a valid model + API key, it renders as a chevron
/// pill that opens the model picker. When the user has no usable model
/// yet, it switches to an accent-tinted "+ Add a model" CTA that opens
/// the provider settings screen so they can paste a key. The component
/// pulls reactive state from the environment so callers don't have to
/// pass anything in besides the two actions.
///
/// For coding composers, set `requiresCodingAgent` so phone-only providers
/// (local Metal, Apple Intelligence) are not treated as a usable selection —
/// those run on-device for chat and may not match the desktop agent.
struct ModelSelectorPill: View {
    @EnvironmentObject var state: AppState
    var modelDisplayName: String
    var onPick: () -> Void
    var onAddModel: () -> Void
    /// When true, only cloud / desktop-agent providers count as usable.
    var requiresCodingAgent: Bool = false

    var body: some View {
        Button {
            if hasUsableModel { onPick() } else { onAddModel() }
        } label: {
            if hasUsableModel {
                HStack(spacing: 4) {
                    Text(modelDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceElevated, in: Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add a model")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.accent.opacity(0.15), in: Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    /// A usable model needs an entry AND (for cloud providers) an API key.
    /// On-device chat providers (Metal, Apple Intelligence) need no key.
    /// For coding, phone-only Metal does not count — only desktop-installed Metal
    /// (or cloud providers the agent supports).
    var hasUsableModel: Bool {
        guard let model = state.selectedModel else { return false }
        if requiresCodingAgent {
            guard model.provider.supportsCodingAgent else { return false }
            if model.provider == .localMetal {
                return state.isDesktopMetalModel(model)
                    || model.displayName.contains("· Desktop")
            }
        }
        if !model.provider.requiresAPIKey { return true }
        return !state.resolvedAPIKey(for: model.provider).isEmpty
    }
}

/// A tappable card used for the composer suggestions (IMG_0987).
struct SuggestionCard: View {
    let attributed: AttributedString
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(attributed)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
    }
}

/// A selectable list row with an optional trailing blue checkmark (IMG_0989/0991).
struct SelectableRow<Leading: View>: View {
    var title: String
    var subtitle: String? = nil
    var isSelected: Bool
    @ViewBuilder var leading: () -> Leading
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(title)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.selection)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension SelectableRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, isSelected: isSelected, leading: { EmptyView() }, action: action)
    }
}

/// Determinate progress while an on-device Metal model is loading into RAM.
/// Used on the model picker and the main chat composer.
struct LocalMetalLoadProgressBanner: View {
    /// 0…1 fraction complete.
    let progress: Double
    /// Optional display name of the model being loaded.
    var modelName: String? = nil
    /// Compact list-row styling vs. composer card padding.
    var style: Style = .card

    enum Style {
        case card
        case plain
    }

    private var clamped: Double {
        min(1, max(0, progress))
    }

    private var percentText: String {
        "\(Int((clamped * 100).rounded()))%"
    }

    private var title: String {
        if let modelName, !modelName.isEmpty {
            return "Loading \(modelName)…"
        }
        return "Loading on-device model…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(percentText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            ProgressView(value: clamped)
                .tint(Theme.accent)
                .accessibilityLabel("Model load progress")
                .accessibilityValue(percentText)
        }
        .padding(style == .card ? EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14) : .init())
        .background {
            if style == .card {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.separator.opacity(0.8), lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The small cloud glyph used next to environments (IMG_0989).
struct CloudGlyph: View {
    var body: some View {
        Image(systemName: "cloud")
            .font(.system(size: 18))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// The GitHub mark used on the repo chip (IMG_0987).
struct GitHubGlyph: View {
    var body: some View {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }
}

/// A titled bottom-sheet scaffold with a close button (used by the pickers).
struct SheetScaffold<Content: View>: View {
    let title: String
    var trailing: AnyView?
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Theme.surfaceElevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let trailing { trailing }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            content()
        }
        .background(Theme.background)
    }
}

/// A badge showing a count (used in connectors list).
struct CountBadge: View {
    let count: Int
    
    var body: some View {
        Text("\(count)")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, 8)
            .background(Theme.selection, in: Capsule())
    }
}

/// A toggle row with icon, title, and switch (used in Add to Chat sheet).
struct ToggleRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var iconColor: Color = Theme.textSecondary
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textPrimary)
                
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.selection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// A beta badge label.
struct BetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.surfaceElevated, in: Capsule())
    }
}

/// Three bouncing dots used while the assistant is generating a reply.
/// Driven by `TimelineView` so the wave keeps running through parent
/// re-renders (streaming tokens, tool status updates).
struct TypingDotsView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = t * 2.4 - Double(index) * 0.22
                    // Smooth 0…1…0 wave per dot, staggered by index.
                    let wave = (sin(phase * .pi * 2) + 1) / 2
                    Circle()
                        .fill(Theme.textSecondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.28 + 0.72 * wave)
                        .offset(y: -3.5 * wave)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant is typing")
    }
}
